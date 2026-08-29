defmodule Mob.ScreenSenderWiringTest do
  @moduledoc """
  The seam between `Mob.Screen` and `Mob.Sender`.

  Screens run `:no_render` here, so no tree is ever committed — but
  `Mob.Sender.set_active/1` is a cast, so with a real sender running these
  assertions pin *who* declares the active screen and *when*.

  Since MOB-112 the sender's key is per **screen**, not per stack. Every screen
  is a live process that repaints on any message it receives, including the ones
  below the top of the stack; keyed by stack they would all share a ref, and a
  timer tick in a screen the user cannot see would commit its tree over the one
  they can. Only the current screen's ref is ever active.
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

    def handle_event("push_detail", _, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, Mob.ScreenSenderWiringTest.DetailScreen)}
  end

  defmodule DetailScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "detail"}, children: []}
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
  defp current_ref(owner), do: :sys.get_state(owner).current.ref

  defp history_refs(owner),
    do: owner |> :sys.get_state() |> Map.fetch!(:nav) |> Mob.Nav.history() |> Enum.map(& &1.ref)

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
      for pid <- [sender, registry], do: stop_safely(pid)
    end)

    {:ok, screen} = Mob.Screen.start_link(HomeScreen, %{})
    on_exit(fn -> stop_safely(screen) end)

    %{screen: screen}
  end

  # `if Process.alive?, do: GenServer.stop` races: the process can exit between
  # the check and the stop, and the :noproc exit then fails the test from inside
  # the on_exit runner. Screens and their owner die with the test process.
  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  test "mounting a screen makes that screen active", %{screen: screen} do
    Sender.sync()
    assert active() == current_ref(screen)
  end

  test "switching stacks moves the active screen", %{screen: screen} do
    home_ref = current_ref(screen)

    Mob.Screen.dispatch(screen, "to_settings", %{})
    Sender.sync()
    settings_ref = current_ref(screen)
    assert active() == settings_ref
    refute settings_ref == home_ref

    Mob.Screen.dispatch(screen, "to_home", %{})
    Sender.sync()
    assert active() == home_ref, "switching back restores the same screen, so the same ref"
  end

  test "an ordinary re-render does not change the active screen", %{screen: screen} do
    Mob.Screen.dispatch(screen, "to_settings", %{})
    Sender.sync()
    settings_ref = current_ref(screen)

    # A screen re-rendering must not promote itself — this fails if set_active/1
    # moves back into the render path.
    Mob.Screen.dispatch(screen, "bump", %{})
    Sender.sync()
    assert active() == settings_ref
  end

  test "a switch to an undeclared stack leaves the active screen alone", %{screen: screen} do
    home_ref = current_ref(screen)
    Mob.Screen.dispatch(screen, "to_nowhere", %{})
    Sender.sync()
    assert active() == home_ref
  end

  test "a screen below the top of the stack has a different ref", %{screen: screen} do
    # The regression this guards: keyed by stack, a background screen's timer
    # tick would commit its tree over the foreground screen, tap table included.
    Mob.Screen.dispatch(screen, "push_detail", %{})
    Sender.sync()
    [below] = history_refs(screen)
    assert active() == current_ref(screen)
    refute below == current_ref(screen)
  end
end
