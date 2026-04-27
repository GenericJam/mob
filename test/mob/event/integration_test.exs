defmodule Mob.Event.IntegrationTest do
  @moduledoc """
  End-to-end tests that exercise the event flow:

  1. A "screen" process subscribes / has handle_info
  2. Legacy event arrives (the shape the NIF currently sends)
  3. Bridge converts it
  4. Handler receives canonical envelope and reacts

  These tests don't touch the NIF — they synthesize legacy messages directly,
  which is exactly what the iOS/Android native code does via `enif_send`.
  """

  use ExUnit.Case, async: true

  alias Mob.Event
  alias Mob.Event.{Address, Bridge}

  # A simple "screen" GenServer that uses the bridge in handle_info.
  defmodule TestScreen do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, opts)

    def get_log(pid), do: GenServer.call(pid, :get_log)

    def init(opts) do
      {:ok, %{log: [], reply_to: opts[:reply_to]}}
    end

    def handle_info(msg, state) do
      case Bridge.legacy_to_canonical(msg, __MODULE__) do
        {:ok, {:mob_event, addr, event, payload} = envelope} ->
          # User-level handler that reacts to canonical events.
          if state.reply_to, do: send(state.reply_to, {:handled, envelope})

          new_log = [{addr.widget, addr.id, event, payload} | state.log]
          {:noreply, %{state | log: new_log}}

        :passthrough ->
          # Not a recognised legacy shape — just ignore for this test.
          {:noreply, state}
      end
    end

    def handle_call(:get_log, _from, state) do
      {:reply, Enum.reverse(state.log), state}
    end
  end

  describe "full bridge flow — tap" do
    test "atom-tagged tap arrives as canonical event" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      # This is what `mob_nif` sends on iOS/Android via enif_send.
      send(screen, {:tap, :save})

      assert_receive {:handled, envelope}, 200
      assert {:mob_event, %Address{widget: :button, id: :save}, :tap, nil} = envelope
    end

    test "binary-tagged tap arrives as canonical event" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:tap, "contact:42"})

      assert_receive {:handled, {:mob_event, %Address{id: "contact:42"}, :tap, nil}}, 200
    end
  end

  describe "full bridge flow — list row select" do
    test "structured list-row tap converts to :select event with instance" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:tap, {:list, :contacts, :select, 47}})

      assert_receive {:handled, envelope}, 200

      assert {:mob_event,
              %Address{
                widget: :list,
                id: :contacts,
                instance: 47
              }, :select, nil} = envelope
    end
  end

  describe "full bridge flow — change" do
    test "text_field change with binary value" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:change, :email, "user@example.com"})

      assert_receive {:handled, envelope}, 200

      assert {:mob_event,
              %Address{widget: :text_field, id: :email},
              :change,
              "user@example.com"} = envelope
    end

    test "toggle change with boolean" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:change, :notifications, true})

      assert_receive {:handled, {:mob_event, %Address{id: :notifications}, :change, true}}, 200
    end

    test "slider change with float" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:change, :volume, 0.75})

      assert_receive {:handled, {:mob_event, %Address{id: :volume}, :change, 0.75}}, 200
    end
  end

  describe "full bridge flow — multiple events accumulate in screen state" do
    test "log captures every event in order" do
      {:ok, screen} = TestScreen.start_link([])

      send(screen, {:tap, :start})
      send(screen, {:change, :email, "a@b"})
      send(screen, {:tap, {:list, :items, :select, 0}})
      send(screen, {:tap, :stop})

      Process.sleep(20)
      log = TestScreen.get_log(screen)

      assert log == [
               {:button, :start, :tap, nil},
               {:text_field, :email, :change, "a@b"},
               {:list, :items, :select, nil},
               {:button, :stop, :tap, nil}
             ]
    end

    test "passthrough events don't pollute the log" do
      {:ok, screen} = TestScreen.start_link([])

      send(screen, {:tap, :a})
      send(screen, {:not_an_event, :ignored})
      send(screen, {:tap, :b})

      Process.sleep(20)
      log = TestScreen.get_log(screen)

      # Only the two recognised taps:
      assert log == [
               {:button, :a, :tap, nil},
               {:button, :b, :tap, nil}
             ]
    end
  end

  describe "Batch 5 Tier 1: scroll/drag/pinch through bridge" do
    test "scroll event with payload arrives canonical" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:scroll, :main_list,
                    %{x: 0.0, y: 240.0, dx: 0.0, dy: 8.0, phase: :dragging,
                      velocity_x: 0.0, velocity_y: 480.0, ts: 12345, seq: 1}})

      assert_receive {:handled, envelope}, 200

      assert {:mob_event, %Address{widget: :scroll, id: :main_list},
              :scroll, %{y: 240.0, dy: 8.0, phase: :dragging}} = envelope
    end

    test "drag with payload" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:drag, :map, %{x: 50.0, y: 80.0, dx: 5.0, dy: 0.0, phase: :began}})

      assert_receive {:handled, {:mob_event, %Address{widget: :drag, id: :map}, :drag, _}}, 200
    end

    test "pinch with payload" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:pinch, :photo, %{scale: 1.5, velocity: 0.4, phase: :dragging}})

      assert_receive {:handled, {:mob_event, _, :pinch, %{scale: 1.5}}}, 200
    end

    test "scroll-stream — many events arrive in order" do
      {:ok, screen} = TestScreen.start_link([])

      for i <- 1..10 do
        send(screen, {:scroll, :feed, %{x: 0.0, y: i * 10.0, dx: 0.0, dy: 10.0, phase: :dragging, seq: i}})
      end

      Process.sleep(20)
      log = TestScreen.get_log(screen)

      seqs =
        log
        |> Enum.map(fn {_widget, _id, :scroll, %{seq: seq}} -> seq end)

      assert seqs == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    end
  end

  describe "Batch 5 Tier 2: semantic scroll events through bridge" do
    test "scroll_began → scroll_ended → scroll_settled" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:scroll_began, :main})
      send(screen, {:scroll_ended, :main})
      send(screen, {:scroll_settled, :main})

      assert_receive {:handled, {:mob_event, _, :scroll_began, nil}}, 200
      assert_receive {:handled, {:mob_event, _, :scroll_ended, nil}}, 200
      assert_receive {:handled, {:mob_event, _, :scroll_settled, nil}}, 200
    end

    test "top_reached and scrolled_past land as semantic events" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:top_reached, :main})
      send(screen, {:scrolled_past, :crossed_100})

      assert_receive {:handled, {:mob_event, %Address{id: :main}, :top_reached, nil}}, 200
      assert_receive {:handled, {:mob_event, %Address{id: :crossed_100}, :scrolled_past, nil}}, 200
    end
  end

  describe "IME composition flow (Batch 6 — text input only)" do
    test "began → updating → committed sequence" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:compose, :email, %{phase: :began, text: "n"}})
      send(screen, {:compose, :email, %{phase: :updating, text: "ni"}})
      send(screen, {:compose, :email, %{phase: :committed, text: "你"}})

      assert_receive {:handled, {:mob_event, _, :compose, %{phase: :began, text: "n"}}}, 200

      assert_receive {:handled, {:mob_event, _, :compose, %{phase: :updating, text: "ni"}}},
                     200

      assert_receive {:handled, {:mob_event, _, :compose, %{phase: :committed, text: "你"}}},
                     200
    end

    test "began → cancelled (user dismissed IME)" do
      {:ok, screen} = TestScreen.start_link(reply_to: self())

      send(screen, {:compose, :email, %{phase: :began, text: ""}})
      send(screen, {:compose, :email, %{phase: :cancelled, text: ""}})

      assert_receive {:handled, {:mob_event, _, :compose, %{phase: :began}}}, 200
      assert_receive {:handled, {:mob_event, _, :compose, %{phase: :cancelled}}}, 200
    end

    test "screen can implement commit-only filter using on_change + on_compose" do
      defmodule CommitOnlyScreen do
        use GenServer

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts, opts)

        def get(pid), do: GenServer.call(pid, :get)

        def init(opts) do
          {:ok, %{committed: nil, composing: false, raw: nil, reply_to: opts[:reply_to]}}
        end

        def handle_info({:compose, _id, %{phase: :began}}, state) do
          {:noreply, %{state | composing: true}}
        end

        def handle_info({:compose, _id, %{phase: :committed, text: text}}, state) do
          # Real commit replaces whatever raw text we've been seeing.
          send(state.reply_to, {:committed, text})
          {:noreply, %{state | composing: false, committed: text, raw: text}}
        end

        def handle_info({:compose, _id, %{phase: :cancelled}}, state) do
          {:noreply, %{state | composing: false}}
        end

        def handle_info({:compose, _id, %{phase: :updating, text: text}}, state) do
          {:noreply, %{state | raw: text}}
        end

        def handle_info({:change, _id, value}, %{composing: true} = state) do
          # Ignore raw text changes while composing — wait for commit.
          {:noreply, %{state | raw: value}}
        end

        def handle_info({:change, _id, value}, state) do
          send(state.reply_to, {:committed, value})
          {:noreply, %{state | committed: value}}
        end

        def handle_call(:get, _from, state), do: {:reply, state, state}
      end

      {:ok, screen} = CommitOnlyScreen.start_link(reply_to: self())

      # Simulate CJK input flow: keystrokes during composition + final commit.
      send(screen, {:compose, :email, %{phase: :began, text: "n"}})
      send(screen, {:change, :email, "n"})
      send(screen, {:compose, :email, %{phase: :updating, text: "ni"}})
      send(screen, {:change, :email, "ni"})
      send(screen, {:compose, :email, %{phase: :committed, text: "你"}})

      # Should receive ONE :committed message — for "你", not "n" or "ni".
      assert_receive {:committed, "你"}, 200
      refute_receive {:committed, "n"}, 50
      refute_receive {:committed, "ni"}, 50

      state = CommitOnlyScreen.get(screen)
      assert state.committed == "你"
      assert state.composing == false
    end
  end

  describe "Mob.Event direct dispatch (no bridge)" do
    test "synthesised event delivered to the test process" do
      addr = Address.new(screen: TestScreen, widget: :button, id: :save)
      :ok = Event.dispatch(self(), addr, :tap, nil)
      assert_receive {:mob_event, ^addr, :tap, nil}
    end

    test "match_address? filters correctly" do
      addr = Address.new(screen: TestScreen, widget: :button, id: :save)
      assert Event.match_address?(addr, widget: :button)
      refute Event.match_address?(addr, widget: :text_field)
    end
  end
end
