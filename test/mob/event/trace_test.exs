defmodule Mob.Event.TraceTest do
  use ExUnit.Case, async: false

  alias Mob.Event
  alias Mob.Event.{Address, Trace}

  setup do
    Trace.start()
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
      task =
        Task.async(fn ->
          Trace.subscribe()
          assert_receive {:mob_trace, _, :tap, nil}, 200
          :got_it
        end)

      Trace.subscribe()
      Process.sleep(20)

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
  end

  describe "unsubscribe/0" do
    test "removes the subscriber" do
      Trace.subscribe()
      Trace.unsubscribe()

      :ok = Event.dispatch(self(), addr(), :tap, nil)

      refute_receive {:mob_trace, _, _, _}, 50
    end
  end

  describe "no-op when stopped" do
    test "broadcast is a no-op if Trace is stopped" do
      Trace.stop()

      # Should not raise.
      :ok = Trace.broadcast(addr(), :tap, nil)
      :ok = Event.dispatch(self(), addr(), :tap, nil)

      # Direct event still arrives:
      assert_receive {:mob_event, _, :tap, nil}
      # No trace:
      refute_receive {:mob_trace, _, _, _}, 50
    end
  end

  describe "dead subscriber cleanup" do
    test "broadcast removes dead pids from the table" do
      pid =
        spawn(fn ->
          Trace.subscribe()
          # Exit immediately
        end)

      Process.sleep(10)
      refute Process.alive?(pid)

      # Now dispatch — broadcast should silently skip the dead pid and clean up.
      :ok = Event.dispatch(self(), addr(), :tap, nil)
      Process.sleep(10)

      # Verify the dead pid was removed.
      assert :ets.lookup(:mob_event_trace, pid) == []
    end
  end
end
