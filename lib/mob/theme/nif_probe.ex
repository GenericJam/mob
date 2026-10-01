defmodule Mob.Theme.NifProbe do
  @moduledoc """
  Serialises `Mob.Theme`'s native probes: each probe runs inside this locally
  registered process, one at a time, so concurrent first theme calls share one
  `mob_nif` load attempt instead of each retrying it.

  Not `:global.trans/3`: it backs off by sleeping under contention, which
  stalls concurrent first theme calls on render paths, and it releases on the
  node name captured at acquire time, so `Mob.Dist` starting distribution
  during a probe leaves the lock held for good and every later probe blocks
  (MOB-311). Started on first use and unlinked, like `Mob.DNS.Seeder`, because
  `mob` has no supervision tree of its own.
  """

  use GenServer

  @doc false
  @spec run((-> result)) :: result when result: term()
  def run(probe), do: call(probe, 1)

  # The probe runs here rather than in the caller, so a caller that dies
  # while queued holds nothing. `Mob.Theme` passes a probe that rescues and
  # catches everything, so it cannot take this process down. `:noproc` means
  # `start/0` handed back a process that died before the call reached it;
  # one retry against a fresh one (a probe re-checks the status it acts on).
  defp call(probe, retries) do
    {:ok, pid} = start()
    GenServer.call(pid, {:run, probe}, :infinity)
  catch
    :exit, {:noproc, _} when retries > 0 -> call(probe, retries - 1)
  end

  @doc false
  @spec start() :: {:ok, pid()}
  def start do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:run, probe}, _from, state), do: {:reply, probe.(), state}
end
