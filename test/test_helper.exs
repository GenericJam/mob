# `Mob.ComponentRegistry` is a globally-named singleton that owns a named ETS
# table, and two `async: true` modules use it — `component_test.exs` and
# `component_server_test.exs`. Both setups do:
#
#     case start_supervised({Mob.ComponentRegistry, []}) do
#       {:ok, _pid} -> :ok
#       {:error, {:already_started, _pid}} -> :ok
#     end
#
# `start_supervised/1` ties the process to the *individual test*. So whichever
# test wins the race OWNS the registry, and ExUnit tears it — and its ETS table
# — down when that test ends, while a concurrent test in the other module is
# still using it. The loser dies on `:ets.lookup` against a table that no
# longer exists (MOB-119, and the mechanism behind MOB-154).
#
# Starting it here makes it owned by the RUN. Both setups then take the
# `:already_started` branch, nobody owns it, and nobody can tear it down
# mid-flight. Sharing is safe because every registry entry is keyed by a
# per-test `screen_pid`, so no two tests can collide on a key.
#
# `router_hot_path_test.exs` deliberately stops and restarts it to prove the
# hot path does not touch it. That is `async: false`, and ExUnit runs every
# async module before any sync one, so it cannot race the two above.
{:ok, _} = Mob.ComponentRegistry.start_link()

ExUnit.start(exclude: [:onboarding, :on_device])
