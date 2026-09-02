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

  describe "render stats travel with the tree they measured" do
    # The screen process casts its frame separately from the render it
    # describes. Binding the two when the render cast is dequeued — rather than
    # looking the frame up again at flush time — is what keeps a frame from
    # being attributed to a tree it did not measure.
    setup do
      Mob.RenderStats.enable()
      Mob.RenderStats.reset()
      on_exit(fn -> Mob.RenderStats.disable() end)
      :ok
    end

    defp labelled_frame(screen) do
      Mob.RenderStats.start_frame(screen, :none)
      Mob.RenderStats.take_frame()
    end

    defp recorded do
      for f <- Mob.RenderStats.frames(), do: {f.screen, f.committed}
    end

    test "a superseded tree's frame is dropped, not committed against the newer tree" do
      state = %Sender{active: :home}

      {:noreply, state} = Sender.handle_cast({:render_stats, :home, labelled_frame(A)}, state)

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("first"), :ios, RecordingNif, :none}, state)

      {:noreply, state} = Sender.handle_cast({:render_stats, :home, labelled_frame(B)}, state)

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("second"), :ios, RecordingNif, :none}, state)

      {:noreply, _state} = Sender.handle_info(:flush, state)

      assert [json] = committed_texts()
      assert json =~ "second"
      assert Enum.sort(recorded()) == [{A, false}, {B, true}]
    end

    test "a flush between a frame and its render does not pair it with the older tree" do
      # Mailbox: stats(A), render(treeA), stats(B), flush, render(treeB). The
      # flush is what `Mob.Sender.sync/1` triggers, and it is called from the
      # router — a different process — so it can land anywhere. Resolving the
      # frame at flush time committed treeA while holding frame B.
      state = %Sender{active: :home}

      {:noreply, state} = Sender.handle_cast({:render_stats, :home, labelled_frame(A)}, state)

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("treeA"), :ios, RecordingNif, :none}, state)

      {:noreply, state} = Sender.handle_cast({:render_stats, :home, labelled_frame(B)}, state)
      {:noreply, state} = Sender.handle_info(:flush, state)

      assert [first] = committed_texts()
      assert first =~ "treeA"
      assert recorded() == [{A, true}]

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("treeB"), :ios, RecordingNif, :none}, state)

      {:noreply, _state} = Sender.handle_info(:flush, state)

      assert [_, second] = committed_texts()
      assert second =~ "treeB"
      assert Enum.sort(recorded()) == [{A, true}, {B, true}]
    end

    test "activating a screen records the queued frame it throws away" do
      # Both activation paths delete a pending tree: it predates the navigation
      # boundary and must not become the new screen's first frame. The BEAM work
      # that built it was still paid for, and navigation boundaries are exactly
      # the transitions this epic is measuring, so it has to be recorded.
      state = %Sender{active: :other}

      {:noreply, state} = Sender.handle_cast({:render_stats, :home, labelled_frame(A)}, state)

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("stale"), :ios, RecordingNif, :none}, state)

      {:reply, :ok, state} = Sender.handle_call({:activate, :home, :push}, self(), state)

      assert state.pending == %{}
      assert recorded() == [{A, false}]
    end

    test "activate_frame records the queued frame it throws away" do
      state = %Sender{active: :other}

      {:noreply, state} = Sender.handle_cast({:render_stats, :home, labelled_frame(A)}, state)

      {:noreply, state} =
        Sender.handle_cast({:render, :home, tree("stale"), :ios, RecordingNif, :none}, state)

      {:reply, _token, state} =
        Sender.handle_call({:activate_frame, :home, :push}, self(), state)

      assert state.pending == %{}
      assert recorded() == [{A, false}]
    end

    test "a staged frame whose render never arrives is swept, not leaked" do
      # A screen killed between hand_off/1 and Mob.Sender.render/5 leaves a
      # staged frame no cast will ever claim. Nothing else removes it, so the
      # map grew without bound and the work was silently lost rather than
      # recorded as dropped.
      old = %{started: System.monotonic_time(:microsecond) - 10_000_000, screen: Dead}
      state = %Sender{active: :home, frames: %{dead_ref: old}}

      {:noreply, state} = Sender.handle_info(:flush, state)

      assert state.frames == %{}
      assert recorded() == [{Dead, false}]
    end

    test "a freshly staged frame survives a flush" do
      # The render that pairs it may still be in the mailbox behind :flush.
      state = %Sender{active: :home, frames: %{live_ref: labelled_frame(A)}}

      {:noreply, state} = Sender.handle_info(:flush, state)

      assert Map.has_key?(state.frames, :live_ref)
      assert recorded() == []
    end

    test "a render dropped by the activation gate drops its frame with it" do
      # The gate returns state untouched on a token mismatch. A frame staged for
      # that ref would otherwise sit there until some later render claimed it.
      state = %Sender{active: :home, activation_gate: {:home, :expected, :push}}

      {:noreply, state} = Sender.handle_cast({:render_stats, :home, labelled_frame(A)}, state)

      {:noreply, state} =
        Sender.handle_cast(
          {:render, :home, tree("stale"), :ios, RecordingNif, :none, :wrong_token},
          state
        )

      assert state.frames == %{}
      assert recorded() == [{A, false}]
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

    test "activation drops a stale pending repaint for the newly active screen" do
      state = %Sender{active: :home}

      {:noreply, state} =
        Sender.handle_cast(
          {:render, :settings, tree("stale"), :ios, RecordingNif, :none},
          state
        )

      {:reply, :ok, state} =
        Sender.handle_call({:activate, :settings, :push}, self(), state)

      assert state.pending == %{}

      {:noreply, state} = Sender.handle_info(:flush, state)
      assert committed_texts() == []

      {:noreply, state} =
        Sender.handle_cast(
          {:render, :settings, tree("fresh"), :ios, RecordingNif, :none},
          state
        )

      {:noreply, _state} = Sender.handle_info(:flush, state)
      assert [json] = committed_texts()
      assert json =~ "fresh"
      assert {:set_transition, :push} in RecordingNif.calls()
    end

    test "a pre-activation render arriving late cannot consume the fresh frame" do
      state = %Sender{active: :home}

      {:reply, token, state} =
        Sender.handle_call({:activate_frame, :settings, :push}, self(), state)

      assert is_reference(token)

      {:noreply, state} =
        Sender.handle_cast(
          {:render, :settings, tree("stale"), :ios, RecordingNif, :none, nil},
          state
        )

      assert state.pending == %{}
      assert state.activation_gate == {:settings, token, :push}

      {:noreply, state} =
        Sender.handle_cast(
          {:render, :settings, tree("fresh"), :ios, RecordingNif, :push, token},
          state
        )

      {:noreply, state} = Sender.handle_info(:flush, state)

      assert state.activation_gate == nil
      assert [json] = committed_texts()
      assert json =~ "fresh"
      refute json =~ "stale"
      assert {:set_transition, :push} in RecordingNif.calls()
    end

    test "activation upgrades sender state loaded before the gate field existed" do
      old_state = Map.delete(%Sender{active: :home}, :activation_gate)

      {:reply, token, state} =
        Sender.handle_call({:activate_frame, :settings, :push}, self(), old_state)

      assert state.active == :settings
      assert state.activation_gate == {:settings, token, :push}
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
