defmodule Mob.SenderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mob.Sender

  # Records what the render path would have called on the native side. Mirrors
  # the stub in renderer_test.exs; kept local so the two can drift apart.
  defmodule RecordingNif do
    def start, do: Agent.start(fn -> [] end, name: __MODULE__)
    def calls, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()
    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

    def clear_taps, do: record({:clear_taps, []})
    def set_transition(t), do: record({:set_transition, t})
    def set_root(json), do: record({:set_root, json})
    def register_tap(_term), do: 0

    defp record(call) do
      Agent.update(__MODULE__, &[call | &1])
      :ok
    end
  end

  defmodule RaisingNif do
    def clear_taps, do: :ok
    def set_transition(_), do: :ok
    def register_tap(_), do: 0
    def set_root(_json), do: raise("native exploded")
  end

  defp tree(text), do: %{type: :text, props: %{text: text}, children: []}

  defp committed_texts do
    for {:set_root, json} <- RecordingNif.calls(), do: json
  end

  setup do
    # Order matters: a sender left running from an earlier test can still have a
    # flush queued, and it would record into the fresh recorder.
    case Process.whereis(Sender) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    case Process.whereis(RecordingNif) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end

    RecordingNif.start()
    :ok
  end

  defp start_sender(active) do
    {:ok, pid} = Sender.start_link(active: active)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  describe "committing" do
    test "commits a tree for the active screen" do
      start_sender(:home)
      Sender.render(:home, tree("hello"), :ios, RecordingNif, :none)
      Sender.sync()

      assert [json] = committed_texts()
      assert json =~ "hello"
    end

    test "issues the full clear/transition/set_root sequence" do
      start_sender(:home)
      Sender.render(:home, tree("x"), :ios, RecordingNif, :push)
      Sender.sync()

      assert [{:clear_taps, []}, {:set_transition, :push}, {:set_root, _}] = RecordingNif.calls()
    end

    test "drops a tree for a screen that is not active" do
      start_sender(:home)
      Sender.render(:settings, tree("inactive"), :ios, RecordingNif, :none)
      Sender.sync()

      assert committed_texts() == []
    end

    test "set_active/1 changes which screen may commit" do
      start_sender(:home)
      Sender.set_active(:settings)
      Sender.render(:home, tree("stale"), :ios, RecordingNif, :none)
      Sender.render(:settings, tree("fresh"), :ios, RecordingNif, :none)
      Sender.sync()

      assert [json] = committed_texts()
      assert json =~ "fresh"
    end
  end

  describe "coalescing" do
    # Driven through the callbacks rather than the running process: whether two
    # casts land before a flush is a scheduling race, and the point being pinned
    # is what the sender does when they do.
    test "a newer tree for the same screen supersedes the one waiting" do
      state = %Sender{active: :home}

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("first"), :ios, RecordingNif, :none}, state)

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("second"), :ios, RecordingNif, :none}, state)

      assert map_size(state.pending) == 1

      {:noreply, state} = Sender.handle_info(:flush, state)

      assert [json] = committed_texts()
      assert json =~ "second"
      refute json =~ "first"
      assert state.pending == %{}
    end

    test "a flush drops every queued tree, not just the one it commits" do
      state = %Sender{active: :home}

      {:noreply, state} =
        Sender.handle_cast({:render, :settings, tree("other"), :ios, RecordingNif, :none}, state)

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("mine"), :ios, RecordingNif, :none}, state)

      {:noreply, state} = Sender.handle_info(:flush, state)

      assert state.pending == %{}
      assert [json] = committed_texts()
      assert json =~ "mine"
    end

    test "a flush with nothing pending for the active screen commits nothing" do
      {:noreply, state} = Sender.handle_info(:flush, %Sender{active: :home})
      assert committed_texts() == []
      assert state.pending == %{}
    end
  end

  describe "coalescing preserves the transition" do
    test "an immediate first paint cannot overtake its navigation transition" do
      start_sender(:home)

      assert :ok = Sender.activate(:details, :push)
      Sender.render(:details, tree("mounted"), :android, RecordingNif, :none)
      Sender.sync()

      Sender.render(:details, tree("loaded"), :android, RecordingNif, :none)
      Sender.sync()

      transitions = for {:set_transition, transition} <- RecordingNif.calls(), do: transition

      assert transitions == [:push, :none]

      assert [mounted, loaded] = committed_texts()
      assert mounted =~ "mounted"
      assert loaded =~ "loaded"
    end

    test "an ordinary first paint consumes the activated navigation transition" do
      state = %Sender{active: :home}

      {:reply, :ok, state} = Sender.handle_call({:activate, :details, :push}, self(), state)

      {:noreply, state} =
        Sender.handle_cast({:render, :details, tree("first"), :ios, RecordingNif, :none}, state)

      assert state.reserved_transition == nil
      {:noreply, _state} = Sender.handle_info(:flush, state)

      assert {:set_transition, :push} in RecordingNif.calls()
    end

    test "the activated transition survives a second ordinary paint before flush" do
      state = %Sender{active: :home}

      {:reply, :ok, state} = Sender.handle_call({:activate, :details, :push}, self(), state)

      {:noreply, state} =
        Sender.handle_cast({:render, :details, tree("first"), :ios, RecordingNif, :none}, state)

      {:noreply, state} =
        Sender.handle_cast({:render, :details, tree("latest"), :ios, RecordingNif, :none}, state)

      {:noreply, _state} = Sender.handle_info(:flush, state)

      assert {:set_transition, :push} in RecordingNif.calls()
      assert [json] = committed_texts()
      assert json =~ "latest"
    end

    test "activation without a transition leaves the first paint ordinary" do
      state = %Sender{active: :home}

      {:reply, :ok, state} = Sender.handle_call({:activate, :settings, :none}, self(), state)

      {:noreply, state} =
        Sender.handle_cast({:render, :settings, tree("first"), :ios, RecordingNif, :none}, state)

      {:noreply, _state} = Sender.handle_info(:flush, state)

      assert {:set_transition, :none} in RecordingNif.calls()
    end

    test "a push superseded by an ordinary re-render still animates as a push" do
      state = %Sender{active: :home}

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("a"), :ios, RecordingNif, :push}, state)

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("b"), :ios, RecordingNif, :none}, state)

      {:noreply, _state} = Sender.handle_info(:flush, state)

      assert {:set_transition, :push} in RecordingNif.calls()
      assert [json] = committed_texts()
      assert json =~ "b"
    end

    test "a newer transition wins over an older one" do
      state = %Sender{active: :home}

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("a"), :ios, RecordingNif, :push}, state)

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("b"), :ios, RecordingNif, :pop}, state)

      {:noreply, _state} = Sender.handle_info(:flush, state)

      assert {:set_transition, :pop} in RecordingNif.calls()
      refute {:set_transition, :push} in RecordingNif.calls()
    end

    test "a plain re-render with nothing pending stays :none" do
      state = %Sender{active: :home}

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("a"), :ios, RecordingNif, :none}, state)

      {:noreply, _state} = Sender.handle_info(:flush, state)

      assert {:set_transition, :none} in RecordingNif.calls()
    end
  end

  describe "ensure_started/0" do
    test "starts the sender when it is missing" do
      refute Sender.running?()
      assert :ok = Sender.ensure_started()
      assert Sender.running?()
      on_exit(fn -> if Sender.running?(), do: GenServer.stop(Sender) end)
    end

    test "is a no-op when one is already running" do
      pid = start_sender(:home)
      assert :ok = Sender.ensure_started()
      assert Process.whereis(Sender) == pid
    end

    test "does not link to the caller — a screen crash must not take it down" do
      test_pid = self()

      caller =
        spawn(fn ->
          Sender.ensure_started()
          send(test_pid, :started)
          receive do: (:die -> exit(:boom))
        end)

      assert_receive :started
      sender = Process.whereis(Sender)
      ref = Process.monitor(caller)
      send(caller, :die)
      assert_receive {:DOWN, ^ref, :process, ^caller, _}

      assert Process.alive?(sender)
      on_exit(fn -> if Sender.running?(), do: GenServer.stop(Sender) end)
    end
  end

  describe "resilience" do
    test "a render that raises does not take the sender down" do
      pid = start_sender(:home)

      capture_log(fn ->
        Sender.render(:home, tree("boom"), :ios, RaisingNif, :none)
        Sender.sync()
      end)

      assert Process.alive?(pid)

      # And it still serves the next screen — losing this process would freeze
      # the whole UI, since every screen renders through it.
      Sender.render(:home, tree("after"), :ios, RecordingNif, :none)
      Sender.sync()
      assert [json] = committed_texts()
      assert json =~ "after"
    end
  end

  describe "sync/1" do
    test "returns only after queued renders have been committed" do
      start_sender(:home)

      for i <- 1..20 do
        Sender.render(:home, tree("frame #{i}"), :ios, RecordingNif, :none)
      end

      Sender.sync()

      # Coalescing means the count is not 20, but the LAST frame must be on
      # screen by the time sync returns — that is the guarantee callers rely on.
      assert List.last(committed_texts()) =~ "frame 20"
    end
  end

  describe "running?/0" do
    test "false when not started, true once it is" do
      refute Sender.running?()
      start_sender(:home)
      assert Sender.running?()
    end
  end
end
