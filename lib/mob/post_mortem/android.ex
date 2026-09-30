defmodule Mob.PostMortem.Android do
  @moduledoc """
  `ApplicationExitInfo`-backed post-mortem ingest for Android.

  Pulls the OS-held history of process exits via
  `ActivityManager.getHistoricalProcessExitReasons` (available on
  Android 11 / API 30 and later), filters against a persistent marker
  so the drain returns each exit once across boots, keeps each one in
  `Mob.PostMortem.Journal` until it has been observed, and hands it to
  `Mob.Defect.emit_appexit_reason/1` as a capsule on `Mob.Defect.Bus`.

  ## What the OS gives us

  `ApplicationExitInfo` records the reason a previous process instance
  of this app died — an ANR, a crash, an OOM, a user-initiated kill.
  The list survives reboots and app updates, and the OS trims it
  eventually (usually 16 entries per app). We do NOT run every boot
  hoping to catch a live incident: we sweep whenever the caller does
  and take whatever the OS still holds since the last sweep.

  ## Persistent marker

  Without a marker, every sweep on a fresh install re-emits the entire
  historical list; every subsequent boot would re-emit the same
  entries. The native NIF persists the highest-seen exit timestamp to
  `<filesDir>/mob_post_mortem_appexit_marker.txt` and filters the OS
  list to entries strictly newer. First sweep on a fresh install still
  emits the current history (that is the point of a first sweep);
  every subsequent drain returns only what accumulated since.

  ## Until observed, not once

  The marker advances when the NIF returns an exit, so the drain is
  destructive: the capsule on this boot's bus is the only copy, and a
  boot that dies before anyone looks — `mix mob.connect` restarts the
  app, for one — would take the exit with it. So each drained exit is
  written to `Mob.PostMortem.Journal` before it is emitted, and every
  sweep, in this boot or a later one, emits it again until a
  subscriber has received it or a reader has asked the bus. Within one
  boot a re-sweep emits nothing it already emitted.

  ## Platform gating

  The NIF is registered on both platforms (iOS returns `[]`
  unconditionally — the iOS substrate is MetricKit, MOB-179). This
  module gates on `:mob_nif.platform() == :android` so a caller on
  iOS or in a host test does no work at all. On an Android device
  below API 30 the native side also returns `[]` — the API was added
  in Android 11.

  ## Redaction

  The emitted capsule carries: numeric reason code, pid (an OS
  identifier, not user data), timestamp, process name (normally the
  app's package name; also OS-controlled), and a short
  OS-generated description string like `"remote process crash"`.
  NOT included this phase: the trace file contents an ANR carries —
  those can hold app strings and need the same
  `Mob.Agent.Receipt.summarize_error/3`-style discipline before they
  can safely reach the bus.
  """

  require Logger

  alias Mob.Defect
  alias Mob.Defect.Capsule
  alias Mob.PostMortem.Journal

  @doc """
  Sweep any ApplicationExitInfo entries the OS has recorded since the
  persisted marker was last written, and every earlier one not yet
  observed.

  Returns the list of capsules emitted: unobserved journaled entries
  first, then new ones in the order the NIF returned them (typically
  OS-chronological). Empty on iOS, on Android < 11, on a host test with
  the NIF not loaded, and when nothing is new or waiting to be observed.
  """
  @spec sweep() :: [Capsule.t()]
  def sweep, do: run(:mob_nif, &Journal.default_path/0)

  @doc false
  @spec sweep_with(module(), Path.t()) :: [Capsule.t()]
  def sweep_with(nif, journal) when is_atom(nif) and is_binary(journal),
    do: run(nif, fn -> journal end)

  defp run(nif, journal) do
    case safe_platform(nif) do
      :android ->
        fresh = nif |> safe_drain() |> Enum.flat_map(&identify/1)
        Journal.sweep(journal, :android, fresh, &Defect.emit_appexit_reason/1)

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Shape + id
  # ---------------------------------------------------------------------------

  # Same shape as Mob.PostMortem.IOS.identify/1: shape validation first,
  # then the artifact id the journal and the Registry dedup on. A
  # malformed entry logs at :warning and is skipped — one bad row from
  # the NIF must not take out the whole sweep.
  defp identify(entry) when is_map(entry) do
    if valid_shape?(entry) do
      [{artifact_id(entry), entry}]
    else
      Logger.warning(
        "[Mob.PostMortem.Android] dropping malformed ApplicationExitInfo entry " <>
          "(missing required key): #{inspect(entry, limit: 4)}"
      )

      []
    end
  end

  defp identify(_), do: []

  defp valid_shape?(%{
         reason_code: _,
         pid: _,
         timestamp_ms: _,
         process_name: _,
         description: _
       }),
       do: true

  defp valid_shape?(_), do: false

  # sha256 over (reason_code + pid + timestamp_ms + process_name +
  # description). The NIF-side marker keeps the OS from handing an exit
  # over twice; the journal keeps it until observed; the Registry keeps
  # a re-sweep within one BEAM session from emitting it twice.
  #
  # `description` is included in the artifact id (not the fingerprint
  # key) to distinguish two OS entries with matching (reason_code,
  # pid, timestamp_ms, process_name) but different descriptions — rare
  # in practice at ms-granular timestamps, but non-zero.
  defp artifact_id(%{
         reason_code: reason_code,
         pid: pid,
         timestamp_ms: timestamp_ms,
         process_name: process_name,
         description: description
       }) do
    canonical = "#{reason_code}|#{pid}|#{timestamp_ms}|#{process_name}|#{description}"
    hash = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
    "sha256:" <> hash
  end

  # ---------------------------------------------------------------------------
  # Safe NIF wrappers (`nif` is `:mob_nif`, or a test's stand-in)
  # ---------------------------------------------------------------------------

  defp safe_platform(nif) do
    nif.platform()
  catch
    # Not loaded (host) or not registered: not Android.
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    _, _ -> :host
  end

  # A drain that fails or returns garbage drained nothing: the journal's
  # pending entries are still re-emitted.
  defp safe_drain(nif) do
    case nif.post_mortem_android_drain() do
      entries when is_list(entries) -> entries
      _ -> []
    end
  catch
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    _, _ -> []
  end
end
