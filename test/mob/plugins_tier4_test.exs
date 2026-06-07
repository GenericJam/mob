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
      tmp = Path.join(System.tmp_dir!(), "mob_set_#{System.unique_integer([:positive])}")
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

    test "runs on_start, starts supervised children + the lifecycle dispatcher" do
      Mob.Plugins.install(%{
        lifecycle: [%{plugin: :chat, on_start: {Hooks, :started, []}, supervised: [Worker]}]
      })

      assert :ok = Mob.Plugins.start_lifecycle()
      assert_received :on_start
      assert Process.whereis(Worker)
      assert Process.whereis(Mob.Plugins.Lifecycle)
    end

    test "a failing on_start bubbles up (fails boot loud)" do
      Mob.Plugins.install(%{lifecycle: [%{plugin: :bad, on_start: {Hooks, :started_error, []}}]})

      Process.flag(:trap_exit, true)
      assert {:error, _} = Mob.Plugins.Supervisor.start_link([])
    end

    test "start_lifecycle is a no-op when no plugin declares a lifecycle" do
      Mob.Plugins.install(%{})
      assert :ok = Mob.Plugins.start_lifecycle()
      refute Process.whereis(Mob.Plugins.Lifecycle)
    end
  end
end
