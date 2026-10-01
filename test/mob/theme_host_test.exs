defmodule Mob.ThemeHostTest do
  use ExUnit.Case, async: false

  test "all host theme callers share exactly one failed NIF probe" do
    script = ~S'''
    Application.ensure_all_started(:ex_unit)
    import ExUnit.CaptureLog

    # The on_load failure is logged by the process that ran on_load, which can
    # happen after the probing call has returned, so count the reports as
    # they arrive rather than reading a capture once the calls are done.
    defmodule OnLoadSpy do
      def log(%{msg: msg}, %{config: %{to: pid}}) do
        if inspect(msg) =~ "on_load function for module", do: send(pid, :on_load_failed)
      end
    end

    :ok = :logger.add_handler(:on_load_spy, OnLoadSpy, %{config: %{to: self()}})

    key = {Mob.Theme, :nif_status}
    :persistent_term.erase(key)
    :unknown = :persistent_term.get(key, :unknown)

    calls =
      List.duplicate(&Mob.Theme.color_scheme/0, 6) ++
        List.duplicate(fn -> Mob.Theme.set(Mob.Theme.default()) end, 6)

    capture_log(fn ->
      tasks = Enum.map(calls, fn call -> Task.async(fn -> receive do: (:go -> call.()) end) end)
      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await/1)
      true = Enum.all?(results, &(&1 in [:light, :ok]))
      :ok = receive do: (:on_load_failed -> :ok), after: (5_000 -> :never_logged)
      :ok = receive do: (:on_load_failed -> :logged_twice), after: (500 -> :ok)
    end)

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
      Logger.flush()
    end)

    :persistent_term.erase(key)
    :unknown = :persistent_term.get(key, :unknown)
    IO.puts("recovery_ok")
    '''

    assert_isolated_success(script, "recovery_ok")
  end

  # A stand-in mob_nif whose color_scheme/0 holds the probe until released,
  # then raises (a failed probe) or answers :dark, per :mob311_mode.
  @blocking_fake_nif ~S'''
  :persistent_term.put(:mob311_parent, self())

  Code.compile_string("""
  defmodule :mob_nif do
    def platform, do: :ios
    def set_theme(_json), do: :ok

    def color_scheme do
      case :persistent_term.get(:mob311_mode) do
        :dark ->
          :dark

        hold ->
          send(:persistent_term.get(:mob311_parent), {:holding, self()})
          receive do: (:release -> :ok)
          if hold == :hold_then_raise, do: raise("probe failed"), else: :dark
      end
    end
  end
  """)
  '''

  # MOB-311: the probe lock was `:global.trans(_, _, [node()])`. A probing
  # caller that stays alive across `Node.start` released on `:nonode@nohost`,
  # so the lock leaked and the next probe blocked for good.
  test "starting distribution during a held probe does not wedge the next probe" do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    script =
      @blocking_fake_nif <>
        ~S'''
        key = {Mob.Theme, :nif_status}
        :persistent_term.erase(key)
        :persistent_term.put(:mob311_mode, :hold_then_raise)

        parent = self()
        spawn(fn ->
          send(parent, {:first, Mob.Theme.color_scheme()})
          Process.sleep(:infinity)
        end)

        prober = receive do {:holding, pid} -> pid after 5_000 -> raise "probe never started" end
        name = List.to_atom(:peer.random_name(~c"mob311") ++ ~c"@127.0.0.1")
        {:ok, _} = Node.start(name, :longnames)
        send(prober, :release)
        :light = receive do {:first, scheme} -> scheme after 5_000 -> raise "first probe hung" end
        :unavailable = :persistent_term.get(key)

        :persistent_term.put(:mob311_mode, :dark)
        second = Task.async(&Mob.Theme.color_scheme/0)
        {:ok, :dark} = Task.yield(second, 5_000) || {:wedged, Task.shutdown(second, :brutal_kill)}
        IO.puts("dist_start_ok")
        '''

    assert_isolated_success(script, "dist_start_ok")
  end

  test "callers queued behind a held probe finish as soon as it does" do
    script =
      @blocking_fake_nif <>
        ~S'''
        key = {Mob.Theme, :nif_status}
        :persistent_term.erase(key)
        :persistent_term.put(:mob311_mode, :hold_then_dark)

        first = Task.async(&Mob.Theme.color_scheme/0)
        prober = receive do {:holding, pid} -> pid after 5_000 -> raise "probe never started" end

        :persistent_term.put(:mob311_mode, :dark)
        waiters = for _ <- 1..11, do: Task.async(&Mob.Theme.color_scheme/0)
        # Long enough for `:global`'s retry to have grown every waiter's
        # random back-off sleep (up to 0.25-1 s each).
        Process.sleep(500)

        released = System.monotonic_time(:millisecond)
        send(prober, :release)
        true = Enum.all?(Task.await_many([first | waiters], 5_000), &(&1 == :dark))
        elapsed = System.monotonic_time(:millisecond) - released
        if elapsed >= 100, do: raise("queued callers took #{elapsed} ms after release")
        IO.puts("no_backoff_ok")
        '''

    assert_isolated_success(script, "no_backoff_ok")
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
