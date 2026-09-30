defmodule Mob.AppConfigTest do
  # Application env is VM-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  @app :mob_app_config_test_app

  defmodule Generated do
    def config do
      [
        {:mob_app_config_test_app, [endpoint: "https://updates.example.com", channel: "beta"]},
        {:mob_app_config_test_other, [flag: true]}
      ]
    end
  end

  defmodule Raising do
    def config, do: raise("corrupt term")
  end

  defmodule Malformed do
    def config, do: :not_a_keyword_list
  end

  defmodule QuietLogger do
    def config, do: [{:logger, [level: :error]}]
  end

  defmodule BadLoggerLevel do
    def config, do: [{:logger, [level: :chatty]}, {:mob_app_config_test_app, [channel: "beta"]}]
  end

  setup do
    on_exit(fn ->
      Application.unload(@app)

      for {app, keys} <- [
            {@app, [:endpoint, :channel, :poll]},
            {:mob_app_config_test_other, [:flag]}
          ],
          key <- keys,
          do: Application.delete_env(app, key, persistent: true)
    end)
  end

  defp app_spec(env) do
    {:application, @app,
     [
       description: ~c"test app",
       vsn: ~c"0.0.0",
       modules: [],
       registered: [],
       applications: [:kernel, :stdlib],
       env: env
     ]}
  end

  describe ":logger" do
    setup do
      level = Logger.level()
      env = Application.fetch_env(:logger, :level)

      on_exit(fn ->
        Logger.configure(level: level)

        case env do
          {:ok, value} -> Application.put_env(:logger, :level, value, persistent: true)
          :error -> Application.delete_env(:logger, :level, persistent: true)
        end
      end)
    end

    # :logger is already running when the config arrives, so putting the env
    # alone leaves the running Logger at its old level.
    test "a configured level takes effect in the running Logger" do
      Logger.configure(level: :debug)
      capture_log(fn -> assert :ok = Mob.AppConfig.load(QuietLogger) end)

      assert Logger.level() == :error
      assert capture_log(fn -> Logger.warning("dropped") end) == ""
    end

    test "an invalid level is logged and the rest of the config still applies" do
      Logger.configure(level: :debug)
      log = capture_log(fn -> assert :ok = Mob.AppConfig.load(BadLoggerLevel) end)

      assert log =~ "[mob] app config: ignoring invalid :logger level :chatty"
      assert Logger.level() == :debug
      assert Application.get_env(@app, :channel) == "beta"
    end
  end

  test "applied values win over the app's own defaults, even when the app is loaded afterwards" do
    capture_log(fn -> assert :ok = Mob.AppConfig.load(Generated) end)

    # Starting a plugin's OTP application loads its .app file; without
    # persistent: true that would put the defaults back.
    :ok = :application.load(app_spec(endpoint: "https://default.invalid", poll: 3600))

    assert Application.get_env(@app, :endpoint) == "https://updates.example.com"
    assert Application.get_env(@app, :channel) == "beta"
    assert Application.get_env(@app, :poll) == 3600
    assert Application.get_env(:mob_app_config_test_other, :flag) == true
  end

  test "applied values replace defaults of an app that was already loaded" do
    :ok = :application.load(app_spec(endpoint: "https://default.invalid"))
    capture_log(fn -> assert :ok = Mob.AppConfig.load(Generated) end)

    assert Application.get_env(@app, :endpoint) == "https://updates.example.com"
  end

  test "logs one summary line naming the apps, never the values" do
    log = capture_log([level: :info], fn -> Mob.AppConfig.load(Generated) end)

    assert log =~
             "[mob] app config: loaded Mob.AppConfigTest.Generated " <>
               "(mob_app_config_test_app: 2 keys, mob_app_config_test_other: 1 key)"

    refute log =~ "updates.example.com"
  end

  test "a missing module is a no-op" do
    assert Mob.AppConfig.load(:mob_app_config_does_not_exist) == :none
    assert Application.get_env(@app, :endpoint) == nil
  end

  test "a module that raises or returns garbage is logged, not raised" do
    for module <- [Raising, Malformed] do
      log = capture_log(fn -> assert {:error, _} = Mob.AppConfig.load(module) end)
      assert log =~ "[mob] app config: #{inspect(module)} could not be applied"
    end

    assert Application.get_env(@app, :endpoint) == nil
  end
end
