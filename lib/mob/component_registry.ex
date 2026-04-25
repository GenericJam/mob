defmodule Mob.ComponentRegistry do
  @moduledoc false
  # ETS-backed registry mapping {screen_pid, id, module} → component_pid.
  # Started by Mob.App. Components register themselves on mount and deregister
  # on terminate. The screen calls reconcile/2 after each render to stop
  # components that have left the tree.

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a component process. Raises if the same {screen_pid, id, module}
  is already registered (duplicate id on the same screen).
  """
  @spec register(pid(), atom(), module(), pid()) :: :ok
  def register(screen_pid, id, module, component_pid) do
    key = {screen_pid, id, module}

    case :ets.lookup(@table, key) do
      [{^key, existing}] when existing != component_pid ->
        raise ArgumentError,
              "Mob.Component: duplicate id #{inspect(id)} for #{inspect(module)} on screen " <>
                "#{inspect(screen_pid)}. Component ids must be unique per screen."

      _ ->
        :ets.insert(@table, {key, component_pid})
        :ets.insert(@table, {component_pid, key})
        :ok
    end
  end

  @doc "Look up the component pid for a given key."
  @spec lookup(pid(), atom(), module()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(screen_pid, id, module) do
    case :ets.lookup(@table, {screen_pid, id, module}) do
      [{_, pid}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc "Remove a component registration (called from ComponentServer.terminate)."
  @spec deregister(pid(), atom(), module()) :: :ok
  def deregister(screen_pid, id, module) do
    key = {screen_pid, id, module}

    case :ets.lookup(@table, key) do
      [{_, pid}] ->
        :ets.delete(@table, key)
        :ets.delete(@table, pid)

      [] ->
        :ok
    end

    :ok
  end

  @doc """
  Stop any component processes for `screen_pid` whose {id, module} key is NOT
  in `active_keys`. Called after each render to reap components that left the tree.
  """
  @spec reconcile(pid(), MapSet.t()) :: :ok
  def reconcile(screen_pid, active_keys) do
    pattern = {{screen_pid, :_, :_}, :_}
    entries = :ets.match_object(@table, pattern)

    for {{^screen_pid, id, module}, pid} <- entries do
      unless MapSet.member?(active_keys, {id, module}) do
        :ets.delete(@table, {screen_pid, id, module})
        :ets.delete(@table, pid)
        Process.exit(pid, :shutdown)
      end
    end

    :ok
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end
end
