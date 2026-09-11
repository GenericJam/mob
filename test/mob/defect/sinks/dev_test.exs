defmodule Mob.Defect.Sinks.DevTest do
  # Not async — Bus and Logger are process-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mob.Defect.Bus
  alias Mob.Defect.Capsule
  alias Mob.Defect.Sinks.Dev

  setup do
    Bus.start()
    Bus.reset()
    :ok
  end

  defp capsule(severity, kind \\ :invariant) do
    Capsule.new(
      kind: kind,
      owner: :mob,
      severity: severity,
      fingerprint_key: %{invariant: :leaked_component, screen: MyScreen}
    )
  end

  defp with_sink(fun) do
    {:ok, pid} = Dev.start_link(name: :"dev_sink_#{System.unique_integer([:positive])}")

    try do
      fun.(pid)
    after
      # Give the sink a beat to process any last message before stopping,
      # so tests can assert on Logger output without racing.
      Process.sleep(20)
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  test "logs at :error for fatal and critical capsules" do
    log =
      capture_log(fn ->
        with_sink(fn _ ->
          Bus.emit(capsule(:fatal))
          Bus.emit(capsule(:critical, :beam_crash))
          Process.sleep(20)
        end)
      end)

    # Two [error] lines, one for each of :fatal and :critical
    error_lines = log |> String.split("\n") |> Enum.filter(&String.contains?(&1, "[error]"))
    assert length(error_lines) == 2
  end

  test "logs at :warning for warning severity" do
    log =
      capture_log(fn ->
        with_sink(fn _ ->
          Bus.emit(capsule(:warning))
          Process.sleep(20)
        end)
      end)

    assert log =~ "[warning]"
    assert log =~ "defect warning"
  end

  test "the emitted line names the fingerprint (short form) and severity" do
    c = capsule(:critical)
    short = c.fingerprint |> String.replace_prefix("sha256:", "") |> String.slice(0, 8)

    log =
      capture_log(fn ->
        with_sink(fn _ ->
          Bus.emit(c)
          Process.sleep(20)
        end)
      end)

    assert log =~ "defect critical"
    assert log =~ "fp=#{short}"
  end

  test "unsubscribes on terminate — no delivery after stop" do
    {:ok, pid} = Dev.start_link(name: :"dev_sink_teardown_#{System.unique_integer([:positive])}")

    Bus.emit(capsule(:warning))
    Process.sleep(20)

    # Sink is registered while alive
    assert pid in Bus.subscribers()

    GenServer.stop(pid)
    Process.sleep(20)

    refute pid in Bus.subscribers()
  end
end
