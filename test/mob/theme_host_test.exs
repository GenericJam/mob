defmodule Mob.ThemeHostTest do
  use ExUnit.Case, async: false

  test "all host theme callers share exactly one failed NIF probe" do
    script = ~S'''
    Application.ensure_all_started(:ex_unit)
    import ExUnit.CaptureLog

    key = {Mob.Theme, :nif_status}
    :persistent_term.erase(key)
    :unknown = :persistent_term.get(key, :unknown)

    calls =
      List.duplicate(&Mob.Theme.color_scheme/0, 6) ++
        List.duplicate(fn -> Mob.Theme.set(Mob.Theme.default()) end, 6)

    log =
      capture_log(fn ->
        tasks = Enum.map(calls, fn call -> Task.async(fn -> receive do: (:go -> call.()) end) end)
        Enum.each(tasks, &send(&1.pid, :go))
        results = Enum.map(tasks, &Task.await/1)
        true = Enum.all?(results, &(&1 in [:light, :ok]))
        Process.sleep(100)
      end)

    1 = length(:binary.matches(log, "The on_load function for module mob_nif returned"))
    :unavailable = :persistent_term.get(key)
    :persistent_term.erase(key)
    :unknown = :persistent_term.get(key, :unknown)
    IO.puts("shared_probe_ok")
    '''

    assert_isolated_success(script, "shared_probe_ok")
  end

  test "theme NIF availability recovers across module load and unload" do
    script = ~S'''
    Application.ensure_all_started(:ex_unit)
    import ExUnit.CaptureLog

    key = {Mob.Theme, :nif_status}
    :persistent_term.erase(key)
    :unknown = :persistent_term.get(key, :unknown)

    fake_nif = """
    defmodule :mob_nif do
      def platform, do: :ios
      def set_theme(_json), do: :ok
      def color_scheme, do: :dark
    end
    """

    capture_log(fn ->
      :light = Mob.Theme.color_scheme()
      :unavailable = :persistent_term.get(key)

      Code.compile_string(fake_nif)
      :dark = Mob.Theme.color_scheme()
      :ok = Mob.Theme.set(Mob.Theme.default())
      :available = :persistent_term.get(key)

      :code.delete(:mob_nif)
      :code.purge(:mob_nif)
      false = :code.is_loaded(:mob_nif)

      :light = Mob.Theme.color_scheme()
      :unavailable = :persistent_term.get(key)

      Code.compile_string(fake_nif)
      :dark = Mob.Theme.color_scheme()
      :available = :persistent_term.get(key)
      Process.sleep(100)
    end)

    :persistent_term.erase(key)
    :unknown = :persistent_term.get(key, :unknown)
    IO.puts("recovery_ok")
    '''

    assert_isolated_success(script, "recovery_ok")
  end

  defp assert_isolated_success(script, marker) do
    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-start", "-e", script],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ marker
  end
end
