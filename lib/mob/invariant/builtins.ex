defmodule Mob.Invariant.Builtins do
  @moduledoc """
  The checks the framework ships with, and an honest list of the ones it does
  not yet.

  MOB-156 names ten. Two are implemented here, because those two are the only
  ones observable from the BEAM today without hooks that do not exist. The rest
  are listed in `unimplemented/0` with what each needs, rather than being
  half-written against state nobody records — a registry advertising ten checks
  and running two would be exactly the kind of claim this epic keeps having to
  retract.

  The component-ownership one leads because three of the four agents in MOB-149
  named that class independently.
  """

  alias Mob.ComponentRegistry

  # Reported orphans per sample. A leak of a thousand is not a thousand times
  # more informative than a leak of eight, and every reported violation is an
  # ETS write on a teardown path.
  @max_reported 8

  @doc """
  Register the built-in checks. Idempotent.
  """
  @spec install() :: :ok
  def install do
    Mob.Invariant.register(:orphaned_component,
      at: :on_screen_stop,
      severity: :critical,
      check: &orphaned_component/1
    )

    Mob.Invariant.register(:dead_screen_in_nav,
      at: :periodic,
      severity: :critical,
      check: &dead_screen_in_nav/1
    )

    :ok
  end

  @doc """
  A live component whose owning screen process is dead.

  The registry keys entries by `{screen_pid, id, module}`, and reaping happens
  on reconcile or when the owner goes down. A component that is still alive
  under a dead owner is a leaked process holding a native handle — the class
  MOB-100 and its follow-ups kept re-fixing.

  Sampled at `:on_screen_stop`, which runs *inside* the screen that is stopping
  — so this never sees that screen's own components: it is still alive, running
  its own `terminate/2`. What it sees is what an *earlier* screen left behind,
  one teardown later. A check written expecting otherwise would silently never
  fire.

  Confirmation matters here more than anywhere: the router stops screens in a
  tight loop, so during a multi-screen reset this samples while the previous
  screen's components are mid-reap. Measured with the confirmation rule in
  place: 0 violations across 60 healthy teardowns.

  Reaping is defence in depth — a monitor `:DOWN`, an `:EXIT` from a linked
  screen, and `ComponentRegistry.reconcile/2` on the next paint — so no
  single-fault injection produces a real leak through the ordinary path. This
  check is verified against the orphan state itself rather than against a
  reproduction of the fault that would cause it. See the decision record.
  """
  @spec orphaned_component(map()) :: Mob.Invariant.result()
  def orphaned_component(_context) do
    case ComponentRegistry.table() do
      :undefined ->
        :ok

      table ->
        # A match spec rather than `tab2list/1`: the registry also holds a
        # `{pid, key}` reverse index, so listing the whole table copies twice
        # the rows this needs.
        orphans =
          table
          |> :ets.select([{{{:"$1", :"$2", :"$3"}, :"$4"}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}])
          |> Enum.filter(&orphan?/1)
          # Sorted before the cap, and this is load-bearing rather than tidy.
          # ETS `select` returns rows in an unspecified order that shifts as the
          # table grows, so taking an arbitrary eight reported a *different*
          # eight on every sample — each one a fresh fingerprint, so nothing
          # ever matured. Measured: 240 leaked rows across 60 teardowns and
          # zero confirmations. Sorting makes the same orphans the reported
          # ones until they are reaped.
          |> Enum.sort()

        # One violation per orphan, not one carrying a list. Each leaked
        # component then matures on its own: rolled together, the details change
        # whenever any orphan is added or reaped, the fingerprint changes with
        # them, and a leak that grows — one more orphan per navigation, which is
        # exactly what a broken reaping path produces — never confirms at all.
        #
        # Capped, and the cap is taken BEFORE building the maps: two `inspect/1`
        # calls per orphan for a thousand orphans ran inside `terminate/2` on the
        # router's synchronous stop path.
        case Enum.take(orphans, @max_reported) do
          [] ->
            :ok

          reported ->
            {:violations,
             Enum.map(reported, fn {screen_pid, id, module, component_pid} ->
               %{
                 screen: inspect(screen_pid),
                 component: inspect(component_pid),
                 id: id,
                 module: module
               }
             end)}
        end
    end
  end

  defp orphan?({screen_pid, _id, _module, component_pid})
       when is_pid(screen_pid) and is_pid(component_pid) do
    not Process.alive?(screen_pid) and Process.alive?(component_pid)
  end

  defp orphan?(_entry), do: false

  @doc """
  A dead screen still present in a router's navigation.

  Expects `%{router: pid}` in the context. A dead pid in the stack means a
  later `pop` returns to a corpse: the router restarts it and the user's state
  is gone, or the entry is skipped and the back stack lies about where it goes.
  """
  @spec dead_screen_in_nav(map()) :: Mob.Invariant.result()
  def dead_screen_in_nav(%{router: router}) when is_pid(router) do
    if Process.alive?(router) do
      dead =
        router
        |> Mob.Router.entries()
        |> Enum.filter(fn {_module, pid} -> is_pid(pid) and not Process.alive?(pid) end)
        |> Enum.take(@max_reported)
        |> Enum.map(fn {module, pid} -> %{module: module, pid: inspect(pid)} end)

      # One per dead entry, for the same reason as orphaned_component: a stack
      # that accumulates corpses would re-fingerprint on every sample and never
      # confirm.
      if dead == [], do: :ok, else: {:violations, dead}
    else
      :ok
    end
  end

  def dead_screen_in_nav(_context), do: :ok

  @doc """
  The eight checks MOB-156 names that are not implemented, and what each needs.

  Kept as data rather than prose so it can be asserted on: a test pins that the
  registry never silently claims to run one of these.
  """
  @spec unimplemented() :: [{atom(), String.t()}]
  def unimplemented do
    [
      {:handles_grow_across_navigation,
       "needs a per-navigation handle-allocation high-water mark; nothing records one"},
      {:component_received_handle_minus_one,
       "the -1 sentinel is produced natively and is not surfaced to the BEAM"},
      {:inactive_screen_committed_frame,
       "a paint runs in the screen, which does not know the router's current entry; " <>
         "asking mid-paint risks a call into a router that may be calling this screen"},
      {:event_for_replaced_handler_generation, "there is no handler generation token yet"},
      {:screen_crashed_past_restart_allowance,
       "the router restarts screens but does not count restarts per entry"},
      {:interactive_node_without_native_frame,
       "needs the native frame registry, which lives on the other side of the bridge"},
      {:sheet_dismissed_twice,
       "needs native sheet presentation state; the BEAM only sees its own removal"},
      {:loaded_modules_disagree_with_manifest,
       "mix mob.attest does this from the host (MOB-152); doing it on-device needs " <>
         "the manifest shipped into the app"}
    ]
  end
end
