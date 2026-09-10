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
  place: 0 violations across 60 healthy teardowns, and a real leak — the
  `{:DOWN, ...}` clause in `Mob.ComponentServer` disabled — still reported.
  """
  @spec orphaned_component(map()) :: Mob.Invariant.result()
  def orphaned_component(_context) do
    case ComponentRegistry.table() do
      :undefined ->
        :ok

      table ->
        # A match spec rather than `tab2list/1`: the registry also holds a
        # `{pid, key}` reverse index, so listing the whole table copies twice
        # the rows this needs. And `Enum.take` before `Enum.map` — building a
        # map with two `inspect/1` calls for every orphan and then keeping eight
        # made the check slowest exactly when a leak was largest, inside
        # `terminate/2`, on the router's synchronous stop path.
        raw =
          :ets.select(table, [
            {{{:"$1", :"$2", :"$3"}, :"$4"}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}
          ])

        orphans = Enum.filter(raw, &orphan?/1)

        case orphans do
          [] ->
            :ok

          _ ->
            details =
              orphans
              |> Enum.take(8)
              |> Enum.map(fn {screen_pid, id, module, component_pid} ->
                %{
                  screen: inspect(screen_pid),
                  component: inspect(component_pid),
                  id: id,
                  module: module
                }
              end)

            {:violation, %{orphans: details, count: length(orphans)}}
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
        |> Enum.map(fn {module, pid} -> %{module: module, pid: inspect(pid)} end)

      if dead == [], do: :ok, else: {:violation, %{dead_entries: dead, count: length(dead)}}
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
