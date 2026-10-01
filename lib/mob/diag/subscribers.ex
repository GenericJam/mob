defmodule Mob.Diag.Subscribers do
  @moduledoc """
  Who is listening to a diagnostic stream: `Mob.Defect.Bus` (`:defect_bus`) and
  `Mob.Event.Trace` (`:event_trace`).

  The write paths read the list from `:persistent_term` and `send/2` to each pid,
  with no process on the hot path. This process only changes the list, and
  monitors every subscriber so one that exits is pruned.

  A subscriber on another node whose connection drops (`:noconnection`) is
  *parked*, not pruned: it leaves the published list, so no emit sends to it
  (a `send/2` to an unconnected node dials it, which over `adb` cannot
  succeed), but its topics and meta are kept. When its node reconnects it is
  monitored again and republished, so a host shell that re-dials the device
  keeps receiving without re-subscribing; if the pid died meanwhile, the new
  monitor prunes it. A parked subscriber whose node stays away for
  `config :mob, :subscriber_park_ms` (default 10 minutes) is dropped.

  It is separate from the stores' table owners on purpose. An owner that also
  did subscriber bookkeeping could lose every recorded defect to a bug in that
  bookkeeping. And if this process dies, the published lists and the parked
  subscribers survive in `:persistent_term`, so delivery continues, and the
  next instance re-monitors every pid it finds there.

  A subscriber is any pid, including one on a connected node:
  `:rpc.call(node, Mob.Defect.Bus, :subscribe, [self()])` subscribes the calling
  shell, where passing no pid would subscribe the short-lived process `:rpc`
  runs the call in.
  """

  use GenServer

  require Logger

  @index {__MODULE__, :topics}
  @parked {__MODULE__, :parked}
  @default_park_ms :timer.minutes(10)

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

  @doc """
  The subscribers of `topic` as `{pid, meta}` pairs, read from
  `:persistent_term` with no process involved.

  The first read in a VM that has never started this registry starts it once,
  so subscribers an older `mob` left behind (after a hot push) are adopted
  rather than silently dropped. Every later read is a lookup. This never
  raises: it sits under every `Mob.Event.dispatch/4`, so if the registry cannot
  be started the read answers from what is published.
  """
  @spec list(atom()) :: [{pid(), term()}]
  def list(topic) do
    case :persistent_term.get(key(topic), nil) do
      nil ->
        if :persistent_term.get(@index, nil) == nil, do: adopt_legacy()
        published(topic)

      subscribers ->
        subscribers
    end
  end

  defp adopt_legacy do
    call(:sync)
  catch
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    kind, reason ->
      Logger.warning("[Mob.Diag.Subscribers] could not start: #{Exception.format(kind, reason)}")
  end

  @doc false
  @spec health() :: map()
  def health do
    topics = :persistent_term.get(@index, [])

    parked =
      @parked
      |> :persistent_term.get(%{})
      |> Enum.flat_map(fn {_pid, {_deadline, parked_topics}} -> Map.keys(parked_topics) end)
      |> Enum.frequencies()

    %{
      process: Process.whereis(__MODULE__),
      topics: Map.new(topics, &{&1, length(published(&1))}),
      parked: Map.new(topics, &{&1, Map.get(parked, &1, 0)})
    }
  end

  defp published(topic), do: :persistent_term.get(key(topic), [])

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
    # Before reading `Node.list/1` below, so a node that comes up in between
    # is not missed.
    ensure_node_monitor()
    parked = parked()

    # Rebuild from what an earlier instance published, so a restart keeps
    # pruning the subscribers it did not see arrive. The first instance in a VM
    # adopts what an older `mob` kept instead, so a hot push onto this version
    # keeps delivering to subscribers registered before it. A predecessor
    # killed between parking a pid and unpublishing it left it in both; parked
    # wins, so this does not dial its node.
    subscribers =
      case :persistent_term.get(@index, nil) do
        nil ->
          legacy_subscribers()

        topics ->
          for topic <- topics,
              into: %{},
              do: {topic, topic |> published() |> Map.new() |> Map.drop(Map.keys(parked))}
      end

    monitors =
      for {_topic, pids} <- subscribers, {pid, _meta} <- pids, into: %{} do
        {pid, Process.monitor(pid)}
      end

    state = %{subscribers: subscribers, monitors: monitors}
    for topic <- Map.keys(subscribers), do: publish(state, topic)

    if :persistent_term.get(@index, nil) == nil,
      do: :persistent_term.put(@index, Map.keys(subscribers))

    # A node that reconnected while no registry was running sent its
    # `:nodeup` to nobody.
    connected = Node.list(:connected)
    now = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(parked, state, fn {pid, {deadline, _topics}}, acc ->
        if node(pid) in connected do
          unpark(acc, pid)
        else
          Process.send_after(self(), {:park_expired, pid}, max(deadline - now, 0))
          acc
        end
      end)

    {:ok, state}
  end

  # Where `mob` 0.9.4 and earlier kept them: the defect bus's cached pid list,
  # and `Mob.Event.Trace`'s `{pid, filter}` table. Anything unexpected there is
  # skipped: this runs in `init/1`, and a registry that cannot start would take
  # every later subscribe with it.
  defp legacy_subscribers,
    do: %{defect_bus: legacy_bus(), event_trace: legacy_tracers()}

  defp legacy_bus do
    case :persistent_term.get(:mob_defect_subscribers, []) do
      pids when is_list(pids) -> for pid <- pids, is_pid(pid), into: %{}, do: {pid, nil}
      _other -> %{}
    end
  end

  # The table belonged to whichever process called the old `Trace.start/0`, so
  # it can vanish between any two reads.
  defp legacy_tracers do
    for {pid, filter} <- :ets.tab2list(:mob_event_trace),
        is_pid(pid) and (is_nil(filter) or is_function(filter, 1)),
        into: %{},
        do: {pid, filter}
  rescue
    ArgumentError -> %{}
  end

  @impl GenServer
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call({:subscribe, topic, pid, meta}, _from, state) do
    state = if Map.has_key?(parked(), pid), do: unpark(state, pid), else: state
    {ref, state} = monitor(state, pid)
    state = put_in(state, [:subscribers, Access.key(topic, %{}), pid], meta)
    publish(state, topic)
    {:reply, {:ok, ref}, state}
  end

  def handle_call({:unsubscribe, topic, pid}, _from, state) do
    state = update_in(state, [:subscribers, Access.key(topic, %{})], &Map.delete(&1, pid))
    publish(state, topic)
    forget_parked([pid], topic)
    {:reply, :ok, demonitor_if_unused(state, pid)}
  end

  def handle_call({:clear, topic}, _from, state) do
    pids = state.subscribers |> Map.get(topic, %{}) |> Map.keys()
    state = put_in(state, [:subscribers, topic], %{})
    publish(state, topic)
    forget_parked(Map.keys(parked()), topic)
    {:reply, :ok, Enum.reduce(pids, state, &demonitor_if_unused(&2, &1))}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, %{monitors: monitors} = state)
      when :erlang.map_get(pid, monitors) == ref do
    state = %{state | monitors: Map.delete(monitors, pid)}

    cond do
      reason != :noconnection ->
        {:noreply, drop_active(state, pid)}

      # The connection came back before this `:DOWN` was handled, so its
      # `:nodeup` found nothing parked. A monitor now is accurate.
      node(pid) in Node.list(:connected) ->
        {:noreply, put_in(state, [:monitors, pid], Process.monitor(pid))}

      true ->
        {:noreply, park(state, pid)}
    end
  end

  def handle_info({:nodeup, node, _info}, state) do
    pids = for {pid, _parked} <- parked(), node(pid) == node, do: pid
    {:noreply, Enum.reduce(pids, state, &unpark(&2, &1))}
  end

  def handle_info({:park_expired, pid}, state) do
    case parked() do
      %{^pid => {deadline, _topics}} = parked ->
        if deadline <= System.monotonic_time(:millisecond),
          do: put_parked(Map.delete(parked, pid))

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp park(state, pid) do
    ensure_node_monitor()
    topics = for {topic, %{^pid => meta}} <- state.subscribers, into: %{}, do: {topic, meta}
    park_ms = Application.get_env(:mob, :subscriber_park_ms, @default_park_ms)
    deadline = System.monotonic_time(:millisecond) + park_ms
    Process.send_after(self(), {:park_expired, pid}, park_ms)
    # Parked before unpublished, so `health/0` never sees it as neither.
    put_parked(Map.put(parked(), pid, {deadline, topics}))
    drop_active(state, pid)
  end

  # Monitoring first: a pid that died while its node was away answers
  # `:noproc`, and that `:DOWN` prunes it.
  defp unpark(state, pid) do
    {{_deadline, topics}, parked} = Map.pop!(parked(), pid)
    state = put_in(state, [:monitors, pid], Process.monitor(pid))

    state =
      Enum.reduce(topics, state, fn {topic, meta}, acc ->
        acc = put_in(acc, [:subscribers, Access.key(topic, %{}), pid], meta)
        publish(acc, topic)
        acc
      end)

    put_parked(parked)
    state
  end

  defp drop_active(state, pid) do
    Enum.reduce(state.subscribers, state, fn {topic, pids}, acc ->
      if Map.has_key?(pids, pid) do
        acc = update_in(acc, [:subscribers, topic], &Map.delete(&1, pid))
        publish(acc, topic)
        acc
      else
        acc
      end
    end)
  end

  defp forget_parked(pids, topic) do
    pids
    |> Enum.reduce(parked(), fn pid, acc ->
      case acc do
        %{^pid => {deadline, topics}} ->
          rest = Map.delete(topics, topic)
          if rest == %{}, do: Map.delete(acc, pid), else: Map.put(acc, pid, {deadline, rest})

        _ ->
          acc
      end
    end)
    |> put_parked()
  end

  # Parked subscribers live only in `:persistent_term`, beside the published
  # lists: a registry that dies while one is parked does not lose it, and the
  # state of a registry an older `mob` started keeps its shape after a hot
  # push onto this code.
  defp parked, do: :persistent_term.get(@parked, %{})

  defp put_parked(parked) do
    if parked != parked(), do: :persistent_term.put(@parked, parked)
    :ok
  end

  # A registry an older `mob` started never subscribed in its `init/1`. The
  # flag is per process, and each subscription would deliver its own
  # `:nodeup`s.
  defp ensure_node_monitor do
    if Process.get(:mob_monitors_nodes) != true do
      :ok = :net_kernel.monitor_nodes(true, node_type: :all)
      Process.put(:mob_monitors_nodes, true)
    end
  end

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
