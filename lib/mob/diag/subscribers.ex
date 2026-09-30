defmodule Mob.Diag.Subscribers do
  @moduledoc """
  Who is listening to a diagnostic stream: `Mob.Defect.Bus` (`:defect_bus`) and
  `Mob.Event.Trace` (`:event_trace`).

  The write paths read the list from `:persistent_term` and `send/2` to each pid,
  with no process on the hot path. This process only changes the list, and
  monitors every subscriber so one that exits (or whose node disconnects) is
  pruned.

  It is separate from the stores' table owners on purpose. An owner that also
  did subscriber bookkeeping could lose every recorded defect to a bug in that
  bookkeeping. And if this process dies, the published lists survive in
  `:persistent_term`, so delivery continues, and the next instance re-monitors
  every pid it finds there.

  A subscriber is any pid, including one on a connected node:
  `:rpc.call(node, Mob.Defect.Bus, :subscribe, [self()])` subscribes the calling
  shell, where passing no pid would subscribe the short-lived process `:rpc`
  runs the call in.
  """

  use GenServer

  @index {__MODULE__, :topics}

  @doc false
  @spec subscribe(atom(), pid(), term()) :: {:ok, reference()}
  def subscribe(topic, pid, meta) when is_atom(topic) and is_pid(pid),
    do: call({:subscribe, topic, pid, meta})

  @doc false
  @spec unsubscribe(atom(), pid()) :: :ok
  def unsubscribe(topic, pid) when is_atom(topic) and is_pid(pid),
    do: call({:unsubscribe, topic, pid})

  @doc false
  @spec clear(atom()) :: :ok
  def clear(topic) when is_atom(topic), do: call({:clear, topic})

  @doc "The subscribers of `topic` as `{pid, meta}` pairs. No process involved."
  @spec list(atom()) :: [{pid(), term()}]
  def list(topic), do: :persistent_term.get(key(topic), [])

  @doc false
  @spec health() :: map()
  def health do
    topics = :persistent_term.get(@index, [])

    %{
      process: Process.whereis(__MODULE__),
      topics: Map.new(topics, &{&1, length(list(&1))})
    }
  end

  defp call(request) do
    pid =
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    GenServer.call(pid, request, :infinity)
  end

  defp key(topic), do: {__MODULE__, topic}

  @impl GenServer
  def init(_opts) do
    # Rebuild from what an earlier instance published, so a restart keeps
    # pruning the subscribers it did not see arrive.
    subscribers =
      for topic <- :persistent_term.get(@index, []), into: %{} do
        {topic, Map.new(list(topic))}
      end

    monitors =
      for {_topic, pids} <- subscribers, {pid, _meta} <- pids, into: %{} do
        {pid, Process.monitor(pid)}
      end

    {:ok, %{subscribers: subscribers, monitors: monitors}}
  end

  @impl GenServer
  def handle_call({:subscribe, topic, pid, meta}, _from, state) do
    {ref, state} = monitor(state, pid)
    state = put_in(state, [:subscribers, Access.key(topic, %{}), pid], meta)
    publish(state, topic)
    {:reply, {:ok, ref}, state}
  end

  def handle_call({:unsubscribe, topic, pid}, _from, state) do
    state = update_in(state, [:subscribers, Access.key(topic, %{})], &Map.delete(&1, pid))
    publish(state, topic)
    {:reply, :ok, demonitor_if_unused(state, pid)}
  end

  def handle_call({:clear, topic}, _from, state) do
    pids = state.subscribers |> Map.get(topic, %{}) |> Map.keys()
    state = put_in(state, [:subscribers, topic], %{})
    publish(state, topic)
    {:reply, :ok, Enum.reduce(pids, state, &demonitor_if_unused(&2, &1))}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    touched = for {topic, pids} <- state.subscribers, Map.has_key?(pids, pid), do: topic
    state = %{state | monitors: Map.delete(state.monitors, pid)}

    state =
      Enum.reduce(touched, state, fn topic, acc ->
        acc = update_in(acc, [:subscribers, topic], &Map.delete(&1, pid))
        publish(acc, topic)
        acc
      end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp monitor(state, pid) do
    case state.monitors do
      %{^pid => ref} ->
        {ref, state}

      _ ->
        ref = Process.monitor(pid)
        {ref, put_in(state, [:monitors, pid], ref)}
    end
  end

  defp demonitor_if_unused(state, pid) do
    subscribed? = Enum.any?(state.subscribers, fn {_topic, pids} -> Map.has_key?(pids, pid) end)

    case state.monitors do
      %{^pid => ref} when not subscribed? ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: Map.delete(state.monitors, pid)}

      _ ->
        state
    end
  end

  defp publish(state, topic) do
    :persistent_term.put(key(topic), state.subscribers |> Map.get(topic, %{}) |> Map.to_list())
    topics = Map.keys(state.subscribers)
    if :persistent_term.get(@index, nil) != topics, do: :persistent_term.put(@index, topics)
  end
end
