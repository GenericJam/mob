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
      Application.delete_env(:mob, :theme_source)
    end)
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
    defmodule SchemeAdaptive do
      # Stands in for an adaptive theme: what it returns follows a scheme the
      # test flips, the way Mob.Theme.Adaptive follows the OS.
      def theme do
        case :persistent_term.get({__MODULE__, :scheme}, :light) do
          :dark -> Mob.Theme.Dark.theme()
          :light -> Mob.Theme.Light.theme()
        end
      end
    end

    setup do
      on_exit(fn -> :persistent_term.erase({SchemeAdaptive, :scheme}) end)
      {:ok, pid} = AdaptiveWatcher.start_link()
      :ok = AdaptiveWatcher.register_adaptive(SchemeAdaptive)
      on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(pid) end)
      {:ok, watcher: pid}
    end

    defp flip_os_to(watcher, scheme) do
      :persistent_term.put({SchemeAdaptive, :scheme}, scheme)
      send(watcher, {:mob_device, :color_scheme_changed, scheme})
      _ = :sys.get_state(watcher)
    end

    test "the adaptive module follows the flip", %{watcher: w} do
      Mob.Theme.set(SchemeAdaptive)

      flip_os_to(w, :dark)
      assert Mob.Theme.current() == Mob.Theme.Dark.theme()

      flip_os_to(w, :light)
      assert Mob.Theme.current() == Mob.Theme.Light.theme()
    end

    test "{adaptive, overrides} follows the flip and keeps the overrides", %{watcher: w} do
      Mob.Theme.set({SchemeAdaptive, primary: 0xFF112233})

      flip_os_to(w, :dark)
      assert Mob.Theme.current() == %{Mob.Theme.Dark.theme() | primary: 0xFF112233}
    end

    test "an explicit fixed theme set after the adaptive one is not clobbered",
         %{watcher: w} do
      Mob.Theme.set(SchemeAdaptive)
      # The struct the adaptive module returns right now, set explicitly: a
      # fixed choice, even though it is equal to the adaptive resolution.
      fixed = SchemeAdaptive.theme()
      Mob.Theme.set(fixed)

      flip_os_to(w, :dark)
      assert Mob.Theme.current() == fixed
    end

    test "ignores arbitrary unrelated messages", %{watcher: w} do
      send(w, :random_noise)
      _ = :sys.get_state(w)
      assert Process.alive?(w)
    end
  end
end
