defmodule Mob.Theme.AdaptiveWatcherTest do
  use ExUnit.Case, async: false

  alias Mob.Theme.AdaptiveWatcher

  setup do
    # Mob.Device + its platform fan-outs need to be alive for the watcher's
    # init/1 to subscribe successfully. Re-use the same start-fresh pattern
    # as Mob.DeviceTest.
    start_supervised!({Mob.Device.IOS, []})
    start_supervised!({Mob.Device.Android, []})
    start_supervised!({Mob.Device, []})

    on_exit(fn ->
      Application.delete_env(:mob, :theme)
    end)

    {:ok, dispatcher: Process.whereis(Mob.Device)}
  end

  describe "start_link/1" do
    test "starts and registers under its own name" do
      {:ok, pid} = AdaptiveWatcher.start_link()
      assert Process.alive?(pid)
      assert Process.whereis(AdaptiveWatcher) == pid
      GenServer.stop(pid)
    end

    test "default adaptive module is Mob.Theme.Adaptive" do
      {:ok, pid} = AdaptiveWatcher.start_link()
      assert AdaptiveWatcher.adaptive_module() == Mob.Theme.Adaptive
      GenServer.stop(pid)
    end
  end

  describe "register_adaptive/1" do
    test "swaps the active adaptive module" do
      {:ok, pid} = AdaptiveWatcher.start_link()

      defmodule MockAdaptive do
        def theme, do: Mob.Theme.build(primary: 0xFF112233)
      end

      :ok = AdaptiveWatcher.register_adaptive(MockAdaptive)
      assert AdaptiveWatcher.adaptive_module() == MockAdaptive

      GenServer.stop(pid)
    end
  end

  describe "color_scheme_changed handling" do
    defmodule TrackingAdaptive do
      # Records calls so the test can assert the watcher hit theme/0 again.
      def theme do
        Process.put({__MODULE__, :calls}, (Process.get({__MODULE__, :calls}) || 0) + 1)
        Mob.Theme.build(primary: 0xFF445566)
      end

      def call_count, do: Process.get({__MODULE__, :calls}) || 0
    end

    test "re-resolves the theme when active theme matches the adaptive module",
         %{dispatcher: d} do
      {:ok, pid} = AdaptiveWatcher.start_link()
      :ok = AdaptiveWatcher.register_adaptive(TrackingAdaptive)

      # Set the active theme to whatever TrackingAdaptive resolves to right
      # now. After the appearance event, the watcher should re-call
      # TrackingAdaptive.theme/0 (i.e. call count > 0).
      Mob.Theme.set(TrackingAdaptive)
      :ok = GenServer.call(d, {:subscribe, AdaptiveWatcher, [:appearance]})

      send(pid, {:mob_device, :color_scheme_changed, :dark})
      # Give the GenServer a tick to handle the message.
      _ = :sys.get_state(pid)

      assert TrackingAdaptive.call_count() >= 1

      GenServer.stop(pid)
    end

    test "ignores the event when active theme is not the adaptive one",
         %{dispatcher: _d} do
      {:ok, pid} = AdaptiveWatcher.start_link()
      :ok = AdaptiveWatcher.register_adaptive(Mob.Theme.Adaptive)

      # User explicitly picked a fixed theme — adaptive watcher must
      # not clobber it on OS toggle.
      fixed = Mob.Theme.Light.theme()
      Mob.Theme.set(fixed)
      send(pid, {:mob_device, :color_scheme_changed, :dark})
      _ = :sys.get_state(pid)

      assert Mob.Theme.current() == fixed
      GenServer.stop(pid)
    end

    test "ignores arbitrary unrelated messages" do
      {:ok, pid} = AdaptiveWatcher.start_link()
      send(pid, :random_noise)
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
