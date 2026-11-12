defmodule Mob.ComponentRepaintTest do
  @moduledoc """
  A native view event that changes nothing the view draws must not cross to
  native.

  Every component event used to end in `{:component_changed, ...}` and an
  unconditional screen paint. A native view that sends an event per key press
  or knob move (FMutate's instrument, on a Moto G) committed the whole tree
  twice per press, and Compose spent 10-20 ms recomposing each one.

  Counted at the NIF, as in `Mob.ScreenRepaintTest`.
  """
  use ExUnit.Case, async: false

  @counts :component_repaint_counts

  defmodule CountingNif do
    # :no_render keeps the component off `:mob_nif.register_component/1`, which
    # is not loaded here; the screen still renders and commits through this.
    def platform, do: :no_render
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def take_launch_notification, do: :none
    def take_launch_link, do: :none
    def set_transition(_), do: :ok
    def register_tap(_), do: 0
    def clear_taps, do: :ok

    def set_root(_json) do
      :ets.update_counter(:component_repaint_counts, :set_root, 1, {:set_root, 0})
      :ok
    end
  end

  defmodule Keys do
    use Mob.Component

    # assign_new: the default update/2 re-runs mount/2 on every screen paint.
    def mount(_props, socket) do
      {:ok,
       socket
       |> Mob.Socket.assign_new(:lit, fn -> 0 end)
       |> Mob.Socket.assign_new(:held, fn -> [] end)}
    end

    def render(assigns), do: %{lit: assigns.lit}

    def handle_event("press", _payload, socket), do: {:noreply, socket}

    def handle_event("hold", %{"k" => k}, socket),
      do: {:noreply, Mob.Socket.update(socket, :held, &[k | &1])}

    def handle_event("light", _payload, socket),
      do: {:noreply, Mob.Socket.update(socket, :lit, &(&1 + 1))}
  end

  defmodule Screen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, socket}

    def render(_assigns) do
      %{
        type: :column,
        props: %{},
        children: [Mob.UI.native_view(Mob.ComponentRepaintTest.Keys, id: :keys)]
      }
    end
  end

  setup do
    :ets.new(@counts, [:public, :named_table, :set])

    started =
      for mod <- [Mob.ComponentRegistry, Mob.Sender], is_nil(Process.whereis(mod)) do
        {:ok, pid} = mod.start_link()
        pid
      end

    {:ok, router} = Mob.Router.start_root(Screen, %{}, nif: CountingNif)
    screen = Mob.Screen.get_screen_pid(router)

    on_exit(fn ->
      Mob.Test.ProcessHelpers.stop_pid(router)
      for pid <- started, do: Mob.Test.ProcessHelpers.stop_pid(pid)
      # See Mob.ScreenRepaintTest: a leftover listener reroutes later files' taps.
      if pid = Process.whereis(Mob.Listener), do: Mob.Test.ProcessHelpers.stop_pid(pid)
    end)

    settle(screen)
    {:ok, component} = Mob.ComponentRegistry.lookup(screen, :keys, Keys)
    %{screen: screen, component: component}
  end

  # A call to the component proves it handled the event and sent any
  # `:component_changed` (it sends before replying); a call to the screen then
  # proves the screen handled that and cast its render; a sender sync proves
  # the render was committed. `get_handle/1`, not `render_props/1`, so the
  # barrier does not change what the component last handed the screen.
  defp settle(screen, component \\ nil) do
    if component, do: Mob.ComponentServer.get_handle(component)
    _ = Mob.Screen.Server.socket(screen)
    Mob.Sender.sync(:infinity)
    :ok
  end

  defp renders, do: :ets.lookup_element(@counts, :set_root, 2, 0)

  defp after_events(%{screen: screen, component: component}, events) do
    before = renders()

    for {event, payload} <- events do
      send(component, {:component_event, event, IO.iodata_to_binary(:json.encode(payload))})
    end

    settle(screen, component)
    renders() - before
  end

  test "an event the component ignores does not cross to native", ctx do
    assert after_events(ctx, [{"press", %{}}]) == 0
  end

  test "an event that changes only assigns render/1 does not read does not cross", ctx do
    assert after_events(ctx, [{"hold", %{"k" => 3}}]) == 0
  end

  test "an event that changes the rendered props does cross", ctx do
    assert after_events(ctx, [{"light", %{}}]) == 1
  end

  test "a burst of ignored events stays at zero", ctx do
    assert after_events(ctx, List.duplicate({"press", %{}}, 25)) == 0
  end

  test "a change after ignored events still lands", ctx do
    assert after_events(ctx, List.duplicate({"press", %{}}, 5) ++ [{"light", %{}}]) == 1
  end

  test "a :component_changed whose tree is already on screen does not cross", ctx do
    # The screen-side half: the screen compares the tree it would commit with
    # the last one, as it does for its own messages.
    before = renders()
    send(ctx.screen, {:component_changed, :keys, Keys})
    settle(ctx.screen)
    assert renders() - before == 0
  end

  test "changes queued behind one paint commit once", %{screen: screen} = ctx do
    # Each event announces itself; the first paint fetches the latest props,
    # so every later announcement finds that tree already on screen.
    :sys.suspend(screen)
    before = renders()
    for _ <- 1..5, do: send(ctx.component, {:component_event, "light", "{}"})
    Mob.ComponentServer.get_handle(ctx.component)
    :sys.resume(screen)
    settle(screen)

    assert renders() - before == 1
    assert %{lit: 5} = Mob.ComponentServer.render_props(ctx.component)
  end
end
