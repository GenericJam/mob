defmodule Mob.Agent.ReceiptTest do
  use ExUnit.Case, async: true

  alias Mob.Agent.Receipt

  defp receipt(stages, opts \\ []) do
    %Receipt{
      action_id: "a1",
      stages: stages,
      error: Keyword.get(opts, :error)
    }
  end

  describe "owner/1 — which layer is answerable" do
    # The table in the moduledoc is the contract. Each row is a distinct place
    # to look, and getting the mapping wrong sends someone to the wrong file.

    test "no handler ran — the event never reached a clause" do
      assert Receipt.owner(receipt([:dispatched])) == :event_routing
    end

    test "handler ran and changed nothing — the application decided not to" do
      assert Receipt.owner(receipt([:dispatched, :handled])) == :app_code
    end

    test "assigns changed but the frame did not — render/1 ignores them" do
      assert Receipt.owner(receipt([:dispatched, :handled, :assigns_changed])) ==
               :render_function
    end

    test "a frame was built and never handed over — the renderer or the bridge" do
      assert Receipt.owner(receipt([:dispatched, :handled, :assigns_changed, :frame_changed])) ==
               :renderer
    end

    test "a committed changed frame has no owner to answer for it" do
      full = [:dispatched, :handled, :assigns_changed, :frame_changed, :committed]
      assert Receipt.owner(receipt(full)) == :none
    end

    test "an unchanged frame that was committed still blames the render function" do
      # A paint happened and handed a frame over, but it was the same frame.
      # `:committed` alone must not read as success, or every no-op repaint
      # would report as a verified effect.
      committed_same = [:dispatched, :handled, :assigns_changed, :committed]
      assert Receipt.owner(receipt(committed_same)) == :render_function
      assert Receipt.effect(receipt(committed_same)) == :no_visible_change
    end

    test "a raised handler is the application's, however far the action got" do
      # Without this clause the stage list would blame whatever layer came next,
      # which is how a crash in app code gets filed against the framework.
      full = [:dispatched, :handled, :assigns_changed, :frame_changed, :committed]
      assert Receipt.owner(receipt(full, error: {:error, %RuntimeError{}})) == :app_code
      assert Receipt.owner(receipt([:dispatched], error: {:error, %RuntimeError{}})) == :app_code
    end
  end

  describe "effect/1 — the verdict an agent asked for" do
    test "a changed frame that was committed is verified" do
      full = [:dispatched, :handled, :assigns_changed, :frame_changed, :committed]
      assert Receipt.effect(receipt(full)) == :verified
    end

    test "a navigation is its own verdict, not inert" do
      # The commonest successful action in a mobile app. This screen does not
      # paint for it — the destination does — so deriving the verdict from the
      # absence of a paint reports a screen push as "the handler did nothing".
      nav = [:dispatched, :handled, :assigns_changed, :navigated]
      assert Receipt.effect(receipt(nav)) == :navigated
      assert Receipt.owner(receipt(nav)) == :none
    end

    test "a frame built but never handed over is not_committed" do
      built = [:dispatched, :handled, :assigns_changed, :frame_changed]
      assert Receipt.effect(receipt(built)) == :not_committed
    end

    test "assigns changed but no new tree is not an error" do
      # A handler that updates state this screen does not render has done what
      # it was asked. Calling that a failure produces false alarms.
      assert Receipt.effect(receipt([:dispatched, :handled, :assigns_changed])) ==
               :no_visible_change
    end

    test "handler ran and changed nothing is inert" do
      assert Receipt.effect(receipt([:dispatched, :handled])) == :inert
    end

    test "no handler is unhandled, not inert" do
      # The distinction is the whole point: :inert means the app chose to do
      # nothing, :unhandled means the event never arrived anywhere.
      assert Receipt.effect(receipt([:dispatched])) == :unhandled
    end

    test "a raise is reported as an error rather than as its stages" do
      assert Receipt.effect(receipt([:dispatched, :handled], error: {:error, :boom})) == :error
    end
  end

  describe "new_action_id/0" do
    test "is unique across calls" do
      ids = for _ <- 1..1_000, do: Receipt.new_action_id()
      assert length(Enum.uniq(ids)) == 1_000
    end
  end

  describe "reached?/2 and describe/1" do
    test "reached?/2 reports stage membership" do
      r = receipt([:dispatched, :handled])
      assert Receipt.reached?(r, :handled)
      refute Receipt.reached?(r, :committed)
    end

    test "describe/1 names the effect and the owner in one line" do
      line =
        %Receipt{
          action_id: "abc",
          event: "increment",
          handler: {My.Screen, :handle_event, 3},
          stages: [:dispatched, :handled],
          elapsed_us: 42
        }
        |> Receipt.describe()

      assert line =~ "abc"
      assert line =~ "increment"
      assert line =~ "My.Screen.handle_event/3"
      assert line =~ "inert"
      assert line =~ "app_code"
    end
  end
end
