defmodule Mob.Defect do
  @moduledoc """
  Entry points that convert what the framework's detectors produce into
  capsules on the defect bus.

  The framework's detectors have their own shapes — an invariant violation is
  a `Mob.Invariant.Violation`, a divergence is the `{:divergence, %{...}}` a
  comparator returns. Rather than teach each detector to build a capsule,
  those detectors call the appropriate function here and this module supplies
  the fingerprint key, the owner, and the evidence shape.

  Centralising the mapping is what keeps `owner: :mob` from being copied into
  five places, and what makes the fingerprint key for the same kind of defect
  identical across detectors — the whole point of a fingerprint is that a
  divergence detected on iOS from mob_dev and the same divergence detected
  on-device from a fallback path land on the same triage item.

  ## Nothing propagates on the return path

  Every function here returns the capsule it built, but the emit is a
  side-effect on the bus and the caller does not need to do anything with
  the return value. That matches the shape of `Mob.Agent.Receipts.record/1`
  and lets a caller drop the emit onto an existing pipeline without
  restructuring around a result.
  """

  alias Mob.Defect.{Bus, Capsule}

  @doc """
  Emit a defect for a confirmed invariant violation.

  Owner is `:mob` — invariants are checks the framework makes about itself,
  and by construction they cannot fail for the app. `kind: :invariant`.

  The fingerprint key is `%{invariant: name, screen: screen_module}`, so a
  violation of the same invariant on the same screen groups across
  occurrences, and the same invariant on a different screen — a leak class
  that appears in two places — reports separately.
  """
  @spec emit_invariant_violation(Mob.Invariant.Violation.t()) :: Capsule.t()
  def emit_invariant_violation(%Mob.Invariant.Violation{} = v) do
    Capsule.new(
      kind: :invariant,
      owner: :mob,
      severity: v.severity,
      fingerprint_key: %{invariant: v.invariant, screen: v.screen},
      evidence: %{
        invariant: v.invariant,
        screen: v.screen,
        at: v.at,
        details: v.details
      }
    )
    |> Bus.emit()
  end

  @doc """
  Emit a defect for a differential-comparator divergence.

  Real entrypoint, pending an in-tree caller. `Mob.Differential.compare/3`
  is a pure comparator; the caller that runs it — currently `mob_dev`, via
  `MobDev.Differential.run/3` — invokes this after a `:divergence` result to
  put the class onto the bus. A follow-up mob_dev change wires that up
  after this ships to Hex; nothing in `mob` itself calls this yet.

  Owner is `:mob` — the differential comparator asserts one design, both
  platforms, which is a framework-level promise. `kind: :divergence`.

  The fingerprint key includes the fixture (so the same divergence in two
  fixtures reports separately), the `reason` (`:type`, `:label`, `:frame`,
  `:child_count`), and the `path` to the diverging node. The `ios` and
  `android` values are on evidence, not on the fingerprint key — a fixture's
  divergence in kind (say, always `:type` at `[0, 2]`) is the same class
  even if the tree values change slightly across releases.
  """
  @spec emit_divergence(map(), keyword() | map()) :: Capsule.t()
  def emit_divergence(%{path: path, reason: reason, ios: ios, android: android}, opts \\ []) do
    opts = Map.new(opts)
    fixture = Map.get(opts, :fixture)

    Capsule.new(
      kind: :divergence,
      owner: :mob,
      severity: Map.get(opts, :severity, :warning),
      fingerprint_key: %{fixture: fixture, reason: reason, path: path},
      evidence: %{
        fixture: fixture,
        reason: reason,
        path: path,
        ios: ios,
        android: android
      }
    )
    |> Bus.emit()
  end

  @doc """
  Emit a defect for an `erl_crash.dump` a scan turned up.

  Owner is `:mob` — the BEAM is what mob depends on and what mob's own
  invariants and scheduling assume; a hard crash there is a framework
  concern before it is an application one. `kind: :beam_crash`.

  Severity comes from what the slogan implies: OOM and out-of-memory
  variants are `:fatal`; a normal termination is `:info`; everything
  else defaults to `:critical`.

  The fingerprint key is the *normalized* slogan (see
  `Mob.PostMortem.BeamCrashDump.normalize_slogan/1`) rather than the raw
  one, because raw slogans embed the exact runtime data that varied per
  crash — a `{badarg, ...}` from `io:put_chars/2` carries a 4KB binary
  literal that would otherwise open one triage row per unique input.

  Evidence carries the human-facing fields plus the on-disk path so a
  triager can open the dump in `crashdump_viewer` when they want more
  than the header. The dump file itself is NOT read into evidence —
  eight kilobytes is the ceiling and the header is what fits.
  """
  @spec emit_beam_crash(map()) :: Capsule.t()
  def emit_beam_crash(%{sha256: sha256, slogan: slogan} = finding) do
    normalized = Mob.PostMortem.BeamCrashDump.normalize_slogan(slogan)

    Capsule.new(
      kind: :beam_crash,
      owner: :mob,
      severity: severity_from_slogan(slogan),
      fingerprint_key: %{slogan: normalized},
      evidence: %{
        path: Map.get(finding, :path),
        sha256: sha256,
        size: Map.get(finding, :size),
        modified_at: format_datetime(Map.get(finding, :modified_at)),
        slogan: slogan,
        system_version: Map.get(finding, :system_version),
        taints: Map.get(finding, :taints, []),
        atoms: Map.get(finding, :atoms),
        dump_version: Map.get(finding, :dump_version)
      }
    )
    |> Bus.emit()
  end

  # Severity heuristic from the slogan text. Conservative: unknown text
  # is `:critical`, not `:fatal`, so a novel crash class does not
  # over-page a triager. The two OOM-family strings are explicit BEAM
  # exits with those exact prefixes; a normal `:normal` termination is
  # not a crash to page on but is still worth an :info row so a triager
  # can see it happened.
  defp severity_from_slogan(nil), do: :critical

  defp severity_from_slogan(slogan) when is_binary(slogan) do
    cond do
      # Allocator panics — the process died because the OS refused a
      # backing allocation. Fatal by definition.
      String.contains?(slogan, "eheap_alloc") -> :fatal
      String.contains?(slogan, "binary_alloc") -> :fatal
      String.contains?(slogan, "ets_alloc") -> :fatal
      String.contains?(slogan, "sl_alloc") -> :fatal
      String.contains?(slogan, "driver_alloc") -> :fatal
      String.contains?(slogan, "fix_alloc") -> :fatal
      String.contains?(slogan, "std_alloc") -> :fatal
      # OTP boot-time crashes and the kernel-supervisor-died panic — the
      # BEAM refused to come up. The user sees nothing running.
      String.starts_with?(slogan, "Kernel pid terminated") -> :fatal
      String.starts_with?(slogan, "Runtime terminating during boot") -> :fatal
      String.contains?(slogan, "out of memory") -> :fatal
      # An explicit `:normal` exit is not a defect per se, but the fact
      # that a crash dump exists at all is worth an :info row so a
      # triager can see it happened. Everything unrecognised is :critical
      # — do not upgrade to :fatal without evidence, since a novel
      # slogan class could be routine.
      slogan == "normal" -> :info
      true -> :critical
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  @doc """
  Emit a defect for one MetricKit diagnostic delivered on iOS.

  Owner is `:mob` — a MetricKit payload names an event the OS
  attributes to this app process, and mob owns the process during a
  mob-app lifetime.

  The `payload` map comes from `Mob.PostMortem.IOS.sweep/0`'s drain of
  the native queue. Its shape:

      %{
        kind: :native_crash | :anr | :perf_regression,
        top_frame: %{binary: "MyApp", offset: 123456},
        timestamp_ms: 1_726_050_000_000,
        raw_json: <<...>>  # MXDiagnosticPayload.JSONRepresentation
      }

  The fingerprint key is the top stack frame — a crash in the same
  place across builds groups into one triage row. The frame's
  `binary` name is not the human function name (MetricKit gives
  mangled symbols only, no user data); it is the safe identifier the
  OS gives us, which is what we can safely put on the wire.

  Severity is picked from the diagnostic kind:
  - `:native_crash` → `:fatal` (the app terminated abnormally)
  - `:anr` → `:critical` (the main thread stalled past the OS's
    hang threshold; the app may or may not have recovered)
  - `:perf_regression` → `:warning` (CPU / disk exception; the app
    kept running, this is a heads-up)
  """
  @spec emit_metrickit_payload(map()) :: Capsule.t()
  def emit_metrickit_payload(
        %{
          kind: kind,
          top_frame: %{binary: binary, offset: offset},
          timestamp_ms: timestamp_ms
        } = payload
      ) do
    Capsule.new(
      kind: kind,
      owner: :mob,
      severity: metrickit_severity(kind),
      fingerprint_key: %{
        source: :metrickit,
        kind: kind,
        top_frame_binary: binary,
        top_frame_offset: offset
      },
      evidence: %{
        source: :metrickit,
        top_frame_binary: binary,
        top_frame_offset: offset,
        timestamp_ms: timestamp_ms,
        raw_json: Map.get(payload, :raw_json)
      }
    )
    |> Bus.emit()
  end

  defp metrickit_severity(:native_crash), do: :fatal
  defp metrickit_severity(:anr), do: :critical
  defp metrickit_severity(:perf_regression), do: :warning
  # Defensive: an unknown kind reaching us means the NIF grew a payload
  # type this dispatch does not know yet. Log severity, not silent
  # absorption.
  defp metrickit_severity(_), do: :critical

  @doc """
  Emit a defect for one Android `ApplicationExitInfo` entry.

  Owner is `:mob` — an ApplicationExitInfo record describes the death
  of this app's own process from the OS's point of view, and mob owns
  the process during a mob-app lifetime.

  The `entry` map comes from `Mob.PostMortem.Android.sweep/0`'s drain
  of the native queue. Its shape:

      %{
        reason_code: 6,       # ApplicationExitInfo.REASON_* integer
        pid: 12345,
        timestamp_ms: 1_726_050_000_000,
        process_name: "com.example.app",
        description: "remote process crash"
      }

  Reason code → kind mapping (numeric constants from Android's
  `android.app.ApplicationExitInfo` public API, hard-coded here rather
  than depending on the JNI shim to name them):

  | Reason(s) | `kind` | `severity` |
  |---|---|---|
  | `REASON_CRASH_NATIVE` (5), `REASON_CRASH` (4), `REASON_SIGNALED` (2) | `:native_crash` | `:fatal` |
  | `REASON_ANR` (6) | `:anr` | `:critical` |
  | `REASON_LOW_MEMORY` (3), `REASON_EXCESSIVE_RESOURCE_USAGE` (9) | `:oom` | `:fatal` |
  | `REASON_USER_STOPPED` (11), `REASON_USER_REQUESTED` (10), `REASON_EXIT_SELF` (1), `REASON_DEPENDENCY_DIED` (12) | `:user_kill` | `:info` |
  | anything else (unknown / rare) | `:user_kill` | `:info` |

  The `:info` default for unrecognised reason codes is deliberate. A
  novel reason a future Android version invents is not a defect to
  page a triager on; downgrading to routine is safer than upgrading
  to critical. The specific `REASON_*` mappings above match Android's
  documented severity semantics.

  Fingerprint groups by `(kind + process_name + reason_code)` — the
  same class of exit for the same process across boots becomes one
  triage row.
  """
  @spec emit_appexit_reason(map()) :: Capsule.t()
  def emit_appexit_reason(
        %{
          reason_code: reason_code,
          pid: _pid,
          timestamp_ms: timestamp_ms,
          process_name: process_name,
          description: description
        } = _entry
      ) do
    kind = appexit_kind(reason_code)

    Capsule.new(
      kind: kind,
      owner: :mob,
      severity: appexit_severity(kind),
      fingerprint_key: %{
        source: :application_exit_info,
        kind: kind,
        process_name: process_name,
        reason_code: reason_code
      },
      evidence: %{
        source: :application_exit_info,
        reason_code: reason_code,
        process_name: process_name,
        description: description,
        timestamp_ms: timestamp_ms
      }
    )
    |> Bus.emit()
  end

  # Reason code → defect kind. Numeric constants from
  # android.app.ApplicationExitInfo; source of truth is the Android
  # SDK (stable across Android 11+).
  #
  # 4 = REASON_CRASH, 5 = REASON_CRASH_NATIVE, 2 = REASON_SIGNALED
  defp appexit_kind(4), do: :native_crash
  defp appexit_kind(5), do: :native_crash
  defp appexit_kind(2), do: :native_crash

  # 6 = REASON_ANR
  defp appexit_kind(6), do: :anr

  # 3 = REASON_LOW_MEMORY, 9 = REASON_EXCESSIVE_RESOURCE_USAGE
  defp appexit_kind(3), do: :oom
  defp appexit_kind(9), do: :oom

  # 1 = REASON_EXIT_SELF, 10 = REASON_USER_REQUESTED,
  # 11 = REASON_USER_STOPPED, 12 = REASON_DEPENDENCY_DIED,
  # 13 = REASON_OTHER, 14 = REASON_FREEZER
  defp appexit_kind(_other), do: :user_kill

  # appexit_kind/1 above is total across the reason-code integer domain
  # (the `defp appexit_kind(_other)` fallback catches everything not
  # explicitly matched), so its return is one of these four atoms only.
  # A `_` fallback here would be dead code the compiler rightly flags.
  defp appexit_severity(:native_crash), do: :fatal
  defp appexit_severity(:anr), do: :critical
  defp appexit_severity(:oom), do: :fatal
  defp appexit_severity(:user_kill), do: :info
end
