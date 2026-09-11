defmodule Mob.PostMortem do
  @moduledoc """
  Collect the post-mortems the OS and the BEAM leave behind when a
  process dies, and put them onto `Mob.Defect.Bus` as capsules.

  Three sources, each in its own submodule:

  * `Mob.PostMortem.BeamCrashDump` — `erl_crash.dump` files (BEAM). Fully
    implemented; the substrate this module was written around.
  * `Mob.PostMortem.IOS` — MetricKit payloads (crash / hang / launch /
    CPU / memory / disk). Scaffolded; returns an empty list until the
    native pipe lands in a follow-up ticket. See its own moduledoc.
  * `Mob.PostMortem.Android` — `ApplicationExitInfo` history (ANR, crash,
    OOM, user kill). Same shape as iOS: scaffolded, follow-up.

  Nothing here runs automatically. An app opts in with
  `Mob.PostMortem.sweep()` from its `on_start`, or a developer / CI runs
  the equivalent `mix mob.post_mortems.sweep` task from the host. That
  matches the discipline the whole `Mob.Defect` subsystem enforces:
  mob owns the format and the bus but never becomes the collector.

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

  # iOS + Android scaffolds intentionally return `[]` today. They exist
  # as symbols so this coordinator does not have to grow a per-platform
  # branch every time a native source lands.
  defp sweep_native do
    Mob.PostMortem.IOS.sweep() ++ Mob.PostMortem.Android.sweep()
  end
end
