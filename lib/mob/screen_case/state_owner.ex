defmodule Mob.ScreenCase.StateOwner do
  @moduledoc """
  Owns the `Mob.State` that concurrently running `Mob.ScreenCase` tests share.

  `Mob.State` is one globally named process over a globally named `:dets`
  table, so async screen tests cannot each start their own. Checking for it and
  starting it from every test raced: two tests saw no process, and the second
  start failed with `:already_started`. A store one test started was also
  stopped when that test ended, even while another test was still using it.

  Every checkout and check-in goes through this process, so they are
  serialised. The first checkout starts `Mob.State` against a throwaway
  `MOB_DATA_DIR`, overlapping checkouts share it, and the last check-in stops it
  and restores the variable. `Mob.ScreenCase` checks in from `on_exit`, which
  ExUnit runs before it moves on, so tests that run afterwards (including
  `async: false` ones that start `Mob.State` themselves) find it gone. A
  `Mob.State` something else already started is shared but never stopped here.
  Started on first use and unlinked, so it outlives any single test.
  """

  use GenServer

  @doc false
  @spec checkout() :: {:ok, reference()} | {:error, term()}
  def checkout, do: call(:checkout)

  @doc false
  @spec checkin(reference()) :: :ok
  def checkin(ref) when is_reference(ref), do: call({:checkin, ref})

  @doc false
  @spec start() :: {:ok, pid()}
  def start do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  # `:infinity` because a timed-out caller would exit while its queued request
  # still started or stopped the store afterwards.
  defp call(request) do
    {:ok, pid} = start()
    GenServer.call(pid, request, :infinity)
  end

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, idle()}
  end

  @impl GenServer
  def handle_call(:checkout, _from, state) do
    case ensure_store(state) do
      {:ok, state} ->
        ref = make_ref()
        {:reply, {:ok, ref}, %{state | holders: MapSet.put(state.holders, ref)}}

      {:error, reason, state} ->
        {:reply, {:error, reason}, release(state)}
    end
  end

  def handle_call({:checkin, ref}, _from, state) do
    holders = MapSet.delete(state.holders, ref)
    state = %{state | holders: holders}
    state = if MapSet.size(holders) == 0, do: release(state), else: state
    {:reply, :ok, state}
  end

  # The linked store exited: forget it so the next checkout starts a new one.
  @impl GenServer
  def handle_info({:EXIT, pid, _reason}, %{store: pid} = state),
    do: {:noreply, %{state | store: nil, owned?: false}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp idle, do: %{holders: MapSet.new(), store: nil, owned?: false, tmp: nil, prev_env: nil}

  defp ensure_store(%{store: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, state}, else: ensure_store(%{state | store: nil})
  end

  defp ensure_store(state) do
    case Process.whereis(Mob.State) do
      pid when is_pid(pid) ->
        {:ok, %{state | store: pid, owned?: false}}

      nil ->
        state = ensure_data_dir(state)

        case Mob.State.start_link() do
          {:ok, pid} -> {:ok, %{state | store: pid, owned?: true}}
          {:error, {:already_started, pid}} -> {:ok, %{state | store: pid, owned?: false}}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp ensure_data_dir(%{tmp: nil} = state) do
    tmp = Path.join(System.tmp_dir!(), "mob_screen_case_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev_env = System.get_env("MOB_DATA_DIR")
    System.put_env("MOB_DATA_DIR", tmp)
    %{state | tmp: tmp, prev_env: prev_env}
  end

  defp ensure_data_dir(state), do: state

  defp release(state) do
    if state.owned? and is_pid(state.store), do: stop_store(state.store)

    if state.tmp do
      restore_env(state.prev_env)
      File.rm_rf(state.tmp)
    end

    %{idle() | holders: state.holders}
  end

  # Any exit means the store is gone, which is what stopping it wants: it may
  # already be dead (`:noproc`) or die another way mid-stop (`:killed`). Letting
  # that crash the owner would skip restoring `MOB_DATA_DIR` below.
  defp stop_store(pid) do
    GenServer.stop(pid, :normal, :infinity)
  catch
    :exit, _reason -> :ok
  end

  defp restore_env(nil), do: System.delete_env("MOB_DATA_DIR")
  defp restore_env(value), do: System.put_env("MOB_DATA_DIR", value)
end
