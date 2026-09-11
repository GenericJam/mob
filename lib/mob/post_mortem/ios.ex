defmodule Mob.PostMortem.IOS do
  @moduledoc """
  MetricKit-backed post-mortem ingest for iOS.

  The framework attaches an `MXMetricManagerSubscriber` in the NIF on
  the first `sweep/0` call, receives MetricKit payloads on a background
  queue thereafter, and drains the bounded in-memory queue into
  `Mob.Defect.Capsule`s on `Mob.Defect.Bus` each time `sweep/0` is
  called.

  ## Scope of a payload

  MetricKit hands the OS-delivered payload to the delegate once per
  incident class per day (approximately — the delivery cadence is under
  Apple's control). Each delivery may contain one or more diagnostics of
  different kinds:

  | MetricKit diagnostic | `kind` |
  |---|---|
  | `MXCrashDiagnosticPayload` | `:native_crash` |
  | `MXHangDiagnosticPayload` | `:anr` (iOS's word is "hang"; the defect taxonomy uses ANR) |
  | `MXCPUExceptionDiagnosticPayload` | `:perf_regression` |
  | `MXDiskWriteExceptionDiagnosticPayload` | `:perf_regression` |

  ## What the delivery contract looks like from Elixir

  `sweep/0` is safe to call at any point; MetricKit's own delivery is
  asynchronous and the queue accumulates until a caller drains it. A
  typical shape:

      # In your app's on_start
      def on_start do
        # ...
        Mob.PostMortem.sweep()
      end

  The top-level `Mob.PostMortem.sweep/0` calls into this module. Nothing
  auto-runs — that is the framework-wide discipline: mob owns the format
  and the bus but never becomes the collector.

  ## Redaction

  MetricKit's `MXCallStackTree` carries binary UUIDs, image names and
  mangled symbol offsets: safe identifiers, no user data. The
  capsule's fingerprint key uses just the top frame's binary name and
  offset — enough to group the same crash across launches without
  embedding anything that varies per crash. The full payload JSON goes
  onto evidence, bounded by the capsule's existing string-truncation
  rule.

  ## Platform gating

  The NIF is registered on both iOS and Android (Android returns an
  empty list unconditionally — see `android/jni/mob_nif.zig`). This
  module additionally gates on `:mob_nif.platform() == :ios` so a
  caller on Android does no work at all, and a caller in a host test
  environment where the NIF is not loaded fails gracefully.
  """

  require Logger

  alias Mob.Defect
  alias Mob.Defect.Capsule
  alias Mob.PostMortem.Registry

  @doc """
  Sweep the MetricKit queue and emit a capsule for each new payload.

  Returns the list of capsules emitted, in the order they were
  delivered by the OS. Empty on Android, on iOS < 14 (no MetricKit
  delivery API), and any time the queue was already empty since the
  last drain.
  """
  @spec sweep() :: [Capsule.t()]
  def sweep do
    with :ios <- safe_platform(),
         payloads when is_list(payloads) <- safe_drain() do
      Registry.start()

      Enum.flat_map(payloads, &emit_if_new/1)
    else
      _ -> []
    end
  end

  # Called by tests to inject a fake NIF that returns hand-shaped
  # payloads. Real callers should never pass this — the default reaches
  # `:mob_nif.post_mortem_ios_drain/0` directly.
  @doc false
  @spec sweep_with(module()) :: [Capsule.t()]
  def sweep_with(nif) when is_atom(nif) do
    with :ios <- safe_platform_via(nif),
         payloads when is_list(payloads) <- safe_drain_via(nif) do
      Registry.start()
      Enum.flat_map(payloads, &emit_if_new/1)
    else
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Emit + dedup
  # ---------------------------------------------------------------------------

  # Emit gate. Two shape checks, in this order:
  #
  # 1. `is_map/1` catches an obviously wrong payload from the NIF (a
  #    naked atom, a list, nil).
  # 2. `valid_shape?/1` catches a *partial* map — one that would
  #    pass `is_map` but crash `Defect.emit_metrickit_payload/1`'s
  #    strict pattern match. A partial payload from a future NIF
  #    version that grew a field the current Elixir side does not
  #    know about is not this shape; a partial payload that dropped
  #    a field this side needs would be, and would take out the
  #    whole sweep — losing every later well-formed payload in the
  #    same drain — if we did not gate.
  #
  # Well-formed payloads emit and mark seen; malformed ones log at
  # :warning and are skipped. Neither raises out of the sweep.
  defp emit_if_new(payload) when is_map(payload) do
    if valid_shape?(payload) do
      id = artifact_id(payload)

      if Registry.mark_seen(id) do
        [Defect.emit_metrickit_payload(payload)]
      else
        []
      end
    else
      Logger.warning(
        "[Mob.PostMortem.IOS] dropping malformed MetricKit payload " <>
          "(missing required key): #{inspect(payload, limit: 4)}"
      )

      []
    end
  end

  defp emit_if_new(_), do: []

  defp valid_shape?(%{
         kind: _,
         top_frame: %{binary: _, offset: _},
         timestamp_ms: _
       }),
       do: true

  defp valid_shape?(_), do: false

  # A MetricKit payload does not carry a stable id of its own — MetricKit
  # deduplicates by day on its side, and we deduplicate by content on
  # ours. sha256 of (kind + top_binary + top_offset + timestamp_ms) is
  # unique per delivered diagnostic; the Registry then filters out
  # re-emits within the same BEAM lifetime (a re-sweep produces no new
  # capsules for the same drained payloads).
  #
  # No fallback clause: `valid_shape?/1` in the caller gates on exactly
  # this pattern, so a malformed payload cannot reach here. A second
  # clause that returned a synthetic id would be dead code the compiler
  # rightly flags.
  defp artifact_id(%{
         kind: kind,
         top_frame: %{binary: binary, offset: offset},
         timestamp_ms: timestamp_ms
       }) do
    canonical = "#{kind}|#{binary}|#{offset}|#{timestamp_ms}"
    hash = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
    "sha256:" <> hash
  end

  # ---------------------------------------------------------------------------
  # Safe NIF wrappers
  # ---------------------------------------------------------------------------

  defp safe_platform do
    try do
      :mob_nif.platform()
    rescue
      _ -> :host
    catch
      _, _ -> :host
    end
  end

  defp safe_platform_via(nif) do
    try do
      nif.platform()
    rescue
      _ -> :host
    catch
      _, _ -> :host
    end
  end

  defp safe_drain do
    try do
      :mob_nif.post_mortem_ios_drain()
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp safe_drain_via(nif) do
    try do
      nif.post_mortem_ios_drain()
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end
end
