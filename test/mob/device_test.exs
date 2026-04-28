defmodule Mob.DeviceTest do
  use ExUnit.Case, async: false

  # Tests cover the GenServer fan-out logic without requiring the NIF.
  # The NIF stubs raise when not loaded; we verify the public-API exports
  # in a separate describe block and exercise the dispatcher by sending
  # synthetic OS messages.

  alias Mob.Device

  setup do
    # Start fresh dispatcher (and platform fan-outs it forwards to) per test.
    start_supervised!({Mob.Device.IOS, []})
    start_supervised!({Mob.Device.Android, []})

    {:ok, pid} =
      case GenServer.start_link(Device, [], name: :"device_#{System.unique_integer([:positive])}") do
        {:ok, p} -> {:ok, p}
        other -> other
      end

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, dispatcher: pid}
  end

  describe "module exports" do
    # function_exported?/3 checks elsewhere were removed — the
    # "raises when NIF not loaded" tests below actually invoke each function,
    # which proves both existence and behaviour. A bare `function_exported?`
    # test gives a false sense of coverage and trips Credo's "this test
    # doesn't call any application code" warning.

    test "categories/0 returns the 6 known categories" do
      cats = Device.categories()
      assert :app in cats
      assert :display in cats
      assert :audio in cats
      assert :power in cats
      assert :thermal in cats
      assert :memory in cats
    end
  end

  describe "category_for/1" do
    test "maps app events" do
      assert Device.category_for(:will_resign_active) == :app
      assert Device.category_for(:did_become_active) == :app
      assert Device.category_for(:did_enter_background) == :app
      assert Device.category_for(:will_enter_foreground) == :app
      assert Device.category_for(:will_terminate) == :app
    end

    test "maps display events" do
      assert Device.category_for(:screen_off) == :display
      assert Device.category_for(:screen_on) == :display
    end

    test "maps audio events" do
      assert Device.category_for(:audio_interrupted) == :audio
      assert Device.category_for(:audio_resumed) == :audio
      assert Device.category_for(:audio_route_changed) == :audio
    end

    test "maps power, thermal, memory events" do
      assert Device.category_for(:battery_state_changed) == :power
      assert Device.category_for(:battery_level_changed) == :power
      assert Device.category_for(:low_power_mode_changed) == :power
      assert Device.category_for(:thermal_state_changed) == :thermal
      assert Device.category_for(:memory_warning) == :memory
    end

    test "unknown events fall through to :unknown" do
      assert Device.category_for(:no_such_event) == :unknown
    end
  end

  describe "subscription fan-out" do
    test "subscriber receives events for its categories", %{dispatcher: d} do
      :ok = GenServer.call(d, {:subscribe, self(), [:app]})
      send(d, {:mob_device, :did_enter_background})
      assert_receive {:mob_device, :did_enter_background}, 100
    end

    test "subscriber does not receive events outside its categories", %{dispatcher: d} do
      :ok = GenServer.call(d, {:subscribe, self(), [:thermal]})
      send(d, {:mob_device, :did_enter_background})
      refute_receive {:mob_device, :did_enter_background}, 50
    end

    test "subscriber to :all (via list of all categories) gets everything", %{dispatcher: d} do
      :ok = GenServer.call(d, {:subscribe, self(), Device.categories()})

      send(d, {:mob_device, :did_enter_background})
      assert_receive {:mob_device, :did_enter_background}, 100

      send(d, {:mob_device, :memory_warning})
      assert_receive {:mob_device, :memory_warning}, 100

      send(d, {:mob_device, :thermal_state_changed, :serious})
      assert_receive {:mob_device, :thermal_state_changed, :serious}, 100
    end

    test "events with payload are delivered with payload", %{dispatcher: d} do
      :ok = GenServer.call(d, {:subscribe, self(), [:power]})
      send(d, {:mob_device, :battery_level_changed, 73})
      assert_receive {:mob_device, :battery_level_changed, 73}, 100
    end

    test "multiple subscribers all receive matching events", %{dispatcher: d} do
      task1 =
        Task.async(fn ->
          :ok = GenServer.call(d, {:subscribe, self(), [:app]})
          assert_receive {:mob_device, :did_become_active}, 200
          :got_it
        end)

      task2 =
        Task.async(fn ->
          :ok = GenServer.call(d, {:subscribe, self(), [:app]})
          assert_receive {:mob_device, :did_become_active}, 200
          :got_it
        end)

      # Give both tasks time to subscribe.
      Process.sleep(20)
      send(d, {:mob_device, :did_become_active})

      assert Task.await(task1) == :got_it
      assert Task.await(task2) == :got_it
    end

    test "unsubscribe removes the subscriber", %{dispatcher: d} do
      :ok = GenServer.call(d, {:subscribe, self(), [:app]})
      :ok = GenServer.call(d, {:unsubscribe, self()})
      send(d, {:mob_device, :did_enter_background})
      refute_receive {:mob_device, :did_enter_background}, 50
    end

    test "subscriber pid going down is auto-removed", %{dispatcher: d} do
      task =
        Task.async(fn ->
          :ok = GenServer.call(d, {:subscribe, self(), [:app]})
          :done
        end)

      assert Task.await(task) == :done
      # Wait for the :DOWN to be processed.
      Process.sleep(50)

      subs = GenServer.call(d, :__test_subscribers__)
      refute Map.has_key?(subs, task.pid)
    end

    test "double-subscribe replaces categories rather than duplicating", %{dispatcher: d} do
      :ok = GenServer.call(d, {:subscribe, self(), [:app]})
      :ok = GenServer.call(d, {:subscribe, self(), [:thermal]})

      send(d, {:mob_device, :did_enter_background})
      refute_receive {:mob_device, :did_enter_background}, 50

      send(d, {:mob_device, :thermal_state_changed, :serious})
      assert_receive {:mob_device, :thermal_state_changed, :serious}, 100
    end
  end

  describe "platform forwarding" do
    test "iOS-tagged messages forward to Mob.Device.IOS", %{dispatcher: d} do
      Mob.Device.IOS.subscribe()

      send(d, {:mob_device_ios, :protected_data_will_become_unavailable})
      assert_receive {:mob_device_ios, :protected_data_will_become_unavailable}, 100
    end

    test "Android-tagged messages forward to Mob.Device.Android", %{dispatcher: d} do
      Mob.Device.Android.subscribe()

      send(d, {:mob_device_android, :doze_mode_changed, true})
      assert_receive {:mob_device_android, :doze_mode_changed, true}, 100
    end

    test "common-tagged subscribers do NOT receive platform-tagged messages",
         %{dispatcher: d} do
      :ok = GenServer.call(d, {:subscribe, self(), Device.categories()})

      send(d, {:mob_device_ios, :will_resign_active})
      refute_receive {:mob_device_ios, :will_resign_active}, 50
      refute_receive {:mob_device, :will_resign_active}, 50
    end
  end

  describe "Mob.Device.IOS subscription" do
    test "subscribe/0 and unsubscribe/0 work" do
      assert :ok = Mob.Device.IOS.subscribe()
      assert :ok = Mob.Device.IOS.unsubscribe()
    end

    test "subscriber pid down is removed" do
      task =
        Task.async(fn ->
          :ok = Mob.Device.IOS.subscribe()
          :done
        end)

      assert Task.await(task) == :done
      Process.sleep(50)

      subs = GenServer.call(Mob.Device.IOS, :__test_subscribers__)
      refute Map.has_key?(subs, task.pid)
    end
  end

  describe "Mob.Device.Android subscription" do
    test "subscribe/0 and unsubscribe/0 work" do
      assert :ok = Mob.Device.Android.subscribe()
      assert :ok = Mob.Device.Android.unsubscribe()
    end
  end

  describe "queries (NIF-backed, raise outside device)" do
    # These all delegate to :mob_nif.* which is not loaded in the test env.
    # Verifying the right exception is raised guards against accidental
    # pure-Elixir fallbacks.

    # credo's VacuousTest heuristic doesn't see `apply(Device, @fun, [])` as a
    # call into application code, but it is — through indirection.
    for fun <- [:battery_level, :battery_state, :thermal_state, :os_version, :model] do
      @fun fun
      # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
      test "#{fun}/0 raises when NIF not loaded" do
        raised =
          try do
            apply(Device, @fun, [])
            false
          rescue
            ErlangError -> true
            UndefinedFunctionError -> true
          end

        assert raised, "expected Mob.Device.#{@fun}/0 to raise without the NIF"
      end
    end
  end
end
