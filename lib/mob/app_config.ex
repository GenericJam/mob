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

  # Names and key counts only: values can be secrets, and this goes to logcat.
  defp summary([]), do: "no apps"

  defp summary(config) do
    Enum.map_join(config, ", ", fn {app, entries} ->
      count = length(entries)
      "#{app}: #{count} #{if count == 1, do: "key", else: "keys"}"
    end)
  end
end
