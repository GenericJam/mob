defmodule Mob.Agent.ReceiptsIntegrationTest do
  use ExUnit.Case, async: false

  alias Mob.Agent.{Receipt, Receipts}

  # MOB-155. The point of a receipt is that it is assembled from what the screen
  # observed, not from what a handler claimed. These drive a real screen through
  # `Mob.Screen.dispatch/3` and read the receipt back, so a handler that lies —
  # or a stage the framework forgets to record — shows up here.

  defmodule Screen do
    @moduledoc false
    use Mob.Screen

    def mount(_p, _s, socket),
      do: {:ok, Mob.Socket.assign(socket, %{count: 0, hidden: 0, password: "hunter2"})}

    # Changes an assign the tree renders — a visible effect.
    def handle_event("increment", _p, socket),
      do: {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}

    # Changes an assign render/1 never reads — the render-function case.
    def handle_event("bump_hidden", _p, socket),
      do: {:noreply, Mob.Socket.assign(socket, :hidden, socket.assigns.hidden + 1)}

    # Runs and decides nothing — the app-code case.
    def handle_event("noop", _p, socket), do: {:noreply, socket}

    def handle_event("boom", _p, _socket), do: raise("handler exploded")

    def handle_event("go", _p, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, Mob.Agent.ReceiptsIntegrationTest.Dest)}

    # Reads a key that is not there, so the raised KeyError embeds the whole
    # assigns map — the shape that leaked a secret before summarize_error/3.
    def handle_event("leak", _p, socket),
      do: {:noreply, Map.fetch!(socket.assigns, :no_such_key)}

    def render(assigns),
      do: %{type: :text, props: %{text: "count=#{assigns.count}"}, children: []}
  end

  defmodule Dest do
    @moduledoc false
    use Mob.Screen
    def mount(_p, _s, socket), do: {:ok, socket}
    def render(_a), do: %{type: :text, props: %{text: "dest"}, children: []}
  end

  # A screen with no handle_event/3 of its own, so `use Mob.Screen`'s injected
  # catch-all survives — the real "stale tag / renamed event" shape.
  defmodule NoHandlers do
    @moduledoc false
    use Mob.Screen
    def mount(_p, _s, socket), do: {:ok, socket}
    def render(_a), do: %{type: :text, props: %{text: "x"}, children: []}
  end

  defmodule Nif do
    @moduledoc false
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def platform, do: :ios
    def take_launch_notification, do: :none
    def unquote(:"$handle_undefined_function")(_f, _a), do: :ok
  end

  setup do
    Receipts.reset()
    {:ok, pid} = Mob.Router.start_root(Screen, %{}, nif: Nif)

    on_exit(fn ->
      # `start_root/3` brings up Mob.Sender and Mob.Listener under global names,
      # and leaving the Listener behind silently changes what the renderer does
      # in every later file: `Mob.Listener.handler/1` wraps a tap tag into
      # `{:mob_route, ...}` only when a listener is running, so Mob.RendererTest
      # fails asserting on the unwrapped tag it registered — naming a file that
      # has never heard of this one.
      Mob.Test.ProcessHelpers.stop_root(pid)
    end)

    %{pid: pid}
  end

  defp dispatch_and_fetch(pid, event) do
    Mob.Screen.dispatch(pid, event, %{})
    [receipt] = Receipts.recent(1)
    receipt
  end

  test "an event that changes what is rendered is verified", %{pid: pid} do
    receipt = dispatch_and_fetch(pid, "increment")

    assert Receipt.effect(receipt) == :verified
    assert Receipt.owner(receipt) == :none
    assert Receipt.reached?(receipt, :committed)

    assert Receipt.reached?(receipt, :frame_changed),
           "the stage the whole attribution turns on must be produced by a real dispatch"

    assert receipt.before_frame_fingerprint != receipt.after_frame_fingerprint
    assert receipt.handler == {Screen, :handle_event, 3}
    assert receipt.event == "increment"
    assert Receipt.reached?(receipt, :assigns_changed)
  end

  test "an assign the render function ignores is attributed to it", %{pid: pid} do
    # This is the case a boolean cannot express and the one that saves the most
    # time: the handler ran, the state changed, and nothing appeared on screen.
    receipt = dispatch_and_fetch(pid, "bump_hidden")

    assert Receipt.effect(receipt) == :no_visible_change
    assert Receipt.owner(receipt) == :render_function
    assert Receipt.reached?(receipt, :assigns_changed)
    refute Receipt.reached?(receipt, :frame_changed)
  end

  test "a handler that changes nothing is inert, and blames the app", %{pid: pid} do
    receipt = dispatch_and_fetch(pid, "noop")

    assert Receipt.effect(receipt) == :inert
    assert Receipt.owner(receipt) == :app_code
    refute Receipt.reached?(receipt, :assigns_changed)
  end

  test "an unmatched event is unhandled, not inert", %{pid: pid} do
    # This screen defines its own handle_event/3 clauses, which override the
    # catch-all `use Mob.Screen` injects — so an unmatched event arrives as a
    # FunctionClauseError. Lumping that in with "the handler crashed" would send
    # someone to read a handler body that was never entered; it is a routing
    # problem — a stale tag, a renamed event.
    receipt = dispatch_and_fetch(pid, "no_such_event")

    assert Receipt.effect(receipt) == :unhandled
    assert Receipt.owner(receipt) == :event_routing

    # No handler is named: there is no clause to send anyone to read.
    assert receipt.handler == nil
    refute Receipt.reached?(receipt, :committed)
  end

  test "a raising handler is still recorded, on the way out", %{pid: pid} do
    # The screen dies here, so the receipt has to be written before the
    # exception propagates. Losing it would mean the crash a defect report most
    # wants to explain is the one action with no receipt.
    #
    # The exit does not reach this test: Mob.Router wraps the dispatch in
    # safe_call/1, so it absorbs the screen's crash. That is exactly why the
    # receipt matters — from the outside, a handler that exploded and a handler
    # that did nothing look the same.
    Process.flag(:trap_exit, true)
    Mob.Screen.dispatch(pid, "boom", %{})

    [receipt] = Receipts.recent(1)

    assert Receipt.effect(receipt) == :error
    assert Receipt.owner(receipt) == :app_code
    # No message: a RuntimeError's message is app-authored and routinely
    # interpolates state. The module and the frame are enough to route it.
    assert %{kind: :error, exception: RuntimeError, message: nil, redaction: :applied} =
             receipt.error

    assert {Screen, :handle_event, 3} = receipt.error.at
    assert receipt.event == "boom"
  end

  test "each dispatch gets its own id, so two actions cannot be confused", %{pid: pid} do
    # The reason receipts exist: the old effect detector waited on a
    # process-wide counter, so a second action inside the window was
    # indistinguishable from the first one landing.
    Mob.Screen.dispatch(pid, "increment", %{})
    Mob.Screen.dispatch(pid, "noop", %{})

    [newest, older] = Receipts.recent(2)

    assert newest.action_id != older.action_id
    assert {newest.event, older.event} == {"noop", "increment"}
    assert Receipt.effect(older) == :verified
    assert Receipt.effect(newest) == :inert
  end

  test "a handler that navigates is not reported as inert", %{pid: pid} do
    # The headline case. This screen deliberately does not paint for a
    # navigation — the owner applies the action and the destination paints — so
    # deriving the verdict from the absence of a paint reports a screen push,
    # the commonest successful action in a mobile app, as "the handler did
    # nothing". That is the same lie as the process-wide counter, inverted.
    receipt = dispatch_and_fetch(pid, "go")

    assert Receipt.effect(receipt) == :navigation_requested

    # :unknown, not :none — the router may refuse the request (a pop at the
    # root, a push that fails to resolve) and this screen cannot see that.
    assert Receipt.owner(receipt) == :unknown
    assert Receipt.reached?(receipt, :navigation_requested)
    refute Receipt.effect(receipt) == :inert
  end

  test "a screen with no handle_event clauses is routing, not a crash", %{pid: running} do
    # The setup's router owns the global :mob_screen name; stop it first.
    Mob.Test.ProcessHelpers.stop_pid(running)

    # `use Mob.Screen` injects a catch-all that raises, so this does NOT arrive
    # as a FunctionClauseError. Filing it as :app_code sends the reader to a
    # handler body that was never written.
    Receipts.reset()
    Process.flag(:trap_exit, true)
    {:ok, pid} = Mob.Router.start_root(NoHandlers, %{}, nif: Nif)

    on_exit(fn ->
      Mob.Test.ProcessHelpers.stop_root(pid)
    end)

    Mob.Screen.dispatch(pid, "anything", %{})
    [receipt] = Receipts.recent(1)

    assert Receipt.effect(receipt) == :unhandled
    assert Receipt.owner(receipt) == :event_routing
  end

  test "a crash never carries assigns into the receipt", %{pid: pid} do
    # KeyError embeds the map it was searching, so the unsummarised exception
    # put the entire assigns — secrets included — into ETS and into telemetry
    # metadata. That is MOB-147's leak, re-created by the mitigation that cites
    # it, and it reaches a sink unredacted.
    Process.flag(:trap_exit, true)
    Mob.Screen.dispatch(pid, "leak", %{})
    [receipt] = Receipts.recent(1)

    assert receipt.error.exception == KeyError

    refute inspect(receipt) =~ "hunter2",
           "the receipt carried a value out of assigns"
  end

  test "a :no_render screen reports unobservable, not a false render_function owner" do
    # `do_paint/5`'s :no_render clause never touches :last_frame, so no frame
    # stage can be reached. Falling through to :no_visible_change blames a
    # render function that is not running — and render_mode DEFAULTS to
    # :no_render, so every screen started outside Mob.Router.start_root/3 would
    # report it for every action.
    {:ok, pid} = Mob.Screen.start_link(Screen, %{}, nif: Nif)
    on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(pid) end)

    Mob.Screen.dispatch(pid, "increment", %{})
    [receipt] = Receipts.recent(1)

    assert Receipt.effect(receipt) == :unobservable
    assert Receipt.owner(receipt) == :unknown
    assert Receipt.reached?(receipt, :assigns_changed)
  end

  test "a receipt is retrievable by its id", %{pid: pid} do
    receipt = dispatch_and_fetch(pid, "increment")

    assert {:ok, ^receipt} = Receipts.fetch(receipt.action_id)
    assert Receipts.fetch("never-issued") == :error
  end

  test "elapsed_us is recorded", %{pid: pid} do
    # Not a benchmark — just that the field is populated, since a receipt whose
    # timing is always nil is a field nobody can use.
    receipt = dispatch_and_fetch(pid, "increment")
    assert is_integer(receipt.elapsed_us) and receipt.elapsed_us >= 0
  end
end
