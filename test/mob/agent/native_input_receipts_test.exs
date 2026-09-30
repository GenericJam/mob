defmodule Mob.Agent.NativeInputReceiptsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mob.Agent.{Receipt, Receipts}
  alias Mob.Event.Address

  # MOB-305. A real tap reaches a screen as `{:tap, tag}` through handle_info/2,
  # delivered by the listener — never through Mob.Screen.dispatch/3 or
  # Mob.Event.dispatch/4. Verified on a Moto G: a tap that changed state left no
  # receipt and no trace. These send exactly what the listener forwards, straight
  # to the screen pid, and read back what was observed.

  defmodule Screen do
    @moduledoc false
    use Mob.Screen

    def mount(_p, _s, socket),
      do: {:ok, Mob.Socket.assign(socket, %{count: 0, typed: nil, row: nil})}

    def handle_info({:tap, :increment}, socket),
      do: {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}

    def handle_info({:tap, :boom}, _socket), do: raise("handler exploded")

    def handle_info({:change, :password, value}, socket),
      do: {:noreply, Mob.Socket.assign(socket, :typed, value)}

    def handle_info({:select, :rows, index}, socket),
      do: {:noreply, Mob.Socket.assign(socket, :row, index)}

    def handle_info(_message, socket), do: {:noreply, socket}

    def render(assigns),
      do: %{
        type: :text,
        props: %{text: "count=#{assigns.count} row=#{assigns.row}"},
        children: []
      }
  end

  defmodule Nif do
    @moduledoc false
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def platform, do: :ios
    def take_launch_notification, do: :none
    def unquote(:"$handle_undefined_function")(_f, _a), do: :ok
  end

  setup do
    Receipts.reset()
    {:ok, router} = Mob.Router.start_root(Screen, %{}, nif: Nif)
    on_exit(fn -> Mob.Test.ProcessHelpers.stop_root(router) end)
    %{screen: Mob.Screen.get_screen_pid(router)}
  end

  # What Mob.Listener does with a routed event, then wait for the screen to
  # have handled it.
  defp deliver(screen, message) do
    send(screen, message)
    :sys.get_state(screen)
    :ok
  end

  defp recent do
    [receipt] = Receipts.recent(1)
    receipt
  end

  test "a native tap that changes the frame is a verified action", %{screen: screen} do
    deliver(screen, {:tap, :increment})
    receipt = recent()

    assert {:tap, %Address{screen: Screen, widget: :button, id: :increment}} = receipt.event
    assert receipt.screen == Screen
    assert receipt.handler == {Screen, :handle_info, 2}
    assert [:dispatched, :handled, :assigns_changed, :frame_changed, :committed] = receipt.stages
    assert Receipt.effect(receipt) == :verified
    assert Receipt.owner(receipt) == :none
  end

  test "a tap the screen ignores is inert, and no frame is claimed committed", %{screen: screen} do
    # A forwarded message repaints through repaint_if_changed/1, which skips an
    # identical frame. Claiming :committed there would say a frame was handed
    # to the sender when none was.
    deliver(screen, {:tap, :nothing_matches})
    receipt = recent()

    assert receipt.stages == [:dispatched, :handled]
    assert Receipt.effect(receipt) == :inert
    assert Receipt.owner(receipt) == :app_code
  end

  test "a raising tap handler is recorded on the way out", %{screen: screen} do
    ref = Process.monitor(screen)

    capture_log(fn ->
      send(screen, {:tap, :boom})
      assert_receive {:DOWN, ^ref, :process, ^screen, _reason}
    end)

    receipt = recent()

    assert Receipt.effect(receipt) == :error
    assert Receipt.owner(receipt) == :app_code
    assert {:tap, %Address{id: :boom}} = receipt.event
    assert %{kind: :error, exception: RuntimeError, message: nil} = receipt.error
    assert receipt.error.at == {Screen, :handle_info, 2}
  end

  test "a text change is receipted by address, never with what was typed", %{screen: screen} do
    deliver(screen, {:change, :password, "hunter2-secret"})
    receipt = recent()

    assert {:change, %Address{widget: :text_field, id: :password}} = receipt.event
    assert Receipt.reached?(receipt, :assigns_changed)

    refute inspect(receipt, limit: :infinity) =~ "secret",
           "the receipt carried the field's value"
  end

  test "a tag that is not a valid address id is recorded as opaque", %{screen: screen} do
    deliver(screen, {:tap, make_ref()})
    assert recent().event == {:tap, :opaque}
  end

  test "a list-row tap is receipted as a select on the row", %{screen: screen} do
    deliver(screen, {:tap, {:list, :rows, :select, 3}})
    receipt = recent()

    assert {:select, %Address{widget: :list, id: :rows, instance: 3}} = receipt.event
    assert Receipt.effect(receipt) == :verified
    assert Mob.Screen.Server.socket(screen).assigns.row == 3
  end

  test "a display-rate stream is traced but not receipted", %{screen: screen} do
    # One scroll is dozens of events; receipts are bounded at 256, so receipting
    # them would evict the tap an agent is about to ask about. A float change
    # is a slider drag — the same stream.
    Mob.Event.Trace.subscribe()

    deliver(screen, {:scroll, :feed, %{y: 12.0, phase: :dragging}})
    deliver(screen, {:change, :volume, 0.5})

    assert_received {:mob_trace, %Address{widget: :scroll, id: :feed}, :scroll, %{y: 12.0}}
    assert_received {:mob_trace, %Address{id: :volume}, :change, 0.5}
    assert Receipts.recent(1) == []
  end

  test "native input is traced once, and a dispatched event is not traced again",
       %{screen: screen} do
    Mob.Event.Trace.subscribe()

    deliver(screen, {:tap, :increment})

    assert_received {:mob_trace, %Address{screen: Screen, widget: :button, id: :increment}, :tap,
                     nil}

    # Mob.Event.dispatch/4 traces as it sends. The screen receiving the
    # envelope must not trace it a second time.
    addr = Address.new(screen: Screen, widget: :button, id: :save)
    Mob.Event.dispatch(screen, addr, :tap, nil)
    :sys.get_state(screen)

    assert_received {:mob_trace, ^addr, :tap, nil}
    refute_received {:mob_trace, _addr, _event, _payload}
  end
end
