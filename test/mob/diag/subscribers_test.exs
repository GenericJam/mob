defmodule Mob.Diag.SubscribersTest do
  # async: false — this starts distribution for the whole VM, and kills the
  # subscriber registry every diagnostic test shares.
  use ExUnit.Case, async: false

  alias Mob.Defect.{Bus, Capsule}
  alias Mob.Diag.Subscribers
  alias Mob.Event.{Address, Trace}
  alias Mob.Test.ProcessHelpers

  # A subscriber on a host shell must survive the host↔device connection
  # dropping: over `adb` the device cannot dial the host back, so the host
  # re-dials, and the shell it subscribed from has to keep receiving (MOB-304).
  # The peer's control channel is stdio, so disconnecting it from this node
  # neither kills it nor needs distribution to drive it.

  setup_all do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
    started? = not Node.alive?()

    # A unique name: a fixed one collides with any other VM running this file
    # (parallel CI jobs, another checkout) or with this VM's previous run while
    # epmd still holds it, and `Node.start` then fails with :nodistribution.
    if started? do
      name = List.to_atom(:peer.random_name(~c"mob_subscribers_test") ++ ~c"@127.0.0.1")
      {:ok, _} = Node.start(name, :longnames)
    end

    on_exit(fn -> if started?, do: Node.stop() end)
    :ok
  end

  setup do
    on_exit(fn -> Application.delete_env(:mob, :subscriber_park_ms) end)
    {peer, node} = start_peer()
    sink = :peer.call(peer, :erlang, :spawn, [:timer, :sleep, [:infinity]])

    on_exit(fn ->
      Bus.unsubscribe(sink)
      Trace.unsubscribe(sink)
    end)

    %{peer: peer, node: node, sink: sink}
  end

  test "a subscriber whose node disconnects is parked, and receives again once it reconnects",
       %{peer: peer, node: node, sink: sink} do
    {:ok, _} = Bus.subscribe(sink)
    :ok = Trace.subscribe(sink, &(&1.id == :wanted))

    disconnect(node, sink)
    assert %{defect_bus: 1, event_trace: 1} = Subscribers.health().parked

    Bus.emit(capsule(:while_parked))
    Mob.Event.dispatch(self(), address(:wanted), :tap, nil)

    true = Node.connect(node)
    ProcessHelpers.eventually(fn -> published?(sink) and no_parked?() end)

    delivered = capsule(:after_reconnect)
    Bus.emit(delivered)
    Mob.Event.dispatch(self(), address(:unwanted), :tap, nil)
    Mob.Event.dispatch(self(), address(:wanted), :tap, nil)

    # Exactly these: nothing sent while parked (which would have dialled the
    # node and arrived first), and the trace filter survived parking.
    wanted = address(:wanted)

    ProcessHelpers.eventually(fn ->
      match?([{:mob_defect, ^delivered}, {:mob_trace, ^wanted, :tap, nil}], mailbox(peer, sink))
    end)
  end

  test "a parked subscriber that exited while its node was away is pruned when it reconnects",
       %{peer: peer, node: node, sink: sink} do
    {:ok, _} = Bus.subscribe(sink)
    disconnect(node, sink)

    :peer.call(peer, :erlang, :exit, [sink, :kill])
    true = Node.connect(node)

    ProcessHelpers.eventually(fn ->
      sink not in Bus.subscribers() and Subscribers.health().parked.defect_bus == 0
    end)
  end

  test "a parked subscriber whose node stays away past the grace period is dropped",
       %{node: node, sink: sink} do
    Application.put_env(:mob, :subscriber_park_ms, 20)
    {:ok, _} = Bus.subscribe(sink)
    true = :erlang.disconnect_node(node)

    ProcessHelpers.eventually(fn ->
      sink not in Bus.subscribers() and Subscribers.health().parked.defect_bus == 0 and
        node not in Node.list(:connected)
    end)

    # Dropped from state, so its node's return has nothing to restore.
    true = Node.connect(node)
    {:ok, _} = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    refute sink in Bus.subscribers()
  end

  test "a parked subscriber survives the registry dying", %{peer: peer, node: node, sink: sink} do
    {:ok, _} = Bus.subscribe(sink)
    disconnect(node, sink)
    kill_registry()

    {:ok, _} = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    assert Subscribers.health().parked.defect_bus == 1

    true = Node.connect(node)
    ProcessHelpers.eventually(fn -> sink in Bus.subscribers() end)

    delivered = capsule(:after_registry_restart)
    Bus.emit(delivered)
    ProcessHelpers.eventually(fn -> mailbox(peer, sink) == [{:mob_defect, delivered}] end)
  end

  # MOB-303 × MOB-304: the first journal design cleared everything up to the
  # newest delivered capsule, so a subscriber resumed from parking (which saw
  # nothing while away) "observed" an exit emitted during its absence the
  # moment any later capsule reached it.
  @tag :tmp_dir
  test "a journaled exit emitted while the only subscriber is parked survives its resumption",
       %{peer: peer, node: node, sink: sink, tmp_dir: tmp_dir} do
    Mob.PostMortem.Registry.reset()
    Mob.PostMortem.Journal.reset()
    on_exit(&Mob.PostMortem.Journal.reset/0)
    path = Path.join(tmp_dir, "journal.etf")

    {:ok, _} = Bus.subscribe(sink)
    disconnect(node, sink)
    assert Bus.subscribers() == []

    exit = %{reason_code: 4, pid: 7, timestamp_ms: 7, process_name: "app", description: "crash"}

    Mob.PostMortem.Journal.sweep(
      fn -> path end,
      :android,
      [{"exit-7", exit}],
      &Mob.Defect.appexit_capsule/1
    )

    true = Node.connect(node)
    ProcessHelpers.eventually(fn -> published?(sink) and no_parked?() end)
    later = capsule(:after_resume)
    Bus.emit(later)
    ProcessHelpers.eventually(fn -> mailbox(peer, sink) == [{:mob_defect, later}] end)

    assert [{:android, "exit-7", _}] = Mob.PostMortem.Journal.read(path).entries
  end

  test "a node that reconnects while the registry is down is picked up by the next one",
       %{node: node, sink: sink} do
    {:ok, _} = Bus.subscribe(sink)
    disconnect(node, sink)
    kill_registry()

    true = Node.connect(node)
    {:ok, _} = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)

    assert sink in Bus.subscribers()
    assert Subscribers.health().parked.defect_bus == 0
  end

  test "a registry started before this code (a hot push) parks and resumes too",
       %{node: node, sink: sink} do
    {:ok, _} = Bus.subscribe(sink)

    # What a 0.9.5 registry looks like once this code is loaded under it: it
    # never subscribed to node events.
    :sys.replace_state(Subscribers, fn state ->
      :ok = :net_kernel.monitor_nodes(false, node_type: :all)
      Process.delete(:mob_monitors_nodes)
      state
    end)

    disconnect(node, sink)
    true = Node.connect(node)
    ProcessHelpers.eventually(fn -> sink in Bus.subscribers() end)
  end

  test "a subscriber on a hidden node resumes too" do
    {peer, node} = start_peer([~c"-hidden"])
    sink = :peer.call(peer, :erlang, :spawn, [:timer, :sleep, [:infinity]])
    {:ok, _} = Bus.subscribe(sink)
    on_exit(fn -> Bus.unsubscribe(sink) end)
    assert node in Node.list(:hidden)

    disconnect(node, sink)
    true = Node.connect(node)
    ProcessHelpers.eventually(fn -> sink in Bus.subscribers() end)
  end

  defp start_peer(args \\ []) do
    {:ok, peer, node} =
      :peer.start(%{
        name: :peer.random_name(),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie()) | args]
      })

    on_exit(fn -> :peer.stop(peer) end)
    true = Node.connect(node)
    # `global` handshakes with every new node, from both ends; a disconnect
    # mid-handshake is re-dialled by its pending messages, which would unpark
    # the subscriber.
    :ok = :global.sync()
    :ok = :peer.call(peer, :global, :sync, [])
    {peer, node}
  end

  # Parking records the subscriber before unpublishing it from each topic in
  # turn, so wait for all of it.
  defp disconnect(node, sink) do
    true = :erlang.disconnect_node(node)

    ProcessHelpers.eventually(fn ->
      not published?(sink) and Subscribers.health().parked.defect_bus == 1
    end)
  end

  defp published?(sink),
    do: Enum.any?([:defect_bus, :event_trace], &List.keymember?(Subscribers.list(&1), sink, 0))

  defp no_parked?, do: Enum.all?(Subscribers.health().parked, fn {_topic, n} -> n == 0 end)

  defp kill_registry do
    registry = Process.whereis(Subscribers)
    Process.exit(registry, :kill)
    ProcessHelpers.await_exit(registry)
  end

  defp mailbox(peer, pid) do
    {:messages, messages} = :peer.call(peer, :erlang, :process_info, [pid, :messages])
    messages
  end

  defp capsule(name) do
    Capsule.new(
      kind: :invariant,
      owner: :mob,
      severity: :critical,
      fingerprint_key: %{invariant: name}
    )
  end

  defp address(id), do: Address.new(screen: X, widget: :button, id: id)
end
