defmodule Mob.ScreenSenderWiringTest do
  @moduledoc """
  The seam between `Mob.Screen` and `Mob.Sender`.

  Screens run `:no_render` here, so no tree is ever committed — but
  `Mob.Sender.set_active/1` is a cast, so with a real sender running these
  assertions pin *who* declares the active screen and *when*. That matters:
  announcing it on every render instead would let any screen promote itself,
  which is what disarms the drop-inactive mechanism at MOB-112.
  """
  use ExUnit.Case, async: false

  alias Mob.Sender

  defmodule HomeScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :count, 0)}
    def render(assigns), do: %{type: :text, props: %{text: "#{assigns.count}"}, children: []}

    def handle_event("bump", _, socket),
      do: {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}

    def handle_event("to_settings", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings)}

    def handle_event("to_home", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home)}

    def handle_event("to_nowhere", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :not_a_stack)}
  end

  defmodule SettingsScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :count, 0)}

    def render(assigns),
      do: %{type: :text, props: %{text: "settings #{assigns.count}"}, children: []}

    def handle_event("bump", _, socket),
      do: {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}

    def handle_event("to_home", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home)}
  end

  defmodule TabApp do
    @behaviour Mob.App
    import Mob.App

    @home Mob.ScreenSenderWiringTest.HomeScreen
    @settings Mob.ScreenSenderWiringTest.SettingsScreen

    def navigation(_) do
      tab_bar([stack(:home, root: @home), stack(:settings, root: @settings)])
    end
  end

  defp active, do: :sys.get_state(Process.whereis(Sender)).active

  setup do
    for name <- [Sender, Mob.Nav.Registry] do
      case Process.whereis(name) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end
    end

    {:ok, sender} = Sender.start_link([])
    {:ok, registry} = Mob.Nav.Registry.start_link(TabApp)

    on_exit(fn ->
      for pid <- [sender, registry], Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, screen} = Mob.Screen.start_link(HomeScreen, %{})
    on_exit(fn -> if Process.alive?(screen), do: GenServer.stop(screen) end)

    %{screen: screen}
  end

  test "mounting a screen declares its stack active", %{screen: _} do
    Sender.sync()
    assert active() == :home
  end

  test "switching stacks moves the active screen", %{screen: screen} do
    Mob.Screen.dispatch(screen, "to_settings", %{})
    Sender.sync()
    assert active() == :settings

    Mob.Screen.dispatch(screen, "to_home", %{})
    Sender.sync()
    assert active() == :home
  end

  test "an ordinary re-render does not change the active screen", %{screen: screen} do
    Mob.Screen.dispatch(screen, "to_settings", %{})
    Sender.sync()
    assert active() == :settings

    # A screen re-rendering must not promote itself — this is the assertion that
    # fails if set_active/1 moves back into do_render/4.
    Mob.Screen.dispatch(screen, "bump", %{})
    Sender.sync()
    assert active() == :settings
  end

  test "a switch to an undeclared stack leaves the active screen alone", %{screen: screen} do
    Mob.Screen.dispatch(screen, "to_nowhere", %{})
    Sender.sync()
    assert active() == :home
  end
end
