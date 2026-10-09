defmodule Mob.Screen.AsyncTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Every task reports back to the test through `test`, so a test can wait for
  # a task to be running, or hold it until it is told to finish.
  defmodule LoadScreen do
    use Mob.Screen

    def mount(%{test: test} = params, _session, socket) do
      socket =
        socket
        |> Mob.Socket.assign(test: test, outcomes: [], infos: [])
        |> Mob.Socket.assign(:profile, :loading)

      socket =
        if params[:start_in_mount],
          do: Mob.Socket.start_async(socket, :profile, fn -> {:profile, "Ada"} end),
          else: socket

      {:ok, socket}
    end

    def render(assigns),
      do: %{type: :text, props: %{text: inspect(assigns.profile)}, children: []}

    def handle_event("start", %{"name" => name, "fun" => fun}, socket),
      do: {:noreply, Mob.Socket.start_async(socket, name, fun)}

    def handle_event("cancel", %{"name" => name}, socket),
      do: {:noreply, Mob.Socket.cancel_async(socket, name)}

    def handle_async(name, outcome, socket) do
      send(socket.assigns.test, {:handle_async, name, outcome})
      outcomes = [{name, outcome} | socket.assigns.outcomes]
      {:noreply, Mob.Socket.assign(socket, :outcomes, outcomes)}
    end

    def handle_info(message, socket),
      do: {:noreply, Mob.Socket.assign(socket, :infos, [message | socket.assigns.infos])}
  end

  defmodule NoHandlerScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: ""}, children: []}
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    @home Mob.Screen.AsyncTest.LoadScreen
    def navigation(_), do: stack(:home, root: @home)
  end

  setup do
    Mob.Test.ProcessHelpers.stop_if_running(Mob.Nav.Registry)
    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)
    on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(registry) end)
    :ok
  end

  defp start_screen(params \\ %{}) do
    {:ok, owner} = Mob.Screen.start_link(LoadScreen, Map.put(params, :test, self()))
    on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(owner) end)
    {owner, Mob.Screen.get_screen_pid(owner)}
  end

  # Blocks the task until the test sends it :go, after telling the test its pid.
  defp held(test, value) do
    fn ->
      send(test, {:task, self()})

      receive do
        :go -> value
      end
    end
  end

  defp start(screen, name, fun) do
    {:ok, nil} = Mob.Screen.Server.dispatch(screen, "start", %{"name" => name, "fun" => fun})
  end

  defp assigns(screen), do: :sys.get_state(screen).socket.assigns

  describe "on a running screen" do
    test "a result reaches handle_async and nothing reaches handle_info" do
      {_owner, screen} = start_screen()

      start(screen, :profile, fn -> "Ada" end)

      assert_receive {:handle_async, :profile, {:ok, "Ada"}}
      # The task's :DOWN and its link's :EXIT arrive after its result; a sync
      # call queues behind them.
      assert assigns(screen).infos == []
    end

    test "a task started in mount reports once the screen is up" do
      {_owner, _screen} = start_screen(%{start_in_mount: true})

      assert_receive {:handle_async, :profile, {:ok, {:profile, "Ada"}}}
    end

    test "a crash arrives as {:exit, reason}, leaves the screen up and logs no linked-process exit" do
      {_owner, screen} = start_screen()

      logs =
        capture_log(fn ->
          start(screen, :profile, fn -> raise "api down" end)

          assert_receive {:handle_async, :profile,
                          {:exit, {%RuntimeError{message: "api down"}, _}}}

          assigns(screen)
        end)

      assert Process.alive?(screen)
      assert assigns(screen).infos == []
      refute logs =~ "linked process"
    end

    test "starting a running name replaces it: the old task dies and only the new one reports" do
      {_owner, screen} = start_screen()

      start(screen, :search, held(self(), "old"))
      assert_receive {:task, old}
      ref = Process.monitor(old)

      start(screen, :search, fn -> "new" end)

      assert_receive {:DOWN, ^ref, :process, ^old, :killed}
      assert_receive {:handle_async, :search, {:ok, "new"}}
      refute_receive {:handle_async, :search, _}, 50
      assert assigns(screen).infos == []
    end

    test "cancel_async stops the task and reports {:exit, {:shutdown, :cancel}}" do
      {_owner, screen} = start_screen()

      start(screen, :profile, held(self(), "never"))
      assert_receive {:task, task}
      ref = Process.monitor(task)

      {:ok, nil} = Mob.Screen.Server.dispatch(screen, "cancel", %{"name" => :profile})

      assert_receive {:DOWN, ^ref, :process, ^task, _reason}
      assert_receive {:handle_async, :profile, {:exit, {:shutdown, :cancel}}}
      refute_receive {:handle_async, :profile, _}, 50
      assert assigns(screen).infos == []
    end

    test "cancelling an unknown name does nothing" do
      {_owner, screen} = start_screen()

      {:ok, nil} = Mob.Screen.Server.dispatch(screen, "cancel", %{"name" => :nothing})

      refute_receive {:handle_async, _, _}, 50
      assert Process.alive?(screen)
    end

    test "stopping the screen with :normal kills its running task" do
      {owner, screen} = start_screen()

      start(screen, :profile, held(self(), "never"))
      assert_receive {:task, task}
      ref = Process.monitor(task)

      # The router restarts the stopped screen and says so; that is not under test.
      capture_log(fn ->
        GenServer.stop(screen, :normal)
        assert_receive {:DOWN, ^ref, :process, ^task, :killed}
        :sys.get_state(owner)
      end)
    end

    test "a screen without handle_async/3 cannot start a task" do
      assert_raise ArgumentError, ~r/NoHandlerScreen does not define/, fn ->
        Mob.Socket.start_async(Mob.Socket.new(NoHandlerScreen), :x, fn -> :ok end)
      end
    end
  end

  describe "Mob.Socket.cancel_async/3" do
    test "rejects :normal, which would not stop the task" do
      socket = Mob.Socket.new(LoadScreen)

      assert_raise ArgumentError, ~r/:normal/, fn ->
        Mob.Socket.cancel_async(socket, :profile, :normal)
      end
    end

    test "a result already waiting in the mailbox is reported as cancelled, not delivered" do
      socket = Mob.Socket.start_async(Mob.Socket.new(LoadScreen), :profile, fn -> "done" end)
      wait_for_result_in_mailbox()

      socket = Mob.Socket.cancel_async(socket, :profile)

      assert {:deliver, :profile, {:exit, {:shutdown, :cancel}}, socket} =
               Mob.Screen.Async.await(socket, 100)

      refute Mob.Screen.Async.pending?(socket)
      refute_receive {Mob.Screen.Async, _, _}, 50
    end

    test "a result the task sends after the cancel is dropped" do
      # Process.exit/2 is asynchronous: a task finishing on another scheduler
      # can send its result after cancel_async/3 flushed the mailbox, landing
      # ahead of the {:exit, _} it posts. Simulated by handling that late result
      # first.
      socket = Mob.Socket.start_async(Mob.Socket.new(LoadScreen), :profile, held(self(), "x"))
      assert_receive {:task, _}
      %{profile: %{token: token}} = socket.__mob__.async

      socket = Mob.Socket.cancel_async(socket, :profile)
      late = {Mob.Screen.Async, token, {:ok, "late"}}

      assert {:dropped, socket} = Mob.Screen.Async.handle_message(late, socket)

      assert {:deliver, :profile, {:exit, {:shutdown, :cancel}}, _socket} =
               Mob.Screen.Async.await(socket, 100)
    end
  end

  defp wait_for_result_in_mailbox do
    {:messages, messages} = Process.info(self(), :messages)

    unless Enum.any?(messages, &match?({Mob.Screen.Async, _, {:ok, _}}, &1)) do
      Process.sleep(5)
      wait_for_result_in_mailbox()
    end
  end
end
