defmodule Mob.Defect.Capsule do
  # Bounds first, so the moduledoc's `#{@…}` interpolations resolve.
  @schema_version "mob.defect/1"
  @evidence_string_limit 4_096
  @evidence_list_limit 64
  @evidence_max_depth 8
  @device_info_key {__MODULE__, :device_info}
  @build_info_key {__MODULE__, :build_info}

  @moduledoc """
  A defect, in the shape a consumer can act on.

  This is the format from
  `decisions/2026-09-04-defect-reports-are-a-shipped-feature.md`. The record is
  a struct in memory and `mob.defect/1` JSON on the wire, and the two are the
  same shape — a struct field with a snake-case atom becomes a JSON key with the
  same spelling, so a reader of one can read the other without a schema
  translation.

  ## What is fixed here vs. what a caller provides

  A caller — the invariant registry, the differential comparator, the crash
  handler, whatever — supplies what makes this defect *this* defect:
  `kind`, `owner`, `severity`, `evidence`, and the fingerprint inputs. The
  capsule fills in what is the same across every defect: `schema`, `id`,
  `detected_at`, `build`, `device`, `redaction`. That split is deliberate. A
  detector that had to construct the build section itself would drift out of
  step with the rest of the reports the moment `mob` bumped its version, and a
  fingerprint the caller computed by hand would land in three different shapes.

  ## Fingerprint

  `fingerprint` groups occurrences into one triage item. One thousand phones
  hitting the same bug produces one thousand `id`s and one `fingerprint`, and
  that is what makes the report channel usable rather than a firehose.

  The stable inputs are what *defines* the defect, and only those:

  * `kind`, `owner`
  * The caller's `fingerprint_key` — a small map like
    `%{invariant: :parked_screen_alive, screen: MyScreen}` — describing the
    defect *class*, not this occurrence

  The excluded inputs are what changes across occurrences of the same defect:

  * `id`, `detected_at`, `monotonic_us`
  * `build.*`, `device.*`
  * `evidence` beyond what the caller put in `fingerprint_key`

  A fingerprint that included the build version would open a new triage item
  every release, which is what the pre-shipped defect systems in this space do
  wrong.

  ## Redaction

  A capsule is written to a bounded ring buffer, and from there to whatever
  sink the app has wired up (dev-mode: the connected agent; production:
  whatever the app developer configured, if anything). The write and the
  possibility of a sink are the same event: by the time the caller has a
  capsule value, redaction has already happened. Sinks receive
  already-safe data, per the "redaction is a precondition" clause of the
  decision record.

  For phase 1 the discipline is pushed onto the callers: an `evidence` map that
  arrives here is trusted to contain no application state, and the capsule
  tags it `redaction: :applied` on that basis. The invariant registry and the
  differential comparator both already promise that (see
  `Mob.Invariant.Violation`'s moduledoc and `Mob.Differential`'s docs), so the
  emit paths in phase 1 are trustworthy inputs by construction. Later phases
  (native crash, `ApplicationExitInfo`, incident-capsule from a raised
  exception) will need `Mob.Agent.Receipt.summarize_error/3`-style reduction,
  which happens *before* the value reaches `new/1`.

  A caller that provably packages no state can pass `redaction: :none` to
  `new/1`, matching the schema. The default is `:applied`, and the default is
  the safe answer.

  ## Bounded shapes

  A defect from an app in the field has to fit through a pipe an app developer
  is willing to keep open. `evidence` and `fingerprint_key` are truncated
  during construction: strings above #{@evidence_string_limit} bytes are
  clipped and lists above #{@evidence_list_limit} elements are cut, with a
  tag left in place so a consumer can see clipping happened rather than treat
  the visible half as the whole. The recursion depth cap protects the packager
  from a maliciously deep term — a defect reporter that can be crashed by the
  defect it is reporting is worse than none.
  """

  alias Mob.Defect.Capsule

  @type kind ::
          :native_crash
          | :beam_crash
          | :anr
          | :oom
          | :user_kill
          | :invariant
          | :divergence
          | :deploy_mismatch
          | :perf_regression

  @type severity :: :fatal | :critical | :warning | :info
  @type owner :: :mob | :mob_dev | :mob_new | {:plugin, atom() | String.t()} | :app | :unknown

  @type redaction :: :applied | :none

  @type build_info :: %{
          mob: String.t() | nil,
          mob_dev: String.t() | nil,
          app: String.t() | nil,
          commit: String.t() | nil,
          dirty: boolean() | nil,
          otp: String.t() | nil,
          elixir: String.t() | nil,
          loaded_md5: map()
        }

  @type device_info :: %{
          platform: :ios | :android | :host,
          os: String.t() | nil,
          model: String.t() | nil,
          simulator: boolean() | nil,
          locale: String.t() | nil,
          scale: number() | nil
        }

  @type repro :: %{available: boolean(), minimized: boolean(), steps: [term()]}

  @type t :: %__MODULE__{
          schema: String.t(),
          id: String.t(),
          fingerprint: String.t(),
          kind: kind(),
          severity: severity(),
          detected_at: String.t(),
          owner: owner(),
          redaction: redaction(),
          build: build_info(),
          device: device_info(),
          evidence: map(),
          repro: repro()
        }

  @enforce_keys [
    :schema,
    :id,
    :fingerprint,
    :kind,
    :severity,
    :detected_at,
    :owner,
    :redaction,
    :build,
    :device,
    :evidence,
    :repro
  ]

  defstruct [
    :schema,
    :id,
    :fingerprint,
    :kind,
    :severity,
    :detected_at,
    :owner,
    :redaction,
    :build,
    :device,
    :evidence,
    :repro
  ]

  @doc """
  Build a capsule.

  Required:
    * `:kind` — see `t:kind/0`
    * `:owner` — see `t:owner/0`
    * `:severity` — see `t:severity/0`
    * `:fingerprint_key` — the map that identifies the defect *class*. Kept
      separately from `:evidence` so the fingerprint stays stable when
      evidence gains fields between releases.

  Optional:
    * `:evidence` — kind-specific detail. Defaults to `%{}`. Truncated during
      construction.
    * `:redaction` — `:applied` (default) or `:none`. `:none` is only legal
      for a capsule that provably carries no application state.
    * `:repro` — a repro map. Defaults to `%{available: false, minimized:
      false, steps: []}` since phase 1 does not attempt reproduction.
    * `:build` / `:device` — override the framework-populated sections
      (tests use this to make snapshots deterministic).
    * `:now_ms` — Unix milliseconds for `detected_at`. Defaults to `System.system_time(:millisecond)`;
      tests use this to make timestamps deterministic.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts) when is_list(opts), do: new(Map.new(opts))

  def new(%{kind: kind, owner: owner, severity: severity, fingerprint_key: fp_key} = opts)
      when is_map(fp_key) do
    truncated_key = truncate(fp_key)
    truncated_evidence = opts |> Map.get(:evidence, %{}) |> truncate()
    redaction = validate_redaction(Map.get(opts, :redaction, :applied))

    build = Map.get_lazy(opts, :build, &build_info/0)
    device = Map.get_lazy(opts, :device, &device_info/0)
    now_ms = Map.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)

    %Capsule{
      schema: @schema_version,
      id: new_id(now_ms),
      fingerprint: fingerprint(kind, owner, truncated_key),
      kind: kind,
      severity: severity,
      detected_at: iso8601(now_ms),
      owner: owner,
      redaction: redaction,
      build: build,
      device: device,
      evidence: Map.merge(truncated_key, truncated_evidence),
      repro: Map.get(opts, :repro, %{available: false, minimized: false, steps: []})
    }
  end

  @doc """
  The JSON-shaped map for the wire.

  Structurally identical to the struct — a struct field with a snake-case atom
  becomes a JSON key of the same name. Owners get their string form:
  `{:plugin, :foo}` becomes `"plugin:foo"`, matching the schema.

  Callers that want bytes rather than a map pass this to `Jason.encode!/1`.
  Jason is `mob`'s only runtime dep, so a caller inside the tree can always
  encode; a caller outside can too but is not obliged to.
  """
  @spec to_json(t()) :: map()
  def to_json(%Capsule{} = c) do
    %{
      "schema" => c.schema,
      "id" => c.id,
      "fingerprint" => c.fingerprint,
      "kind" => Atom.to_string(c.kind),
      "severity" => Atom.to_string(c.severity),
      "detected_at" => c.detected_at,
      "owner" => owner_to_string(c.owner),
      "redaction" => Atom.to_string(c.redaction),
      "build" => stringify_keys(c.build),
      "device" => stringify_keys(c.device),
      "evidence" => stringify_terms(c.evidence),
      "repro" => stringify_keys(c.repro)
    }
  end

  @doc """
  A one-line triage summary for a human reading a log.

  Deliberately compact and free of any application state — everything shown
  here has already been through the capsule's redaction contract, so this is
  safe to log even when the sink is a remote agent over dist.
  """
  @spec describe(t()) :: String.t()
  def describe(%Capsule{} = c) do
    fp_short = c.fingerprint |> String.replace_prefix("sha256:", "") |> String.slice(0, 8)

    "[defect #{Atom.to_string(c.severity)}] " <>
      "#{Atom.to_string(c.kind)} owner=#{owner_to_string(c.owner)} " <>
      "fp=#{fp_short} redaction=#{Atom.to_string(c.redaction)} " <>
      "evidence=#{inspect(c.evidence, limit: 8)}"
  end

  @doc """
  A stable sha256 hex over the defect-defining fields only.

  `kind`, `owner`, and `fingerprint_key` are hashed with a canonical
  representation of the map (keys sorted, atoms unified with their string
  form) so two callers that produce the same defect land on the same
  fingerprint regardless of key insertion order. Time, id, build, device, and
  extra evidence are excluded — a fingerprint is a defect class, not an
  occurrence.

  Exposed for tests and for callers that want to correlate a defect against
  something they compute themselves. Called by `new/1`, so ordinary construction
  does not need to call this directly.
  """
  @spec fingerprint(kind(), owner(), map()) :: String.t()
  def fingerprint(kind, owner, fingerprint_key) when is_map(fingerprint_key) do
    canonical = {kind, owner, canonicalize(fingerprint_key)}

    digest =
      canonical
      |> :erlang.term_to_binary(minor_version: 2)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  # ---------------------------------------------------------------------------
  # Build / device population
  # ---------------------------------------------------------------------------

  @doc """
  The build section, computed once per node and cached.

  Versions do not change during a session. `Application.spec/2` is cheap on
  its own, but the write path pays it on every emit — the small cost adds up
  under a burst of confirmed violations from a runaway teardown, and the
  cached value is trivially cheaper. Same reasoning as `device_info/0`.
  """
  @spec build_info() :: build_info()
  def build_info do
    case :persistent_term.get(@build_info_key, :none) do
      :none ->
        info = compute_build_info()
        :persistent_term.put(@build_info_key, info)
        info

      cached ->
        cached
    end
  end

  @doc false
  @spec forget_build_info() :: :ok
  def forget_build_info do
    :persistent_term.erase(@build_info_key)
    :ok
  end

  defp compute_build_info do
    %{
      mob: version(:mob),
      mob_dev: version(:mob_dev),
      app: nil,
      commit: nil,
      dirty: nil,
      otp: otp_release(),
      elixir: System.version(),
      loaded_md5: %{}
    }
  end

  @doc """
  The device section, computed once per node and cached.

  `platform`, `os`, `model`, and the fields that will populate around them do
  not change during a session — the OS reports the same model on every call,
  and OS version changes only across upgrades that require a relaunch. Every
  emit was paying two NIF hops for those on the write path, which on a
  teardown-heavy sampling point (`:on_screen_stop`) is real cost added to
  every confirmed violation. Read once, cache in `:persistent_term`, done.

  `:persistent_term.put/2` is expensive (it triggers a global GC) but that
  cost pays for reads that are the cheapest thing on the BEAM, and this is a
  one-shot at first emit — a use-once, read-many pattern which is exactly the
  case persistent_term is documented for.
  """
  @spec device_info() :: device_info()
  def device_info do
    case :persistent_term.get(@device_info_key, :none) do
      :none ->
        info = compute_device_info()
        :persistent_term.put(@device_info_key, info)
        info

      cached ->
        cached
    end
  end

  # Test/support hook: forget the cached device section so the next
  # `device_info/0` re-reads from the platform. Not called on the hot path.
  @doc false
  @spec forget_device_info() :: :ok
  def forget_device_info do
    :persistent_term.erase(@device_info_key)
    :ok
  end

  defp compute_device_info do
    %{
      platform: safe_platform(),
      os: safe_os_version(),
      model: safe_model(),
      simulator: nil,
      locale: nil,
      scale: nil
    }
  end

  defp version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
    end
  end

  defp otp_release do
    :erlang.system_info(:otp_release)
    |> List.to_string()
  end

  defp safe_platform do
    try do
      :mob_nif.platform()
    rescue
      _ -> :host
    catch
      _, _ -> :host
    end
  end

  defp safe_os_version do
    try do
      Mob.Device.os_version()
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp safe_model do
    try do
      Mob.Device.model()
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Fingerprint canonicalisation
  # ---------------------------------------------------------------------------

  # Fingerprint stability across an `%{a: 1, b: 2}` written two different ways
  # matters: term_to_binary is not order-stable on maps, so two writers that
  # both produce the same defect could land on two different hashes if we hashed
  # the raw term. Sort keys, and recurse into values that are themselves maps
  # for the same reason.
  #
  # Atoms are converted to strings so an atom key and a string key with the
  # same name hash the same. This matches the JSON shape, where every key is a
  # string, and it means a caller reading a fingerprint back from a JSON copy
  # of a capsule still gets the same value.
  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {stringify_key(k), canonicalize_value(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize_value(v) when is_map(v) and not is_struct(v), do: canonicalize(v)
  defp canonicalize_value(v) when is_list(v), do: Enum.map(v, &canonicalize_value/1)

  defp canonicalize_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp canonicalize_value(v), do: v

  defp stringify_key(k) when is_atom(k), do: Atom.to_string(k)
  defp stringify_key(k) when is_binary(k), do: k
  defp stringify_key(k), do: inspect(k)

  # ---------------------------------------------------------------------------
  # Truncation
  # ---------------------------------------------------------------------------

  defp truncate(m) when is_map(m), do: truncate_value(m, 0)

  defp truncate_value(_v, depth) when depth > @evidence_max_depth,
    do: {:truncated, :depth}

  defp truncate_value(v, depth) when is_map(v) and not is_struct(v) do
    Map.new(v, fn {k, val} -> {k, truncate_value(val, depth + 1)} end)
  end

  defp truncate_value(v, depth) when is_list(v) do
    if length(v) > @evidence_list_limit do
      kept = v |> Enum.take(@evidence_list_limit) |> Enum.map(&truncate_value(&1, depth + 1))
      kept ++ [{:truncated, :list, length(v) - @evidence_list_limit}]
    else
      Enum.map(v, &truncate_value(&1, depth + 1))
    end
  end

  defp truncate_value(v, _depth) when is_binary(v) and byte_size(v) > @evidence_string_limit do
    <<kept::binary-size(@evidence_string_limit), _::binary>> = v
    {:truncated, :string, kept}
  end

  defp truncate_value(v, _depth), do: v

  # ---------------------------------------------------------------------------
  # Wire-form helpers
  # ---------------------------------------------------------------------------

  defp validate_redaction(:applied), do: :applied
  defp validate_redaction(:none), do: :none

  defp validate_redaction(other),
    do: raise(ArgumentError, "redaction must be :applied or :none, got #{inspect(other)}")

  defp owner_to_string({:plugin, name}) when is_atom(name), do: "plugin:" <> Atom.to_string(name)
  defp owner_to_string({:plugin, name}) when is_binary(name), do: "plugin:" <> name
  defp owner_to_string(owner) when is_atom(owner), do: Atom.to_string(owner)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {stringify_key(k), stringify_value(v)} end)
  end

  defp stringify_value(v) when is_map(v) and not is_struct(v), do: stringify_keys(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)

  defp stringify_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp stringify_value(v), do: v

  # `evidence` may contain terms the caller does not expect to reach a wire —
  # pids, refs, tuples. Sinks that hand a capsule to Jason will fail on those
  # without help. Reduce them here to inspect strings so the wire form is
  # always encodable. This is separate from redaction: redaction refuses to
  # transmit application state; this makes the shape encodable.
  defp stringify_terms(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {stringify_key(k), stringify_term(v)} end)
  end

  defp stringify_term(v) when is_map(v) and not is_struct(v), do: stringify_terms(v)
  defp stringify_term(v) when is_list(v), do: Enum.map(v, &stringify_term/1)
  defp stringify_term(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&stringify_term/1)

  defp stringify_term(v) when is_pid(v) or is_reference(v) or is_port(v) or is_function(v),
    do: inspect(v)

  defp stringify_term(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp stringify_term(v), do: v

  # ---------------------------------------------------------------------------
  # Id and timestamp
  # ---------------------------------------------------------------------------

  # A time-sortable id: 48-bit millisecond timestamp, then a monotonic per-node
  # counter, base32-encoded. Not a full ULID — mob's single-runtime-dep rule
  # rules out a ULID library — but structurally similar: the leading digits
  # sort by time, so a listing of ids from a ring buffer is chronological
  # without a separate sort. Unique per occurrence within a node.
  defp new_id(now_ms) do
    unique = System.unique_integer([:positive, :monotonic])
    <<time_part::48, rest_part::80>> = <<now_ms::48, unique::80>>
    Base.encode32(<<time_part::48, rest_part::80>>, padding: false, case: :upper)
  end

  defp iso8601(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end
end
