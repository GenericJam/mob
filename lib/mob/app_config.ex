defmodule Mob.AppConfig do
  @moduledoc """
  Puts the project's `config/*.exs` into the application environment on device.

  A Mob app boots from a custom BEAM entry (`<app>:start()`), not a release,
  so nothing reads `config/config.exs` on the phone and `Application.get_env/2`
  returns `nil` for everything that isn't `compile_env`. mob_dev closes that
  gap at build time: it evaluates `config/config.exs` (and `config/runtime.exs`,
  **on the build host**) for the build's Mix env and target, and ships the
  result as a generated `:mob_app_config` module next to the app's own BEAMs.
  `Mob.App.start/0` calls `load/0` before anything else reads the environment.

  The values are put with `persistent: true`, so a later `Application.load/1`
  of the same app (starting a plugin's OTP application loads it) does not
  replace them with the defaults in its `.app` file.

  ## `:logger`

  The `:logger` application is already running when the config arrives (the
  device entry starts it before `Mob.App.start/0`), so its settings that
  are read once at startup can't take effect. Applied:

    * `:level`, through `Logger.configure/1`, so the running Logger's primary
      level changes. An invalid level is logged and skipped.
    * `:translator_inspect_opts`, which Logger reads from the environment
      each time it's used.

  Not applied, because Logger reads them only when it starts:
  `:default_handler`, `:default_formatter`, `:handle_otp_reports`,
  `:handle_sasl_reports`, `:translators`, `:backends`, and `:truncate` /
  `:utc_log` for the default handler's formatter. The `:compile_time_*` keys
  are compile-time only. Logger output on device goes through
  `Mob.NativeLogger` anyway.
  """

  require Logger

  @module :mob_app_config

  @doc """
  Applies the generated config module, if there is one.

  Returns `:ok` once applied, `:none` when the module isn't present (an app
  built by an older mob_dev, or a host test), and `{:error, reason}` when it
  can't be applied. Never raises: a broken config must not stop the app from
  booting, so the failure is logged and the app runs with what it has.
  """
  @spec load(module()) :: :ok | :none | {:error, term()}
  def load(module \\ @module) do
    case :code.ensure_loaded(module) do
      {:module, ^module} -> apply_config(module)
      {:error, _reason} -> :none
    end
  end

  defp apply_config(module) do
    config = module.config()
    Application.put_all_env(config, persistent: true)
    apply_logger_level(config)
    Logger.info("[mob] app config: loaded #{inspect(module)} (#{summary(config)})")
    :ok
  catch
    kind, reason ->
      Logger.error(
        "[mob] app config: #{inspect(module)} could not be applied, continuing without it: " <>
          Exception.format_banner(kind, reason, __STACKTRACE__)
      )

      {:error, {kind, reason}}
  end

  # put_env doesn't reach the running Logger: its level is the :logger primary
  # config, which Logger.configure/1 sets.
  defp apply_logger_level(config) do
    with {:logger, entries} <- List.keyfind(config, :logger, 0),
         {:ok, level} <- Keyword.fetch(entries, :level) do
      if level in [:all, :none | Logger.levels()] do
        Logger.configure(level: level)
      else
        Logger.warning("[mob] app config: ignoring invalid :logger level #{inspect(level)}")
      end
    end
  end

  # Names and key counts only: values can be secrets, and this goes to logcat.
  defp summary([]), do: "no apps"

  defp summary(config) do
    Enum.map_join(config, ", ", fn {app, entries} ->
      count = length(entries)
      "#{app}: #{count} #{if count == 1, do: "key", else: "keys"}"
    end)
  end
end
