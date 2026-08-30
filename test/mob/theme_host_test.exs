defmodule Mob.ThemeHostTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  test "repeated host color-scheme reads do not repeatedly probe the unavailable NIF" do
    log =
      capture_log(fn ->
        assert Enum.map(1..3, fn _ -> Mob.Theme.color_scheme() end) == [:light, :light, :light]

        tasks = Enum.map(1..10, fn _ -> Task.async(&Mob.Theme.color_scheme/0) end)
        assert Enum.map(tasks, &Task.await/1) == List.duplicate(:light, 10)

        Process.sleep(100)
      end)

    warnings = :binary.matches(log, "The on_load function for module mob_nif returned")
    assert Enum.count(warnings) <= 1
  end
end
