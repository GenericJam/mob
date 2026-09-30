defmodule Mob.Diag.Heir do
  @moduledoc """
  Holds diagnostic tables while their owner is down, and starts the next owner.

  Every `Mob.Diag.Store` table names this process as its ETS heir, with the
  store as heir data, so a store owner that dies hands its tables — rows intact
  and still writable, since they are public — here instead of deleting them.
  The heir then starts a replacement owner, which takes them back with
  `give_back/2`. Nothing else would: `Mob.Diag.Store.ensure/1` only checks
  that a store's tables exist, and they do, so without a restart the heir held
  them until it died too and took every row with it (MOB-302).

  The restart runs in a process of its own. The new owner's setup calls
  `give_back/2`, which the heir could not answer while starting it, and a
  store that fails to start must not take the heir down. Started on first use
  and unlinked, like the owners.
  """

  use GenServer

  alias Mob.Diag.Store

  @doc false
  @spec ensure() :: pid()
  def ensure do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc false
  @spec give_back(atom(), pid()) :: :ok
  def give_back(table, to), do: GenServer.call(ensure(), {:give_back, table, to}, :infinity)

  # State: each store's owner generation (`Mob.Diag.Store.owner_generation/1`)
  # when its owner was last restarted.
  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:give_back, table, to}, _from, restarted) do
    if :ets.info(table, :owner) == self(), do: :ets.give_away(table, to, :returned)
    {:reply, :ok, restarted}
  end

  # A dying owner hands over its tables one message apiece, so restart only
  # when an owner has finished starting since the last restart. That is one
  # restart per death, and none for an owner that died during setup: a store
  # whose setup crashes after taking its tables back would otherwise restart
  # forever. A generation of `nil` means no owner of it ever finished setup,
  # which is also what heir data naming anything but a store looks like.
  @impl GenServer
  def handle_info({:"ETS-TRANSFER", _table, from, store}, restarted) do
    generation = Store.owner_generation(store)

    if generation == nil or Map.get(restarted, store) == generation do
      {:noreply, restarted}
    else
      spawn(fn -> restart(store, from) end)
      {:noreply, Map.put(restarted, store, generation)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # An exiting process passes its tables on before its monitors fire, so once
  # the old owner is down every table is here and the new owner's setup takes
  # them all back.
  defp restart(store, old_owner) do
    ref = Process.monitor(old_owner)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end

    Store.restart(store)
  end
end
