defmodule Mob.SizeClassTest do
  use ExUnit.Case, async: false

  # MOB-204. Every screen socket carries the window's size class as
  # `assigns.size_class`, read from the platform at mount and kept current by
  # `{:mob_size_class, h, v}`, which native sends to the `:mob_screen` router on
  # rotation, Split View / Slide Over / Stage Manager resizes and (later) fold
  # changes. Screens hear about a change as
  # `handle_info({:mob_size_class_changed, new}, socket)`.

  defmodule Screen do
    @moduledoc false
    use Mob.Screen

    def mount(params, _s, socket) do
      {:ok, Mob.Socket.assign(socket, label: Map.get(params, :label, "root"), seen: [])}
    end

    # Records what the screen was told, and what its socket held when it was —
    # the assign must already be the new value when the callback runs.
    def handle_info({:mob_size_class_changed, new}, socket) do
      {:noreply,
       Mob.Socket.assign(socket, :seen, socket.assigns.seen ++ [{new, socket.assigns.size_class}])}
    end

    def handle_info({:push, label}, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, __MODULE__, %{label: label})}

    def handle_info(_other, socket), do: {:noreply, socket}

    def render(assigns) do
      %{
        type: :text,
        props: %{text: "#{assigns.label} #{inspect(assigns.size_class)}"},
        children: []
      }
    end
  end

  # Overrides handle_info/2 without a catch-all, so it has no clause for the
  # size-class message.
  defmodule NoClauseScreen do
    @moduledoc false
    use Mob.Screen

    def mount(_p, _s, socket), do: {:ok, Mob.Socket.assign(socket, :ticks, 0)}

    def handle_info(:tick, socket),
      do: {:noreply, Mob.Socket.assign(socket, :ticks, socket.assigns.ticks + 1)}

    def render(assigns),
      do: %{type: :text, props: %{text: inspect(assigns.size_class)}, children: []}
  end

  # Its clause matches, then fails inside: that is a real crash, not a missing
  # clause, and must not be swallowed.
  defmodule BrokenClauseScreen do
    @moduledoc false
    use Mob.Screen

    def mount(_p, _s, socket), do: {:ok, socket}

    def handle_info({:mob_size_class_changed, new}, socket) do
      {:noreply, Mob.Socket.assign(socket, :axis, only_regular(new))}
    end

    def handle_info(_other, socket), do: {:noreply, socket}

    defp only_regular({:regular, _}), do: :regular

    def render(_assigns), do: %{type: :text, props: %{text: "x"}, children: []}
  end

  defmodule Nif do
    @moduledoc false
    use Agent

    def start(answer), do: Agent.start_link(fn -> answer end, name: __MODULE__)
    def size_class, do: Agent.get(__MODULE__, & &1)
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def platform, do: :ios
    def take_launch_notification, do: :none
    def unquote(:"$handle_undefined_function")(_f, _a), do: :ok
  end

  setup do
    Mob.Test.ProcessHelpers.stop_if_running(Nif)
    :ok
  end

  defp start_root(module \\ Screen) do
    {:ok, pid} = Mob.Router.start_root(module, %{}, nif: Nif)
    on_exit(fn -> Mob.Test.ProcessHelpers.stop_root(pid) end)
    pid
  end

  # `get_screen_pid/1` is a call to the router, so the router has handled (and
  # forwarded) everything sent to it before; syncing with the screen then
  # queues behind what was forwarded.
  defp settle(pid) do
    pid |> Mob.Router.get_screen_pid() |> :sys.get_state()
    Mob.Router.get_socket(pid)
  end

  describe "at mount" do
    test "the socket holds the platform's size class" do
      {:ok, _} = Nif.start({:regular, :regular})
      pid = start_root()

      assert settle(pid).assigns.size_class == {:regular, :regular}
    end

    test "with no window yet, the socket holds the placeholder rather than no key" do
      {:ok, _} = Nif.start(:no_window)
      pid = start_root()

      assert settle(pid).assigns.size_class == {:compact, :regular}
    end

    test "a native library without size_class/0 degrades to the placeholder" do
      # What a hot-pushed mob meets on an app whose native layer predates
      # size_class/0: on the host, :mob_nif's library is not loaded at all.
      defmodule OldNif do
        @moduledoc false
        def safe_area, do: {0.0, 0.0, 0.0, 0.0}
      end

      assert Mob.SizeClass.read(OldNif) == {:compact, :regular}
      assert Mob.SizeClass.read(:mob_nif) == {:compact, :regular}
    end
  end

  describe "a change reported by native" do
    test "updates the assign, then tells the screen with the assign already set" do
      {:ok, _} = Nif.start({:compact, :regular})
      pid = start_root()

      send(pid, {:mob_size_class, :regular, :compact})
      socket = settle(pid)

      assert socket.assigns.size_class == {:regular, :compact}
      assert socket.assigns.seen == [{{:regular, :compact}, {:regular, :compact}}]
    end

    test "corrects a screen that mounted with the placeholder" do
      {:ok, _} = Nif.start(:no_window)
      pid = start_root()

      send(pid, {:mob_size_class, :regular, :regular})

      assert settle(pid).assigns.size_class == {:regular, :regular}
    end

    test "repaints the screen with the new value" do
      {:ok, _} = Nif.start({:compact, :regular})
      pid = start_root()

      send(pid, {:mob_size_class, :regular, :compact})
      settle(pid)

      assert Mob.Screen.Server.tree(Mob.Router.get_screen_pid(pid)).props.text ==
               "root {:regular, :compact}"
    end

    test "a value the screen already holds is not delivered again" do
      {:ok, _} = Nif.start({:compact, :regular})
      pid = start_root()

      send(pid, {:mob_size_class, :compact, :regular})
      send(pid, {:mob_size_class, :regular, :compact})
      send(pid, {:mob_size_class, :regular, :compact})

      assert settle(pid).assigns.seen == [{{:regular, :compact}, {:regular, :compact}}]
    end

    test "reaches screens below the top of the stack, not only the visible one" do
      {:ok, _} = Nif.start({:compact, :regular})
      pid = start_root()

      send(pid, {:push, "second"})
      assert settle(pid).assigns.label == "second"

      send(pid, {:mob_size_class, :regular, :regular})
      settle(pid)

      [{Screen, below}] = Mob.Router.get_nav_history(pid)
      assert below.assigns.label == "root"
      assert below.assigns.size_class == {:regular, :regular}
      assert below.assigns.seen == [{{:regular, :regular}, {:regular, :regular}}]
    end

    test "a screen with no clause for the message keeps running with the new value" do
      {:ok, _} = Nif.start({:compact, :regular})
      pid = start_root(NoClauseScreen)
      screen = Mob.Router.get_screen_pid(pid)

      send(pid, {:mob_size_class, :regular, :compact})
      send(pid, :tick)
      socket = settle(pid)

      assert Mob.Router.get_screen_pid(pid) == screen, "the screen was restarted"
      assert socket.assigns.size_class == {:regular, :compact}
      assert socket.assigns.ticks == 1, "the screen lost its state"
    end

    test "a crash inside a matching clause is still a crash" do
      {:ok, _} = Nif.start({:regular, :regular})
      pid = start_root(BrokenClauseScreen)
      screen = Mob.Router.get_screen_pid(pid)
      ref = Process.monitor(screen)

      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, {:mob_size_class, :compact, :regular})
        assert_receive {:DOWN, ^ref, :process, ^screen, _reason}, 1_000
      end)
    end
  end
end
