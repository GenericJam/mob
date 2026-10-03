defmodule Mob.Screen.CrashRedactionTest do
  @moduledoc """
  MOB-310. A screen crash is logged by the router, by OTP's gen_server crash
  report, and on a device by `Mob.NativeLogger` into logcat, where bug reports
  and adb read it. None of those may carry the screen's assigns or a typed
  value, so each test puts a secret in them and searches both sinks for it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @secret "s3cr3t-MOB310"

  defmodule Screen do
    use Mob.Screen

    @secret "s3cr3t-MOB310"

    # The KeyError's message embeds the params.
    def mount(%{"fail_mount" => true} = params, _session, _socket),
      do: Map.fetch!(params, :no_such_key)

    # A refusal whose reason carries the params, as {:error, reason}.
    def mount(%{"refuse" => true} = params, _session, _socket), do: {:error, {:refused, params}}

    def mount(params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, %{password: @secret, params: params})}

    def render(_assigns), do: %{type: :text, props: %{text: "x"}, children: []}

    # The KeyError's message embeds the whole assigns map.
    def handle_event("key_error", _params, socket),
      do: {:noreply, Map.fetch!(socket.assigns, :no_such_key)}

    # Only this event matches, so any other is a FunctionClauseError whose
    # stack frame holds the event, the params and the socket.
    def handle_event("noop", _params, socket), do: {:noreply, socket}

    # gen_server takes a thrown value as the callback's return value and exits
    # with {:bad_return_value, value}, here the socket.
    def handle_event("throw", _params, socket), do: throw({:gave_up, socket})

    # Shaped like an {:event, name, params} message, whose name message/1 keeps.
    def handle_event("throw_event_shaped", _params, socket),
      do: throw({:event, socket.assigns.password, nil})

    def handle_event("crash_task", _params, socket) do
      Task.start_link(fn -> Map.fetch!(socket.assigns, :no_such_key) end)
      {:noreply, socket}
    end

    def handle_event("push_restarts", _params, socket) do
      dest = Mob.Screen.CrashRedactionTest.Restarts
      {:noreply, Mob.Socket.push_screen(socket, dest, %{"token" => @secret})}
    end

    def handle_event("push_no_handlers", _params, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, Mob.Screen.CrashRedactionTest.NoHandlers)}

    # A typed value arrives as the message itself: OTP's "last message".
    def handle_info({:change, :name, _value}, _socket), do: raise(ArgumentError, "bad change")

    # Crashes with a typed value still queued and a secret in the dictionary,
    # both of which proc_lib's crash report reads straight from the process.
    def handle_info(:crash_with_queue, _socket) do
      send(self(), {:change, :name, @secret})
      Process.put(:mob310_token, @secret)
      raise ArgumentError, "queued"
    end

    def handle_info(_message, socket), do: {:noreply, socket}
  end

  # Mounts once; every re-mount raises a KeyError embedding its params.
  defmodule Restarts do
    use Mob.Screen

    def mount(params, _session, socket) do
      if :persistent_term.get({__MODULE__, :mounted}, false) do
        Map.fetch!(params, :no_such_key)
      else
        :persistent_term.put({__MODULE__, :mounted}, true)
        {:ok, socket}
      end
    end

    def render(_assigns), do: %{type: :text, props: %{text: "x"}, children: []}
    def handle_event("boom", _params, _socket), do: raise("restarts exploded")
  end

  # No handle_event/3 of its own, so `use Mob.Screen`'s catch-all raises
  # Mob.Screen.UnhandledEventError, whose message the framework writes.
  defmodule NoHandlers do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "x"}, children: []}
  end

  defmodule Component do
    use Mob.Component

    @secret "s3cr3t-MOB310"

    def mount(props, socket) do
      socket = Mob.Socket.assign(socket, :password, @secret)
      {:ok, Mob.Socket.assign(socket, :observer, Map.get(props, :observer))}
    end

    def terminate(reason, socket) do
      if observer = socket.assigns.observer, do: send(observer, {:component_terminate, reason})
      :ok
    end

    def render(_assigns), do: %{}
    def handle_event("noop", _payload, socket), do: {:noreply, socket}
  end

  defmodule Nif do
    @moduledoc false
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def platform, do: :ios
    def take_launch_notification, do: :none
    def take_launch_link, do: :none
    def unquote(:"$handle_undefined_function")(_f, _a), do: :ok
  end

  # Stands in for `:mob_nif` behind `Mob.NativeLogger`, so the test reads the
  # exact text a device writes to logcat or NSLog.
  defmodule LogcatNif do
    @moduledoc false
    def platform, do: :android
    def log(_level, text), do: send(:persistent_term.get({__MODULE__, :to}), {:logcat, text})
  end

  setup do
    :persistent_term.put({LogcatNif, :to}, self())
    :ok = Mob.NativeLogger.install(nif: LogcatNif)
    on_exit(fn -> :logger.remove_handler(:mob_native_logger) end)

    {:ok, router} = Mob.Router.start_root(Screen, %{"token" => @secret}, nif: Nif)
    on_exit(fn -> Mob.Test.ProcessHelpers.stop_root(router) end)

    %{router: router}
  end

  defp logcat do
    receive do
      {:logcat, text} -> [text | logcat()]
    after
      0 -> []
    end
  end

  # Everything both sinks received while `fun` ran and, given a router, after
  # it has handled the :DOWN the crash produced.
  defp all_logs(router, fun) do
    console =
      capture_log(fn ->
        fun.()
        if router, do: :sys.get_state(router)
        Logger.flush()
      end)

    Enum.join([console | logcat()], "\n")
  end

  defp assert_redacted(logs, expected) do
    for fragment <- expected, do: assert(logs =~ fragment, logs)
    refute logs =~ @secret, logs
  end

  defp screen_pid(router), do: Mob.Screen.get_screen_pid(router)

  defp crash(router, fun) do
    screen = screen_pid(router)
    ref = Process.monitor(screen)

    all_logs(router, fn ->
      fun.(screen)
      assert_receive {:DOWN, ^ref, :process, ^screen, _reason}, 2_000
    end)
  end

  test "an unmatched event's FunctionClauseError carries neither the params nor the socket",
       %{router: router} do
    logs = crash(router, fn _ -> Mob.Screen.dispatch(router, "unmatched", %{"v" => @secret}) end)

    assert_redacted(logs, [
      "crashed and is being restarted",
      "FunctionClauseError",
      "Mob.Screen.CrashRedactionTest.Screen.handle_event/3",
      "GenServer"
    ])
  end

  test "a value thrown from a handler is not the exit reason", %{router: router} do
    screen = screen_pid(router)
    ref = Process.monitor(screen)
    logs = crash(router, fn _ -> Mob.Screen.dispatch(router, "throw", %{}) end)

    # The exit reason reaches monitors, links and proc_lib's crash report.
    assert_receive {:DOWN, ^ref, :process, ^screen, reason}
    assert {:bad_return_value, {:gave_up, :redacted}} = reason
    assert_redacted(logs, ["{:bad_return_value, {:gave_up, :redacted}}"])
  end

  test "a thrown term keeps only its tag, whatever its shape", %{router: router} do
    screen = screen_pid(router)
    ref = Process.monitor(screen)
    logs = crash(router, fn _ -> Mob.Screen.dispatch(router, "throw_event_shaped", %{}) end)

    assert_receive {:DOWN, ^ref, :process, ^screen, reason}
    assert reason == {:bad_return_value, {:event, :redacted, :redacted}}
    assert_redacted(logs, ["bad_return_value"])
  end

  test "an exception whose message embeds the assigns is logged without its message",
       %{router: router} do
    logs = crash(router, fn _ -> Mob.Screen.dispatch(router, "key_error", %{}) end)
    assert_redacted(logs, ["KeyError", "crashed and is being restarted"])
  end

  test "a typed value in the last message stays out of the crash report", %{router: router} do
    logs = crash(router, fn screen -> send(screen, {:change, :name, @secret}) end)
    assert_redacted(logs, ["ArgumentError", "{:change, :name, :redacted}"])
  end

  test "a picked value stays out of the crash report even when it is an atom",
       %{router: router} do
    logs = crash(router, fn screen -> send(screen, {:change, :name, :s3cr3t_atom_mob310}) end)
    assert_redacted(logs, ["{:change, :name, :redacted}"])
    refute logs =~ "s3cr3t_atom_mob310", logs
  end

  test "a message the framework writes itself is kept", %{router: router} do
    Mob.Screen.dispatch(router, "push_no_handlers", %{})
    assert Mob.Screen.get_current_module(router) == NoHandlers

    logs = crash(router, fn _ -> Mob.Screen.dispatch(router, "ghost", %{"v" => @secret}) end)
    assert_redacted(logs, ["Mob.Screen.UnhandledEventError: unhandled event \"ghost\""])
  end

  test "a linked task that crashes holding the socket is logged by mob without it",
       %{router: router} do
    logs =
      all_logs(router, fn ->
        Mob.Screen.dispatch(router, "crash_task", %{})
        # The task's crash reaches the screen as an :EXIT it logs.
        Process.sleep(50)
        :sys.get_state(screen_pid(router))
      end)

    # The task's own crash report belongs to the app's Task, not to mob.
    mob_lines = logs |> String.split("\n") |> Enum.filter(&(&1 =~ "linked process"))
    assert mob_lines != [], logs
    assert_redacted(Enum.join(mob_lines, "\n"), ["KeyError"])
  end

  test "a re-mount that fails is logged without the mount's params", %{router: router} do
    :persistent_term.erase({Restarts, :mounted})
    on_exit(fn -> :persistent_term.erase({Restarts, :mounted}) end)
    Mob.Screen.dispatch(router, "push_restarts", %{})
    assert Mob.Screen.get_current_module(router) == Restarts

    logs = all_logs(router, fn -> Mob.Screen.dispatch(router, "boom", %{}) end)

    assert_redacted(logs, ["could not be restarted", "KeyError", "Restarts.mount/3"])
  end

  test "a root screen that fails to mount is logged without its params", %{router: router} do
    Mob.Test.ProcessHelpers.stop_root(router)
    # start_root/3 links the router, whose init fails with the mount's crash.
    Process.flag(:trap_exit, true)

    logs =
      all_logs(nil, fn ->
        {:error, _} =
          Mob.Router.start_root(Screen, %{"fail_mount" => true, "token" => @secret}, nif: Nif)
      end)

    assert_redacted(logs, ["failed to start", "KeyError", "Screen.mount/3"])
  end

  test "a root screen that refuses to mount returns a reason without its params",
       %{router: router} do
    Mob.Test.ProcessHelpers.stop_root(router)
    Process.flag(:trap_exit, true)

    logs =
      all_logs(nil, fn ->
        assert {:error, reason} =
                 Mob.Router.start_root(Screen, %{"refuse" => true, "token" => @secret}, nif: Nif)

        assert reason == {:refused, :redacted}
      end)

    assert_redacted(logs, ["failed to start", "{:refused, :redacted}"])
  end

  # proc_lib's crash report (SASL; off unless the app sets
  # `handle_sasl_reports: true`) reads the dying process's mailbox and
  # dictionary directly, so format_status/1 never sees them.
  test "with SASL reports on, a queued value and the dictionary stay out", %{router: router} do
    %{filters: filters} = :logger.get_primary_config()
    {:logger_translator, {translate, config}} = List.keyfind(filters, :logger_translator, 0)

    sasl =
      List.keyreplace(
        filters,
        :logger_translator,
        0,
        {:logger_translator, {translate, %{config | sasl: true}}}
      )

    :ok = :logger.set_primary_config(:filters, sasl)
    on_exit(fn -> :logger.set_primary_config(:filters, filters) end)

    logs = crash(router, fn screen -> send(screen, :crash_with_queue) end)

    # The proc_lib report did arrive; otherwise this proves nothing.
    assert logs =~ "Initial Call: Mob.Screen.Server.init/1", logs
    assert_redacted(logs, ["ArgumentError"])
  end

  test ":sys.get_status/1 keeps the assigns' keys and drops their values", %{router: router} do
    status = inspect(:sys.get_status(screen_pid(router)), limit: :infinity)

    assert status =~ "password"
    refute status =~ @secret
  end

  describe "a component process" do
    defp start_component(screen_pid, props \\ %{}) do
      {:ok, _} = Mob.Test.ProcessHelpers.ensure_component_registry()

      {:ok, pid} =
        Mob.ComponentServer.start(
          module: Component,
          id: :secret_box,
          screen_pid: screen_pid,
          props: props,
          platform: :no_render
        )

      pid
    end

    test "that crashes keeps its assigns and the event payload out of the report",
         %{router: router} do
      component = start_component(screen_pid(router))
      ref = Process.monitor(component)

      logs =
        all_logs(router, fn ->
          Mob.ComponentServer.dispatch(component, "unmatched", %{"v" => @secret})
          assert_receive {:DOWN, ^ref, :process, ^component, _reason}, 2_000
        end)

      assert_redacted(logs, ["FunctionClauseError", "Component.handle_event/3"])
    end

    # A component on a crashing screen is usually stopped with :shutdown
    # before it sees the :DOWN, so this stands in a screen that dies with a raw
    # reason (killed from outside, or running code from before MOB-310): the
    # component stops with that reason and OTP reports it.
    test "stopped by its screen's exit keeps that reason out of its report and its exit",
         %{router: router} do
      screen = spawn(fn -> receive do: (reason -> exit(reason)) end)
      component = start_component(screen, %{observer: self()})
      ref = Process.monitor(component)

      logs =
        all_logs(router, fn ->
          send(screen, {:crashed, %{password: @secret}})
          assert_receive {:DOWN, ^ref, :process, ^component, reason}, 2_000
          assert reason == {:crashed, :redacted}
        end)

      assert_receive {:component_terminate, {:crashed, :redacted}}
      assert_redacted(logs, ["{:crashed, :redacted}", "Last message: {:DOWN"])
    end
  end
end
