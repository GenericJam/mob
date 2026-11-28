defmodule Mob.ThemeChangeRerenderTest do
  use ExUnit.Case, async: false

  # MOB-575. Token resolution happens in Mob.Renderer, at paint time, so a
  # screen keeps the palette of its last paint until something repaints it.
  # `Mob.Theme.set/1` repainted nothing: an adaptive theme's light/dark flip
  # (Mob.Theme.AdaptiveWatcher) repainted the iOS root background live and left
  # every screen's `:on_surface` text in the old palette until the user next
  # touched it. Every live screen now repaints on any theme change.

  defmodule Screen do
    @moduledoc false
    use Mob.Screen

    def mount(params, _s, socket),
      do: {:ok, Mob.Socket.assign(socket, label: params.label, test: params.test)}

    def handle_info({:push, label}, socket) do
      params = %{label: label, test: socket.assigns.test}
      {:noreply, Mob.Socket.push_screen(socket, __MODULE__, params)}
    end

    def handle_info(other, socket) do
      send(socket.assigns.test, {:handled, socket.assigns.label, other})
      {:noreply, socket}
    end

    def render(assigns) do
      send(assigns.test, {:rendered, assigns.label, Mob.Theme.current().on_surface})
      %{type: :text, props: %{text: assigns.label}, children: []}
    end
  end

  # Reports every frame that reaches native to the test process, while it runs:
  # a frame the Sender commits after the test has ended goes nowhere.
  defmodule Nif do
    @moduledoc false
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def platform, do: :ios
    def take_launch_notification, do: :none
    def take_launch_link, do: :none

    def set_root(json) do
      if test = Process.whereis(:theme_rerender_test),
        do: send(test, {:set_root, :json.decode(json)})

      :ok
    end

    def unquote(:"$handle_undefined_function")(_f, _a), do: :ok
  end

  setup do
    Process.register(self(), :theme_rerender_test)
    Mob.Theme.set(%Mob.Theme{})
    on_exit(fn -> Mob.Theme.set(%Mob.Theme{}) end)
    :ok
  end

  defp start_root do
    {:ok, pid} = Mob.Router.start_root(Screen, %{label: "root", test: self()}, nif: Nif)
    on_exit(fn -> Mob.Test.ProcessHelpers.stop_root(pid) end)
    pid
  end

  defp flush do
    receive do
      {:rendered, _label, _color} -> flush()
      {:set_root, _tree} -> flush()
    after
      100 -> :ok
    end
  end

  test "a theme change repaints every live screen, the ones under the top too" do
    pid = start_root()
    send(pid, {:push, "second"})
    assert_receive {:rendered, "second", :gray_100}
    flush()

    Mob.Theme.set(on_surface: :red_500)

    assert_receive {:rendered, "second", :red_500}
    assert_receive {:rendered, "root", :red_500}

    # And the screen on top reaches native in the new palette.
    red = Mob.Renderer.colors().red_500
    assert_receive {:set_root, %{"props" => %{"text" => "second", "text_color" => ^red}}}
  end

  test "the repaint is internal: the screen's handle_info never sees it" do
    start_root()
    flush()

    Mob.Theme.set(on_surface: :red_500)

    assert_receive {:rendered, "root", :red_500}
    refute_received {:handled, _label, {:mob_theme, :changed}}
  end

  test "setting the theme a screen already painted with sends native nothing" do
    start_root()
    flush()

    Mob.Theme.set(%Mob.Theme{})

    refute_receive {:set_root, _tree}, 200
  end
end
