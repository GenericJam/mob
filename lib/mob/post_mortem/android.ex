defmodule Mob.PostMortem.Android do
  @moduledoc """
  `ApplicationExitInfo`-backed post-mortem ingest for Android.

  Pulls the OS-held history of process exits via
  `ActivityManager.getHistoricalProcessExitReasons` (available on
  Android 11 / API 30 and later), filters against a persistent marker
  so each exit is emitted exactly once across boots, and hands each new
  entry to `Mob.Defect.emit_appexit_reason/1` as a capsule on
  `Mob.Defect.Bus`.

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
  every subsequent sweep emits only what accumulated since.

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
  alias Mob.PostMortem.Registry

  @doc """
  Sweep any ApplicationExitInfo entries the OS has recorded since the
  persisted marker was last written.

  Returns the list of capsules emitted, in the order the NIF returned
  them (typically OS-chronological). Empty on iOS, on Android < 11, on
  a host test with the NIF not loaded, or any time the marker filters
  everything out.
  """
  @spec sweep() :: [Capsule.t()]
  def sweep do
    with :android <- safe_platform(),
         entries when is_list(entries) <- safe_drain() do
      Registry.start()

      Enum.flat_map(entries, &emit_if_new/1)
    else
      _ -> []
    end
  end

  @doc false
  @spec sweep_with(module()) :: [Capsule.t()]
  def sweep_with(nif) when is_atom(nif) do
    with :android <- safe_platform_via(nif),
         entries when is_list(entries) <- safe_drain_via(nif) do
      Registry.start()
      Enum.flat_map(entries, &emit_if_new/1)
    else
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Emit + dedup
  # ---------------------------------------------------------------------------

  # Same shape as Mob.PostMortem.IOS.emit_if_new/1: shape validation
  # first, then Registry dedup, then Defect emit. A malformed entry
  # logs at :warning and is skipped — one bad row from the NIF must
  # not take out the whole sweep.
  defp emit_if_new(entry) when is_map(entry) do
    if valid_shape?(entry) do
      id = artifact_id(entry)

      if Registry.mark_seen(id) do
        [Defect.emit_appexit_reason(entry)]
      else
        []
      end
    else
      Logger.warning(
        "[Mob.PostMortem.Android] dropping malformed ApplicationExitInfo entry " <>
          "(missing required key): #{inspect(entry, limit: 4)}"
      )

      []
    end
  end

  defp emit_if_new(_), do: []

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
  # description). The persistent NIF-side marker filters most re-emits
  # between boots; the Registry here catches re-drains within a single
  # BEAM session (a re-sweep in the same lifetime should be a no-op).
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
      :mob_nif.post_mortem_android_drain()
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp safe_drain_via(nif) do
    try do
      nif.post_mortem_android_drain()
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end
end
