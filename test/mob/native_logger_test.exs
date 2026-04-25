defmodule Mob.NativeLoggerTest do
  use ExUnit.Case, async: false

  alias Mob.NativeLogger
  require Logger

  # ── Mock NIF ─────────────────────────────────────────────────────────────────
  # Wraps an Agent pid so each test gets its own isolated instance.

  defmodule MockNIF do
    def start(platform \\ :android) do
      Agent.start_link(fn -> %{platform: platform, calls: []} end)
    end

    def calls(pid), do: Agent.get(pid, & &1.calls)
    def platform(pid), do: Agent.get(pid, & &1.platform)

    def log(pid, level, msg) do
      Agent.update(pid, fn s -> %{s | calls: s.calls ++ [{level, msg}]} end)
      :ok
    end
  end

  # Wrap the pid-based MockNIF in a module that matches the nif: interface
  # expected by NativeLogger (i.e. nif.platform/0 and nif.log/2 called with
  # no pid argument). We store the pid in the process dictionary so the
  # zero-arity wrappers can find it.

  defmodule BoundNIF do
    def bind(pid), do: Process.put(:mock_nif_pid, pid)
    def platform, do: MockNIF.platform(Process.get(:mock_nif_pid))
    def log(level, msg), do: MockNIF.log(Process.get(:mock_nif_pid), level, msg)
  end

  setup do
    {:ok, pid} = MockNIF.start(:android)
    BoundNIF.bind(pid)
    :logger.remove_handler(:mob_native_logger)
    on_exit(fn -> :logger.remove_handler(:mob_native_logger) end)
    {:ok, nif_pid: pid}
  end

  # ── install/1 ────────────────────────────────────────────────────────────────

  describe "install/1" do
    test "installs handler when platform is :android" do
      assert :ok = NativeLogger.install(nif: BoundNIF)
      assert :mob_native_logger in :logger.get_handler_ids()
    end

    test "installs handler when platform is :ios" do
      {:ok, ios_pid} = MockNIF.start(:ios)
      BoundNIF.bind(ios_pid)
      assert :ok = NativeLogger.install(nif: BoundNIF)
      assert :mob_native_logger in :logger.get_handler_ids()
    end

    test "is a no-op when platform is :host" do
      {:ok, host_pid} = MockNIF.start(:host)
      BoundNIF.bind(host_pid)
      assert :ok = NativeLogger.install(nif: BoundNIF)
      refute :mob_native_logger in :logger.get_handler_ids()
    end

    test "returns :ok if handler already installed" do
      assert :ok = NativeLogger.install(nif: BoundNIF)
      assert :ok = NativeLogger.install(nif: BoundNIF)
    end
  end

  # ── log/2 (handler callback) ─────────────────────────────────────────────────

  describe "log/2 handler callback" do
    setup do
      NativeLogger.install(nif: BoundNIF)
      :ok
    end

    test "routes :string messages to nif.log", %{nif_pid: pid} do
      NativeLogger.log(
        %{level: :info, msg: {:string, "hello world"}, meta: %{}},
        %{nif: BoundNIF}
      )

      assert [{:info, "hello world"}] = MockNIF.calls(pid)
    end

    test "routes :report messages to nif.log as inspect output", %{nif_pid: pid} do
      NativeLogger.log(
        %{level: :warning, msg: {:report, %{key: :value}}, meta: %{}},
        %{nif: BoundNIF}
      )

      [{:warning, text}] = MockNIF.calls(pid)
      assert text =~ "key"
      assert text =~ "value"
    end

    test "routes :format messages to nif.log", %{nif_pid: pid} do
      NativeLogger.log(
        %{level: :error, msg: {:format, "count=~p", [42]}, meta: %{}},
        %{nif: BoundNIF}
      )

      assert [{:error, "count=42"}] = MockNIF.calls(pid)
    end

    test "Logger.info/1 reaches the handler end-to-end", %{nif_pid: pid} do
      Logger.info("end-to-end test")
      # Give the async logger handler a moment to flush
      Process.sleep(50)
      calls = MockNIF.calls(pid)

      assert Enum.any?(calls, fn {level, msg} ->
               level == :info and String.contains?(msg, "end-to-end test")
             end)
    end

    test "Logger.error/1 reaches the handler with :error level", %{nif_pid: pid} do
      Logger.error("something broke")
      Process.sleep(50)
      calls = MockNIF.calls(pid)

      assert Enum.any?(calls, fn {level, msg} ->
               level == :error and String.contains?(msg, "something broke")
             end)
    end
  end

  # ── level_to_nif/1 ───────────────────────────────────────────────────────────

  describe "level_to_nif/1" do
    test "maps :debug to :debug", do: assert(NativeLogger.level_to_nif(:debug) == :debug)
    test "maps :info to :info", do: assert(NativeLogger.level_to_nif(:info) == :info)
    test "maps :notice to :info", do: assert(NativeLogger.level_to_nif(:notice) == :info)
    test "maps :warning to :warning", do: assert(NativeLogger.level_to_nif(:warning) == :warning)
    test "maps :error to :error", do: assert(NativeLogger.level_to_nif(:error) == :error)
    test "maps :critical to :error", do: assert(NativeLogger.level_to_nif(:critical) == :error)
    test "maps :alert to :error", do: assert(NativeLogger.level_to_nif(:alert) == :error)
    test "maps :emergency to :error", do: assert(NativeLogger.level_to_nif(:emergency) == :error)
  end

  # ── format_msg/2 ─────────────────────────────────────────────────────────────

  describe "format_msg/2" do
    test "{:string, iodata} returns binary" do
      assert NativeLogger.format_msg({:string, "hello"}, %{}) == "hello"
    end

    test "{:string, iolist} converts to binary" do
      assert NativeLogger.format_msg({:string, ["hel", "lo"]}, %{}) == "hello"
    end

    test "{:report, map} returns inspect string" do
      assert NativeLogger.format_msg({:report, %{a: 1}}, %{}) =~ "a: 1"
    end

    test "{:format, fmt, args} applies format" do
      result = NativeLogger.format_msg({:format, "x=~p y=~p", [1, 2]}, %{})
      assert result == "x=1 y=2"
    end
  end
end
