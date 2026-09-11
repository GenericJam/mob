defmodule Mob.PostMortem do
  @moduledoc """
  Collect the post-mortems the OS and the BEAM leave behind when a
  process dies, and put them onto `Mob.Defect.Bus` as capsules.

  Three sources, each in its own submodule:

  * `Mob.PostMortem.BeamCrashDump` — `erl_crash.dump` files (BEAM).
    Scans configured paths, reads a bounded 8 KB header, dedups by
    sha256, emits `:beam_crash` capsules.
  * `Mob.PostMortem.IOS` — MetricKit payloads (crash / hang / launch /
    CPU / memory / disk). Attaches an `MXMetricManagerSubscriber`
    lazily on first sweep, buffers OS-delivered payloads in a bounded
    native queue, emits `:native_crash` / `:anr` / `:perf_regression`
    capsules on drain.
  * `Mob.PostMortem.Android` — `ApplicationExitInfo` history (ANR,
    crash, OOM, user kill). Pulls the OS-held exit-reason list on
    demand (API 30+), filters against a persistent marker so each
    exit emits exactly once across boots, emits `:native_crash` /
    `:anr` / `:oom` / `:user_kill` capsules.

  Nothing here runs automatically. An app opts in by calling
  `Mob.PostMortem.sweep/0` from its `on_start`, and a developer or CI
  calls the same function from an IEx session (there is no dedicated
  Mix task — the whole surface is one function). That matches the
  discipline the `Mob.Defect` subsystem enforces: mob owns the format
  and the bus but never becomes the collector.

  ## Idempotence

  `sweep/0` is safe to call as many times as you like. Each artifact has
  a sha256 id, and `Mob.PostMortem.Registry` records ids that have
  already emitted; a subsequent sweep finds them seen and does nothing.
  The dump stays on disk — nothing here deletes or moves a file — so
  offline inspection still works. See the registry's moduledoc for why
  the seen-set does not persist across BEAM restarts (a fresh BEAM
  sweeps back into a fresh bus, on purpose).

  ## Return value

  `sweep/0` and `sweep/1` return the capsules that were emitted this
  call, in the order they were emitted. That is what a caller drop-in
  in `on_start` normally ignores; a test or a CLI wants it.
  """

  alias Mob.Defect.Capsule
  alias Mob.PostMortem.BeamCrashDump

  @doc """
  Sweep every source using its default paths.

  Equivalent to `sweep([])` — each source module supplies its own
  defaults (see `BeamCrashDump.default_paths/0`; iOS and Android draw
  from their platform native APIs when linked).
  """
  @spec sweep() :: [Capsule.t()]
  def sweep, do: sweep([])

  @doc """
  Sweep every source, with `beam_paths` added to the BEAM-crash-dump
  scanner's default paths.

  A caller with dumps somewhere unusual (a CI artifact directory, a
  scratchpad) passes them here — they merge with the defaults rather
  than replacing them, so passing an empty list is equivalent to
  `sweep/0`.
  """
  @spec sweep([Path.t()]) :: [Capsule.t()]
  def sweep(beam_paths) when is_list(beam_paths) do
    beam_all = Enum.uniq(BeamCrashDump.default_paths() ++ beam_paths)

    beam_all
    |> BeamCrashDump.scan()
    |> BeamCrashDump.emit()
    |> Kernel.++(sweep_native())
  end

  # Both platform modules gate on `:mob_nif.platform/0` internally, so
  # each call is a no-op on the wrong platform (and on host, where the
  # NIF is not loaded). The coordinator therefore does not need a
  # per-platform branch — it just asks both. On iOS the Android drain
  # returns [] and vice versa.
  defp sweep_native do
    Mob.PostMortem.IOS.sweep() ++ Mob.PostMortem.Android.sweep()
  end
end
