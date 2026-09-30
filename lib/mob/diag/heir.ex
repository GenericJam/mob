defmodule Mob.Diag.Heir do
  @moduledoc """
  Holds diagnostic tables while their owner is down.

  Every `Mob.Diag.Store` table names this process as its ETS heir, so a store
  owner that dies hands its tables — rows intact and still writable, since they
  are public — here instead of deleting them. The next owner takes them back
  with `give_back/2`. It does nothing else, so there is nothing in it to crash.
  Started on first use and unlinked, like the owners.
  """

  use GenServer

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

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:give_back, table, to}, _from, state) do
    if :ets.info(table, :owner) == self(), do: :ets.give_away(table, to, :returned)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:"ETS-TRANSFER", _table, _from, _data}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}
end
