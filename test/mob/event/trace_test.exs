defmodule Mob.Event.TraceTest do
  use ExUnit.Case, async: false

  alias Mob.Event
  alias Mob.Event.{Address, Trace}

  setup do
    on_exit(fn -> Trace.stop() end)
    :ok
  end

  defp addr(opts \\ []) do
    Address.new(Keyword.merge([screen: TestScreen, widget: :button, id: :save], opts))
  end

  describe "subscribe/0 + dispatch/4 broadcast" do
    test "subscriber receives trace of every event" do
      :ok = Trace.subscribe()

      :ok = Event.dispatch(self(), addr(), :tap, nil)

      # Two messages: the direct delivery (because we dispatched to self) plus the trace.
      assert_receive {:mob_event, _, :tap, nil}
      assert_receive {:mob_trace, %Address{id: :save}, :tap, nil}
    end

    test "multiple subscribers all see the event" do
      parent = self()

      task =
        Task.async(fn ->
          Trace.subscribe()
          # The dispatch below must not run until this subscription is in the
          # table. Sleeping guessed at how long that takes across processes;
          # the ready-message is the actual ordering constraint.
          send(parent, :subscribed)
          assert_receive {:mob_trace, _, :tap, nil}, 200
          :got_it
        end)

      Trace.subscribe()
      assert_receive :subscribed

      :ok = Event.dispatch(self(), addr(), :tap, nil)

      assert_receive {:mob_trace, _, :tap, nil}
      assert Task.await(task) == :got_it
    end

    test "filter narrows the events delivered" do
      :ok = Trace.subscribe(fn a -> a.widget == :list end)

      :ok = Event.dispatch(self(), addr(widget: :button), :tap, nil)
      :ok = Event.dispatch(self(), addr(widget: :list, id: :contacts), :select, nil)

      assert_receive {:mob_trace, %Address{widget: :list}, :select, nil}
      refute_receive {:mob_trace, %Address{widget: :button}, _, _}, 50
    end

    test "filter that raises is treated as non-match" do
      :ok = Trace.subscribe(fn _ -> raise "oops" end)

      :ok = Event.dispatch(self(), addr(), :tap, nil)

      refute_receive {:mob_trace, _, _, _}, 50
    end

    test "a filter that throws or exits is a non-match, not a crash of the dispatcher" do
      :ok = Trace.subscribe(fn _ -> throw(:nope) end)
      :ok = Event.dispatch(self(), addr(), :tap, nil)

      :ok = Trace.subscribe(fn _ -> exit(:nope) end)
      :ok = Event.dispatch(self(), addr(), :tap, nil)

      refute_receive {:mob_trace, _, _, _}, 50
    end
  end

  describe "unsubscribe/0" do
    test "removes the subscriber" do
      Trace.subscribe()
      Trace.unsubscribe()

      :ok = Event.dispatch(self(), addr(), :tap, nil)

      refute_receive {:mob_trace, _, _, _}, 50
    end
  end

  describe "stop/0" do
    test "unsubscribes every tracer, so dispatch sends no trace" do
      :ok = Trace.subscribe()
      Trace.stop()

      :ok = Event.dispatch(self(), addr(), :tap, nil)

      # Direct event still arrives:
      assert_receive {:mob_event, _, :tap, nil}
      # No trace:
      refute_receive {:mob_trace, _, _, _}, 50
    end
  end

  describe "dead subscriber cleanup" do
    test "a tracer that exits is pruned without unsubscribing" do
      parent = self()

      pid =
        spawn(fn ->
          Trace.subscribe()
          send(parent, :subscribed)
        end)

      assert_receive :subscribed
      Mob.Test.ProcessHelpers.await_exit(pid)

      Mob.Test.ProcessHelpers.eventually(fn ->
        not List.keymember?(Mob.Diag.Subscribers.list(:event_trace), pid, 0)
      end)

      :ok = Event.dispatch(self(), addr(), :tap, nil)
    end

    test "the table-free registry survives the process that first subscribed" do
      # The old table was created by whichever process called `start/0`; over
      # `:rpc` that process exits at once and took tracing with it.
      Task.await(Task.async(fn -> Trace.subscribe(self(), nil) end))

      :ok = Trace.subscribe()
      :ok = Event.dispatch(self(), addr(), :tap, nil)

      assert_receive {:mob_trace, %Address{id: :save}, :tap, nil}
    end
  end

  describe "subscribe/2" do
    test "delivers to the given pid rather than the caller" do
      parent = self()

      # The call runs in a short-lived process, as `:rpc.call/4` would.
      Task.await(Task.async(fn -> Trace.subscribe(parent, nil) end))

      :ok = Event.dispatch(self(), addr(), :tap, nil)
      assert_receive {:mob_trace, %Address{id: :save}, :tap, nil}
    end
  end
end
