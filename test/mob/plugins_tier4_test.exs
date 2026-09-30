defmodule Mob.PluginsTier4Test do
  use ExUnit.Case, async: false

  # Named hook functions (apply/3 needs MFAs, not closures). Each forwards to the
  # test process registered under :tier4_test so a test can assert it ran.
  defmodule Hooks do
    def notify(payload), do: send_test({:notified, payload})
    def matches_chat?(payload), do: Map.get(payload, :kind) == "chat"
    def resumed, do: send_test(:resumed)
    def backgrounded, do: send_test(:backgrounded)
    def started, do: send_test(:on_start) && :ok
    def started_error, do: {:error, :boom}
    def crash(_payload), do: raise("boom in handler")
    def crash_pred(_payload), do: raise("boom in predicate")
    def send_test(msg), do: send(Process.whereis(:tier4_test), msg)
  end

  defmodule Worker do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def init(:ok), do: {:ok, :ok}
  end

  setup do
    Process.register(self(), :tier4_test)
    on_exit(fn -> Mob.Plugins.install(%{}) end)
    :ok
  end

  describe "settings" do
    setup do
      tmp = Mob.Test.ProcessHelpers.tmp_path("mob_set")
      File.mkdir_p!(tmp)
      System.put_env("MOB_DATA_DIR", tmp)
      start_supervised!(Mob.State)
      on_exit(fn -> File.rm_rf!(tmp) end)

      Mob.Plugins.install(%{
        settings: [
          %{
            plugin: :chat,
            schema: [
              %{key: :sound, type: :boolean, default: true},
              %{key: :channel, type: :string, default: "#general"}
            ],
            editor_screen: Chat.SettingsScreen
          }
        ]
      })
    end

    test "get_setting falls back to the schema default, then reads written values" do
      assert Mob.Plugins.get_setting(:chat, :sound) == true
      assert :ok = Mob.Plugins.put_setting(:chat, :sound, false)
      assert Mob.Plugins.get_setting(:chat, :sound) == false
    end

    test "put_setting validates the value type" do
      assert {:error, {:invalid_type, :boolean}} = Mob.Plugins.put_setting(:chat, :sound, "nope")
      assert {:error, :unknown_setting} = Mob.Plugins.put_setting(:chat, :missing, 1)
    end

    test "get_setting returns nil for an unknown plugin/key" do
      assert Mob.Plugins.get_setting(:nope, :x) == nil
    end

    test "settings_editor returns the editor screen module" do
      assert Mob.Plugins.settings_editor(:chat) == {:ok, Chat.SettingsScreen}
      assert Mob.Plugins.settings_editor(:nope) == :error
    end

    test "a schema entry missing :default does not crash get_setting" do
      Mob.Plugins.install(%{settings: [%{plugin: :p, schema: [%{key: :x, type: :boolean}]}]})
      assert Mob.Plugins.get_setting(:p, :x) == nil
    end

    test "a schema entry missing :type does not crash put_setting" do
      Mob.Plugins.install(%{settings: [%{plugin: :p, schema: [%{key: :x, default: true}]}]})
      assert {:error, :unknown_setting} = Mob.Plugins.put_setting(:p, :x, false)
    end

    test "a non-list schema does not crash setting reads/writes" do
      Mob.Plugins.install(%{settings: [%{plugin: :p, schema: %{key: :x}}]})
      assert Mob.Plugins.get_setting(:p, :x) == nil
      assert {:error, :unknown_setting} = Mob.Plugins.put_setting(:p, :x, 1)
    end
  end

  describe "dispatch_notification/1" do
    setup do
      Mob.Plugins.install(%{
        notification_handlers: [
          %{plugin: :chat, match: %{type: "msg"}, handler: {Hooks, :notify, 1}},
          %{plugin: :chat, match: {Hooks, :matches_chat?, 1}, handler: {Hooks, :notify, 1}}
        ]
      })
    end

    test "first matching handler (map prefix) wins and is invoked with the payload" do
      assert :handled = Mob.Plugins.dispatch_notification(%{type: "msg", body: "hi"})
      assert_received {:notified, %{type: "msg", body: "hi"}}
    end

    test "a predicate match also routes" do
      assert :handled = Mob.Plugins.dispatch_notification(%{kind: "chat"})
      assert_received {:notified, %{kind: "chat"}}
    end

    test "no match is unhandled" do
      assert :unhandled = Mob.Plugins.dispatch_notification(%{type: "other"})
      refute_received {:notified, _}
    end

    test "a handler that raises is isolated (logs, does not propagate)" do
      Mob.Plugins.install(%{
        notification_handlers: [
          %{plugin: :boom, match: %{type: "x"}, handler: {Hooks, :crash, 1}}
        ]
      })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :handled = Mob.Plugins.dispatch_notification(%{type: "x"})
        end)

      assert log =~ "notification handler crashed"
    end

    test "a matching entry with a malformed handler is skipped; a later handler still receives it" do
      Mob.Plugins.install(%{
        notification_handlers: [
          %{plugin: :bad, match: %{type: "x"}, handler: :not_an_mfa},
          %{plugin: :good, match: %{type: "x"}, handler: {Hooks, :notify, 1}}
        ]
      })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :handled = Mob.Plugins.dispatch_notification(%{type: "x"})
        end)

      assert log =~ "malformed"
      assert_received {:notified, %{type: "x"}}
    end

    test "a matching entry missing :handler is skipped without raising" do
      Mob.Plugins.install(%{
        notification_handlers: [%{plugin: :bad, match: %{type: "x"}}]
      })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :unhandled = Mob.Plugins.dispatch_notification(%{type: "x"})
        end)

      assert log =~ "malformed"
    end

    test "a non-map handler entry is skipped without raising" do
      Mob.Plugins.install(%{
        notification_handlers: [
          :garbage,
          %{plugin: :good, match: %{type: "x"}, handler: {Hooks, :notify, 1}}
        ]
      })

      assert :handled = Mob.Plugins.dispatch_notification(%{type: "x"})
      assert_received {:notified, %{type: "x"}}
    end

    test "a predicate that raises is isolated (treated as no-match, does not propagate)" do
      Mob.Plugins.install(%{
        notification_handlers: [
          %{plugin: :boom, match: {Hooks, :crash_pred, 1}, handler: {Hooks, :notify, 1}}
        ]
      })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :unhandled = Mob.Plugins.dispatch_notification(%{type: "x"})
        end)

      assert log =~ "notification predicate crashed"
      refute_received {:notified, _}
    end
  end

  describe "Lifecycle dispatcher" do
    test "routes did_become_active / did_enter_background to the plugin hooks" do
      state = [
        %{
          plugin: :chat,
          on_resume: {Hooks, :resumed, []},
          on_background: {Hooks, :backgrounded, []}
        }
      ]

      {:noreply, ^state} =
        Mob.Plugins.Lifecycle.handle_info({:mob_device, :did_become_active}, state)

      assert_received :resumed

      {:noreply, ^state} =
        Mob.Plugins.Lifecycle.handle_info({:mob_device, :did_enter_background}, state)

      assert_received :backgrounded
    end

    test "a plugin without a hook is skipped; unrelated messages are ignored" do
      state = [%{plugin: :chat}]

      assert {:noreply, ^state} =
               Mob.Plugins.Lifecycle.handle_info({:mob_device, :did_become_active}, state)

      assert {:noreply, ^state} = Mob.Plugins.Lifecycle.handle_info(:whatever, state)
      refute_received :resumed
    end
  end

  describe "Supervisor" do
    setup do
      start_supervised!({Mob.Device, []})
      :ok
    end

    @tag :capture_log
    test "runs on_start, starts supervised children + the lifecycle dispatcher" do
      Mob.Plugins.install(%{
        lifecycle: [%{plugin: :chat, on_start: {Hooks, :started, []}, supervised: [Worker]}]
      })

      assert :ok = Mob.Plugins.start()
      assert_received :on_start
      assert Process.whereis(Worker)
      assert Process.whereis(Mob.Plugins.Lifecycle)
    end

    test "a failing on_start bubbles up (fails boot loud)" do
      Mob.Plugins.install(%{lifecycle: [%{plugin: :bad, on_start: {Hooks, :started_error, []}}]})

      Process.flag(:trap_exit, true)
      assert {:error, _} = Mob.Plugins.Supervisor.start_link([])
    end

    test "start starts no lifecycle when no plugin declares one" do
      Mob.Plugins.install(%{})
      assert :ok = Mob.Plugins.start()
      refute Process.whereis(Mob.Plugins.Lifecycle)
    end
  end

  # A plugin's OTP application, loaded from an in-memory spec the way a real
  # one is loaded from its .app file. The start argument picks the behaviour.
  defmodule PluginApp do
    use Application

    @impl Application
    def start(_type, :ok), do: Supervisor.start_link([], strategy: :one_for_one)
    def start(_type, :fail), do: {:error, :boom}

    def start(_type, :hang) do
      Process.register(self(), :mob_hanging_plugin_app)

      receive do
        :release -> {:error, :released}
      end
    end

    def running?(app), do: send_test({:running_at_on_start, app, app_running?(app)}) && :ok

    def app_running?(app),
      do: Enum.any?(Application.started_applications(), &(elem(&1, 0) == app))

    defp send_test(msg), do: send(Process.whereis(:tier4_test), msg)
  end

  describe "plugin OTP applications" do
    setup do
      start_supervised!({Mob.Device, []})
      :ok
    end

    defp load_plugin_app(app, behaviour, deps \\ []) do
      mod = if behaviour, do: [mod: {PluginApp, behaviour}], else: []

      :ok =
        :application.load(
          {:application, app,
           [
             description: ~c"test plugin",
             vsn: ~c"0.0.0",
             modules: [PluginApp],
             registered: [],
             applications: [:kernel, :stdlib | deps]
           ] ++ mod}
        )

      on_exit(fn ->
        Application.stop(app)
        Application.unload(app)
      end)
    end

    defp lifecycle_probe(app),
      do: %{plugin: app, on_start: {PluginApp, :running?, [app]}}

    @tag :capture_log
    test "each plugin's application is running before any plugin's on_start" do
      load_plugin_app(:mob_test_plugin_ok, :ok)

      Mob.Plugins.install(%{
        plugins: [:mob_test_plugin_ok],
        lifecycle: [lifecycle_probe(:mob_test_plugin_ok)]
      })

      assert :ok = Mob.Plugins.start()
      assert_received {:running_at_on_start, :mob_test_plugin_ok, true}
    end

    test "an application that fails to start is logged and boot continues" do
      load_plugin_app(:mob_test_plugin_fail, :fail)

      Mob.Plugins.install(%{
        plugins: [:mob_test_plugin_fail, :mob_test_plugin_missing],
        lifecycle: [lifecycle_probe(:mob_test_plugin_fail)]
      })

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Mob.Plugins.start() end)

      assert log =~
               "[mob] plugin :mob_test_plugin_fail: OTP application failed to start, continuing boot"

      assert log =~ ":boom"

      assert log =~
               "[mob] plugin :mob_test_plugin_missing: OTP application failed to start, continuing boot"

      assert_received {:running_at_on_start, :mob_test_plugin_fail, false}
    end

    test "an application whose start hangs doesn't hold up boot" do
      load_plugin_app(:mob_test_plugin_hang, :hang)
      on_exit(fn -> send(:mob_hanging_plugin_app, :release) end)

      Mob.Plugins.install(%{
        plugins: [:mob_test_plugin_hang],
        lifecycle: [lifecycle_probe(:mob_test_plugin_hang)]
      })

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Mob.Plugins.start(50) end)

      assert log =~
               "[mob] plugin :mob_test_plugin_hang: OTP application did not start within 50ms, " <>
                 "continuing boot"

      assert_received {:running_at_on_start, :mob_test_plugin_hang, false}
    end

    # ensure_all_started undoes what it started when the app it was asked for
    # fails. An attempt abandoned at the timeout used to keep running, so when
    # the hanging app finally failed it stopped the shared dependency out from
    # under the plugin that started after it.
    @tag :capture_log
    test "an abandoned start can't later stop a dependency another plugin uses" do
      load_plugin_app(:mob_test_shared_dep, nil)
      load_plugin_app(:mob_test_plugin_slow, :hang, [:mob_test_shared_dep])
      load_plugin_app(:mob_test_plugin_user, :ok, [:mob_test_shared_dep])
      Mob.Plugins.install(%{plugins: [:mob_test_plugin_slow, :mob_test_plugin_user]})

      assert :ok = Mob.Plugins.start(50)
      assert PluginApp.app_running?(:mob_test_plugin_user)
      assert PluginApp.app_running?(:mob_test_shared_dep)

      hanging = Process.whereis(:mob_hanging_plugin_app)
      ref = Process.monitor(hanging)
      send(hanging, :release)
      assert_receive {:DOWN, ^ref, :process, ^hanging, _}

      refute stops_within?(:mob_test_shared_dep, 300)
    end

    defp stops_within?(app, ms) do
      cond do
        not PluginApp.app_running?(app) -> true
        ms <= 0 -> false
        true -> Process.sleep(10) == :ok and stops_within?(app, ms - 10)
      end
    end
  end

  describe "names/0" do
    test "is the manifest's plugin list when mob_dev wrote one" do
      Mob.Plugins.install(%{plugins: [:b, :a], lifecycle: [%{plugin: :c}]})
      assert Mob.Plugins.names() == [:b, :a]
    end

    test "falls back to the plugins tagged on runtime declarations, once each" do
      Mob.Plugins.install(%{
        lifecycle: [%{plugin: :deliver}],
        screens: [%{plugin: :chat, module: Chat.Screen, default_route: "chat"}],
        settings: [%{plugin: :deliver, schema: []}],
        nifs: [Some.Nif]
      })

      assert Mob.Plugins.names() == [:deliver, :chat]
    end
  end
end
