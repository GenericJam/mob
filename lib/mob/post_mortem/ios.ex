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
  | `MXCrashDiagnostic` | `:native_crash` |
  | `MXHangDiagnostic` | `:anr` (iOS's word is "hang"; the defect taxonomy uses ANR) |
  | `MXCPUExceptionDiagnostic` | `:perf_regression` |
  | `MXDiskWriteExceptionDiagnostic` | `:perf_regression` |

  The `Payload` suffix belongs on the container `MXDiagnosticPayload`
  the OS hands to `didReceiveDiagnosticPayloads:`, which then exposes
  the individual diagnostics above.

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

  ## Until observed, not once

  The native queue is cleared as it is drained, and MetricKit does not
  deliver a payload twice, so the capsule on this boot's bus is the
  only copy; a boot that dies before anyone looks would take the
  diagnostic with it. So each drained payload is written to
  `Mob.PostMortem.Journal` before it is emitted, and every sweep, in
  this boot or a later one, emits it again until a subscriber has
  received it or a reader has asked the bus. Within one boot a
  re-sweep emits nothing it already emitted.

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
  alias Mob.PostMortem.Journal

  @doc """
  Sweep the MetricKit queue and emit a capsule for each new payload,
  and for every earlier one not yet observed.

  Returns the list of capsules emitted: unobserved journaled payloads
  first, then new ones in the order the OS delivered them. Empty on
  Android, on iOS < 14 (no MetricKit delivery API), and when nothing
  is new or waiting to be observed.
  """
  @spec sweep() :: [Capsule.t()]
  def sweep, do: run(:mob_nif, &Journal.default_path/0)

  # Called by tests to inject a fake NIF that returns hand-shaped
  # payloads, and a journal path. Real callers should never pass this —
  # the default reaches `:mob_nif.post_mortem_ios_drain/0` and
  # `Journal.default_path/0`.
  @doc false
  @spec sweep_with(module(), Path.t()) :: [Capsule.t()]
  def sweep_with(nif, journal) when is_atom(nif) and is_binary(journal),
    do: run(nif, fn -> journal end)

  defp run(nif, journal) do
    case safe_platform(nif) do
      :ios ->
        fresh = nif |> safe_drain() |> Enum.flat_map(&identify/1)
        Journal.sweep(journal, :ios, fresh, &Defect.emit_metrickit_payload/1)

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Shape + id
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
  #    a field this side needs would be, and would be journaled and
  #    fail to emit on every sweep — if we did not gate.
  #
  # Well-formed payloads get their artifact id; malformed ones log at
  # :warning and are skipped. Neither raises out of the sweep.
  defp identify(payload) when is_map(payload) do
    if valid_shape?(payload) do
      [{artifact_id(payload), payload}]
    else
      Logger.warning(
        "[Mob.PostMortem.IOS] dropping malformed MetricKit payload " <>
          "(missing required key): #{inspect(payload, limit: 4)}"
      )

      []
    end
  end

  defp identify(_), do: []

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
  # unique per delivered diagnostic; the journal keys on it across
  # boots and the Registry filters out re-emits within the same BEAM
  # lifetime (a re-sweep produces no new capsules for the same payloads).
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
  # Safe NIF wrappers (`nif` is `:mob_nif`, or a test's stand-in)
  # ---------------------------------------------------------------------------

  defp safe_platform(nif) do
    nif.platform()
  catch
    # Not loaded (host) or not registered: not iOS.
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    _, _ -> :host
  end

  # A drain that fails or returns garbage drained nothing: the journal's
  # pending payloads are still re-emitted.
  defp safe_drain(nif) do
    case nif.post_mortem_ios_drain() do
      payloads when is_list(payloads) -> payloads
      _ -> []
    end
  catch
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    _, _ -> []
  end
end
