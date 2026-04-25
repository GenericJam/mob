defmodule Mob.LiveViewTest do
  use ExUnit.Case, async: true

  # ── use Mob.LiveView macro ────────────────────────────────────────────────

  # A LiveView module that uses the macro but defines no handle_event clauses.
  defmodule BareView do
    use Mob.LiveView
  end

  # A LiveView module that defines its own clause — verifies the catch-all
  # does not shadow user-defined handlers.
  defmodule HandlingView do
    use Mob.LiveView

    def handle_event("mob_message", %{"type" => "ping"}, socket) do
      {:noreply, Map.put(socket, :handled, true)}
    end
  end

  describe "use Mob.LiveView" do
    test "provides a default handle_event that returns {:noreply, socket}" do
      socket = %{}
      assert {:noreply, ^socket} = BareView.handle_event("mob_message", %{}, socket)
    end

    test "default catch-all accepts any payload" do
      socket = %{}

      assert {:noreply, ^socket} =
               BareView.handle_event("mob_message", %{"anything" => true}, socket)
    end

    test "user-defined clause handles its pattern" do
      socket = %{}
      {:noreply, result} = HandlingView.handle_event("mob_message", %{"type" => "ping"}, socket)
      assert result.handled == true
    end

    test "defining handle_event replaces the catch-all — unmatched patterns raise" do
      # defoverridable means the user's definition replaces the injected catch-all
      # entirely. If you define handle_event/3, add your own catch-all for events
      # you don't handle — exactly as you would in any LiveView.
      socket = %{}

      assert_raise FunctionClauseError, fn ->
        HandlingView.handle_event("mob_message", %{"type" => "unknown"}, socket)
      end
    end
  end

  # ── local_url/1 ───────────────────────────────────────────────────────────

  describe "local_url/1" do
    setup do
      # Preserve any existing env value and restore after each test
      original = Application.get_env(:mob, :liveview_port)

      on_exit(fn ->
        if original do
          Application.put_env(:mob, :liveview_port, original)
        else
          Application.delete_env(:mob, :liveview_port)
        end
      end)

      :ok
    end

    test "defaults to port 4000" do
      Application.delete_env(:mob, :liveview_port)
      assert Mob.LiveView.local_url("/") == "http://127.0.0.1:4000/"
    end

    test "uses configured port" do
      Application.put_env(:mob, :liveview_port, 4001)
      assert Mob.LiveView.local_url("/") == "http://127.0.0.1:4001/"
    end

    test "appends path" do
      Application.delete_env(:mob, :liveview_port)
      assert Mob.LiveView.local_url("/dashboard") == "http://127.0.0.1:4000/dashboard"
    end

    test "defaults path to /" do
      Application.delete_env(:mob, :liveview_port)
      assert Mob.LiveView.local_url() == "http://127.0.0.1:4000/"
    end

    test "always uses 127.0.0.1 loopback" do
      url = Mob.LiveView.local_url("/any")
      assert String.starts_with?(url, "http://127.0.0.1:")
    end

    test "port 8080 example" do
      Application.put_env(:mob, :liveview_port, 8080)
      assert Mob.LiveView.local_url("/settings") == "http://127.0.0.1:8080/settings"
    end
  end
end
