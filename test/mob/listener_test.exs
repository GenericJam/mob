defmodule Mob.ListenerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mob.Listener

  setup do
    case Process.whereis(Listener) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    :ok
  end

  defp start_listener do
    {:ok, pid} = Listener.start_link([])
    on_exit(fn -> stop_safely(pid) end)
    pid
  end

  # `if Process.alive?, do: GenServer.stop` races: the process can exit between
  # the check and the stop, and the :noproc exit then fails the test from inside
  # the on_exit runner.
  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  describe "handler/1 without a listener" do
    test "returns a tagged target unchanged" do
      target = {self(), :save}
      assert Listener.handler(target) == target
    end

    test "returns a bare pid unchanged" do
      assert Listener.handler(self()) == self()
    end
  end

  describe "handler/1 with a listener" do
    test "addresses native at the listener, not the screen" do
      listener = start_listener()
      assert {^listener, _envelope} = Listener.handler({self(), :save})
    end

    test "carries the screen and tag in the envelope" do
      start_listener()
      screen = self()
      assert {_listener, {:mob_route, ^screen, :save}} = Listener.handler({screen, :save})
    end

    test "a bare pid keeps the :ok tag native would have substituted" do
      start_listener()
      screen = self()
      assert {_listener, {:mob_route, ^screen, :ok}} = Listener.handler(screen)
    end

    test "a non-atom tag survives the envelope" do
      start_listener()
      screen = self()
      tag = {:list, "id", :select, 3}
      assert {_listener, {:mob_route, ^screen, ^tag}} = Listener.handler({screen, tag})
    end
  end

  describe "forwarding" do
    test "unwraps and delivers to the screen named in the envelope" do
      listener = start_listener()
      send(listener, {:tap, {:mob_route, self(), :save}})
      assert_receive {:tap, :save}
    end

    test "every native event atom uses the same clause" do
      listener = start_listener()

      for event <- [:tap, :change, :focus, :blur, :submit, :dismiss, :select, :scroll, :drag] do
        send(listener, {event, {:mob_route, self(), :tag}})
        assert_receive {^event, :tag}
      end
    end

    test "delivers to the screen in the envelope, not the current one" do
      # The MOB-107 shape: an event registered by one screen must not land in
      # whichever screen happens to be active now.
      listener = start_listener()
      test_pid = self()

      other =
        spawn(fn ->
          receive do: (msg -> send(test_pid, {:other_got, msg}))
        end)

      send(listener, {:tap, {:mob_route, other, :belongs_to_other}})

      assert_receive {:other_got, {:tap, :belongs_to_other}}
      refute_receive {:tap, :belongs_to_other}
    end

    test "an event for a dead screen is dropped, not redirected" do
      listener = start_listener()
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      send(listener, {:tap, {:mob_route, dead, :gone}})

      # Still alive and still serving — a dead target must not take it down.
      send(listener, {:tap, {:mob_route, self(), :mine}})
      assert_receive {:tap, :mine}
      assert Process.alive?(listener)
    end

    test "an unmodelled routed shape is logged, not silently dropped" do
      # A native sender with an arity the listener does not model delivers
      # nothing to the screen: the control just stops working, with no crash.
      # The log line is the only way that becomes visible.
      listener = start_listener()

      log =
        capture_log(fn ->
          send(listener, {:change, {:mob_route, self(), :tag}, :extra, :unmodelled})
          send(listener, {:tap, {:mob_route, self(), :ping}})
          assert_receive {:tap, :ping}
        end)

      assert log =~ "unhandled routed event"
    end

    test "an unrecognised message is ignored" do
      listener = start_listener()
      send(listener, :garbage)
      send(listener, {:tap, :not_an_envelope})
      send(listener, {:tap, {:mob_route, self(), :still_working}})
      assert_receive {:tap, :still_working}
      assert Process.alive?(listener)
    end
  end

  describe "renderer round trip" do
    # Stands in for the native layer: records what register_tap/1 was given, and
    # replays it the way mob_send_tap does — {event, tag} to the stored pid.
    defmodule FakeNative do
      def start, do: Agent.start(fn -> [] end, name: __MODULE__)
      def registered, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

      def clear_taps, do: :ok
      def set_transition(_), do: :ok
      def set_root(_), do: :ok

      def register_tap(target) do
        Agent.update(__MODULE__, &[target | &1])
        length(Agent.get(__MODULE__, & &1)) - 1
      end

      # mob_send_tap / mob_send_event / mob_send_scrolled_past: {event, tag}.
      def fire(handle, event) do
        {pid, tag} = target(handle)
        send(pid, {event, tag})
      end

      # mob_send_change / compose / swipe / scroll / drag / pinch / rotate /
      # pointer_move: {event, tag, payload}. Modelling only the 2-tuple family
      # is what let the missing 3-tuple clause pass review the first time.
      def fire(handle, event, payload) do
        {pid, tag} = target(handle)
        send(pid, {event, tag, payload})
      end

      defp target(handle) do
        case Enum.at(registered(), handle) do
          {pid, tag} -> {pid, tag}
          pid when is_pid(pid) -> {pid, :ok}
        end
      end
    end

    setup do
      case Process.whereis(FakeNative) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end

      FakeNative.start()
      :ok
    end

    defp button(tag),
      do: %{type: :button, props: %{text: "go", on_tap: {self(), tag}}, children: []}

    test "with no listener, native is given the screen directly" do
      screen = self()
      Mob.Renderer.render(button(:save), :ios, FakeNative, :none)
      assert [{^screen, :save}] = FakeNative.registered()
    end

    test "with a listener, native is given the listener and the screen moves into the tag" do
      listener = start_listener()
      screen = self()
      Mob.Renderer.render(button(:save), :ios, FakeNative, :none)
      assert [{^listener, {:mob_route, ^screen, :save}}] = FakeNative.registered()
    end

    test "a native tap reaches the owning screen unchanged" do
      start_listener()
      Mob.Renderer.render(button(:save), :ios, FakeNative, :none)

      # What mob_send_tap does on a real tap.
      FakeNative.fire(0, :tap)

      # The screen sees exactly what it saw before the listener existed.
      assert_receive {:tap, :save}
    end

    test "a payload-free event round trips" do
      start_listener()
      screen = self()

      tree = %{type: :text_field, props: %{on_submit: {screen, :submitted}}, children: []}
      Mob.Renderer.render(tree, :ios, FakeNative, :none)

      FakeNative.fire(0, :submit)
      assert_receive {:submit, :submitted}
    end

    test "a value-carrying event round trips with its payload" do
      # The regression this file missed: mob_send_change sends {change, tag,
      # value}, so a listener that only unwraps {event, tag} drops every text
      # field, toggle, slider and tab selection silently.
      start_listener()
      screen = self()

      tree = %{type: :text_field, props: %{on_change: {screen, :email}}, children: []}
      Mob.Renderer.render(tree, :ios, FakeNative, :none)

      FakeNative.fire(0, :change, "hello@example.com")
      assert_receive {:change, :email, "hello@example.com"}
    end

    test "every 3-tuple native sender round trips" do
      start_listener()
      screen = self()

      tree = %{
        type: :canvas,
        props: %{
          on_change: {screen, :changed},
          on_compose: {screen, :composed},
          on_swipe: {screen, :swiped},
          on_scroll: {screen, :scrolled},
          on_drag: {screen, :dragged},
          on_pinch: {screen, :pinched},
          on_rotate: {screen, :rotated},
          on_pointer_move: {screen, :moved}
        },
        children: []
      }

      Mob.Renderer.render(tree, :ios, FakeNative, :none)

      handles =
        for {target, i} <- Enum.with_index(FakeNative.registered()),
            into: %{},
            do: {elem(elem(target, 1), 2), i}

      for {event, tag} <- [
            change: :changed,
            compose: :composed,
            swipe: :swiped,
            scroll: :scrolled,
            drag: :dragged,
            pinch: :pinched,
            rotate: :rotated,
            pointer_move: :moved
          ] do
        FakeNative.fire(handles[tag], event, %{payload: tag})
        assert_receive {^event, ^tag, %{payload: ^tag}}
      end
    end
  end

  describe "ensure_started/0" do
    test "starts the listener when missing and is a no-op when present" do
      refute Listener.running?()
      assert :ok = Listener.ensure_started()
      # Registered before the assertions below, so a failure cannot leak a
      # listener into unrelated test files.
      on_exit(fn -> if pid = Process.whereis(Listener), do: stop_safely(pid) end)

      assert Listener.running?()
      pid = Process.whereis(Listener)
      assert :ok = Listener.ensure_started()
      assert Process.whereis(Listener) == pid
    end

    test "does not link to the caller" do
      test_pid = self()

      caller =
        spawn(fn ->
          Listener.ensure_started()
          send(test_pid, :started)
          receive do: (:die -> exit(:boom))
        end)

      assert_receive :started
      listener = Process.whereis(Listener)
      on_exit(fn -> stop_safely(listener) end)

      ref = Process.monitor(caller)
      send(caller, :die)
      assert_receive {:DOWN, ^ref, :process, ^caller, _}

      assert Process.alive?(listener)
    end
  end
end
