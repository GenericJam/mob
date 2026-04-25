defmodule Mob.NativeLogger do
  @moduledoc """
  OTP logger handler that routes Elixir Logger output to the platform's native
  system log.

  - **Android** — `mob_nif:log/2` → `android.util.Log` → `adb logcat`
  - **iOS** — `mob_nif:log/2` → `NSLog` → unified system log (Xcode console,
    `xcrun simctl spawn booted log stream`)

  Each message appears with the correct priority level (D/I/W/E) under the
  tag `Elixir`. OTP supervision reports, GenServer crashes, and all
  `Logger.info/warn/error` calls are captured from the first BEAM instruction,
  including boot-time failures that happen before Erlang distribution comes up.

  ## Usage

  Call `install/0` once after `application:start(logger)` in your BEAM entry
  point (e.g. `mob_demo.erl`):

      'Elixir.Mob.NativeLogger':install()

  On the host Mix environment (`:host` platform) the call is a no-op, so the
  same boot file works unchanged during `mix test` and local development.

  ## Relationship to Erlang distribution

  This handler and dist-based log forwarding are complementary. Native logging
  is always-on and survives connection drops; dist forwarding surfaces logs in
  the mob_dev dashboard. Both can be active simultaneously — OTP supports
  multiple logger handlers.
  """

  @handler_id :mob_native_logger

  @doc """
  Installs the native system log handler.

  Checks the platform via the NIF; if `:host`, returns `:ok` without adding
  any handler. Safe to call multiple times.

  Options:
  - `:nif` — NIF module to use (default `:mob_nif`; override in tests)
  """
  @spec install(keyword()) :: :ok
  def install(opts \\ []) do
    nif = Keyword.get(opts, :nif, :mob_nif)

    if nif.platform() in [:android, :ios] do
      case :logger.add_handler(@handler_id, __MODULE__, %{nif: nif}) do
        :ok -> :ok
        {:error, {:already_exist, @handler_id}} -> :ok
      end
    else
      :ok
    end
  end

  # ── OTP logger handler callback ───────────────────────────────────────────

  @doc false
  @spec log(map(), map()) :: :ok
  def log(%{level: level, msg: msg, meta: meta}, %{nif: nif}) do
    text = format_msg(msg, meta)
    nif.log(level_to_nif(level), text)
  end

  # ── Helpers (public for testing) ──────────────────────────────────────────

  @doc false
  @spec format_msg(term(), map()) :: String.t()
  def format_msg({:string, msg}, _meta), do: IO.iodata_to_binary(msg)
  def format_msg({:report, report}, _meta), do: inspect(report)

  def format_msg({:format, fmt, args}, _meta) do
    :io_lib.format(fmt, args) |> IO.iodata_to_binary()
  end

  def format_msg(msg, _meta), do: inspect(msg)

  @doc false
  @spec level_to_nif(:logger.level()) :: :debug | :info | :warning | :error
  def level_to_nif(:debug), do: :debug
  def level_to_nif(:info), do: :info
  def level_to_nif(:notice), do: :info
  def level_to_nif(:warning), do: :warning
  def level_to_nif(:error), do: :error
  def level_to_nif(:critical), do: :error
  def level_to_nif(:alert), do: :error
  def level_to_nif(:emergency), do: :error
  def level_to_nif(_), do: :info
end
