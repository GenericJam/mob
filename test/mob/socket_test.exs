defmodule Mob.SocketTest do
  use ExUnit.Case, async: true

  alias Mob.Socket

  describe "new/1" do
    test "creates socket with empty assigns" do
      socket = Socket.new(MyScreen)
      assert socket.assigns == %{}
    end

    test "stores the screen module" do
      socket = Socket.new(MyScreen)
      assert socket.__mob__.screen == MyScreen
    end

    test "defaults platform to :android" do
      socket = Socket.new(MyScreen)
      assert socket.__mob__.platform == :android
    end

    test "accepts platform option" do
      socket = Socket.new(MyScreen, platform: :ios)
      assert socket.__mob__.platform == :ios
    end
  end

  describe "assign/3 — single key/value" do
    test "adds a new assign" do
      socket = Socket.new(MyScreen) |> Socket.assign(:count, 0)
      assert socket.assigns.count == 0
    end

    test "overwrites existing assign" do
      socket = Socket.new(MyScreen) |> Socket.assign(:count, 0) |> Socket.assign(:count, 5)
      assert socket.assigns.count == 5
    end

    test "preserves other assigns" do
      socket =
        Socket.new(MyScreen)
        |> Socket.assign(:a, 1)
        |> Socket.assign(:b, 2)
        |> Socket.assign(:a, 99)

      assert socket.assigns.b == 2
      assert socket.assigns.a == 99
    end
  end

  describe "update/3" do
    test "applies the function to the current value" do
      socket =
        Socket.new(MyScreen) |> Socket.assign(:count, 1) |> Socket.update(:count, &(&1 + 1))

      assert socket.assigns.count == 2
    end

    test "raises if the key is not assigned" do
      assert_raise KeyError, fn ->
        Socket.new(MyScreen) |> Socket.update(:missing, &(&1 + 1))
      end
    end

    test "leaves other assigns untouched" do
      socket =
        Socket.new(MyScreen)
        |> Socket.assign(a: 1, b: 2)
        |> Socket.update(:a, &(&1 * 10))

      assert socket.assigns.a == 10
      assert socket.assigns.b == 2
    end
  end

  describe "assign_new/3" do
    test "assigns and runs the fun when the key is absent" do
      socket = Socket.new(MyScreen) |> Socket.assign_new(:user, fn -> "computed" end)
      assert socket.assigns.user == "computed"
    end

    test "keeps the existing value and does not run the fun" do
      socket =
        Socket.new(MyScreen)
        |> Socket.assign(:user, "existing")
        |> Socket.assign_new(:user, fn -> raise "assign_new ran when key was present" end)

      assert socket.assigns.user == "existing"
    end
  end

  describe "assign/2 — keyword list" do
    test "sets multiple assigns at once" do
      socket = Socket.new(MyScreen) |> Socket.assign(count: 0, name: "test")
      assert socket.assigns.count == 0
      assert socket.assigns.name == "test"
    end

    test "merges with existing assigns" do
      socket =
        Socket.new(MyScreen)
        |> Socket.assign(:existing, true)
        |> Socket.assign(count: 1, name: "hi")

      assert socket.assigns.existing == true
      assert socket.assigns.count == 1
    end

    test "accepts a plain map" do
      socket = Socket.new(MyScreen) |> Socket.assign(%{x: 10, y: 20})
      assert socket.assigns.x == 10
      assert socket.assigns.y == 20
    end
  end

  describe "assign/2 — does not mutate __mob__" do
    test "assign does not touch __mob__ metadata" do
      socket = Socket.new(MyScreen)
      original_mob = socket.__mob__
      socket = Socket.assign(socket, :foo, :bar)
      assert socket.__mob__ == original_mob
    end
  end

  describe "put_root_view/2" do
    test "stores the root view ref" do
      socket = Socket.new(MyScreen) |> Socket.put_root_view(:some_ref)
      assert socket.__mob__.root_view == :some_ref
    end
  end

  describe "reset_to/4" do
    test "keeps the reset transition by default" do
      socket = Socket.new(MyScreen) |> Socket.reset_to(OtherScreen, %{source: :login})

      assert socket.__mob__.nav_action ==
               {:reset, OtherScreen, %{source: :login}, :reset}
    end

    test "accepts a directional transition without changing the reset action" do
      socket =
        Socket.new(MyScreen)
        |> Socket.reset_to(OtherScreen, %{tab: :portfolio}, transition: :push)

      assert socket.__mob__.nav_action ==
               {:reset, OtherScreen, %{tab: :portfolio}, :push}
    end

    test "rejects a transition the platform cannot render" do
      # set_transition/1 accepts any atom and the platform falls back to no
      # animation for one it does not recognise, so an unchecked typo would
      # silently produce the wrong motion with nothing to point at.
      assert_raise ArgumentError, ~r/invalid transition :puhs/, fn ->
        Socket.new(MyScreen) |> Socket.reset_to(OtherScreen, %{}, transition: :puhs)
      end
    end

    test "accepts the directional transitions and the default" do
      for t <- [:push, :pop, :reset] do
        socket = Socket.new(MyScreen) |> Socket.reset_to(OtherScreen, %{}, transition: t)
        assert {:reset, OtherScreen, %{}, ^t} = socket.__mob__.nav_action
      end
    end

    test "emits an all-stack reset only when explicitly requested" do
      socket =
        Socket.new(MyScreen)
        |> Socket.reset_to(OtherScreen, %{source: :logout}, scope: :all)

      assert socket.__mob__.nav_action ==
               {:reset, OtherScreen, %{source: :logout}, :reset, :all}
    end

    test "combines all-stack scope with a directional transition" do
      socket =
        Socket.new(MyScreen)
        |> Socket.reset_to(OtherScreen, %{}, transition: :pop, scope: :all)

      assert socket.__mob__.nav_action == {:reset, OtherScreen, %{}, :pop, :all}
    end

    test "keeps the established action shape for explicit stack scope" do
      socket = Socket.new(MyScreen) |> Socket.reset_to(OtherScreen, %{}, scope: :stack)
      assert socket.__mob__.nav_action == {:reset, OtherScreen, %{}, :reset}
    end

    test "rejects an unknown reset scope" do
      assert_raise ArgumentError, ~r/invalid scope :tabs/, fn ->
        Socket.new(MyScreen) |> Socket.reset_to(OtherScreen, %{}, scope: :tabs)
      end
    end

    test "rejects :none, which would replace the stack without telling the platform" do
      # :none suppresses the navigation-version bump, so SwiftUI diffs the
      # incoming tree into the outgoing screen's view identities — a TextField
      # at the same position keeps the old screen's text and focus across a
      # stack that no longer exists.
      assert_raise ArgumentError, ~r/invalid transition :none/, fn ->
        Socket.new(MyScreen) |> Socket.reset_to(OtherScreen, %{}, transition: :none)
      end
    end
  end

  describe "switch_tab/3" do
    test "keeps the legacy action shape when no transition is requested" do
      socket = Socket.new(MyScreen) |> Socket.switch_tab(:settings)
      assert socket.__mob__.nav_action == {:switch_tab, :settings}

      socket = Socket.new(MyScreen) |> Socket.switch_tab(:settings, [])
      assert socket.__mob__.nav_action == {:switch_tab, :settings}
    end

    test "stores a validated directional transition" do
      for transition <- [:push, :pop, :reset] do
        socket = Socket.new(MyScreen) |> Socket.switch_tab(:settings, transition: transition)
        assert socket.__mob__.nav_action == {:switch_tab, :settings, transition}
      end
    end

    test "stores mount params with the default or an explicit transition" do
      socket = Socket.new(MyScreen) |> Socket.switch_tab(:settings, mount_params: %{user_id: 7})

      assert socket.__mob__.nav_action ==
               {:switch_tab, :settings, :none, %{user_id: 7}}

      socket =
        Socket.new(MyScreen)
        |> Socket.switch_tab(:settings, transition: :push, mount_params: %{user_id: 7})

      assert socket.__mob__.nav_action ==
               {:switch_tab, :settings, :push, %{user_id: 7}}
    end

    test "rejects non-map mount params" do
      assert_raise ArgumentError, ~r/invalid mount_params \[user_id: 7\]/, fn ->
        Socket.new(MyScreen) |> Socket.switch_tab(:settings, mount_params: [user_id: 7])
      end
    end

    test "rejects an invalid transition" do
      assert_raise ArgumentError, ~r/Mob.Socket.switch_tab\/3: invalid transition :puhs/, fn ->
        Socket.new(MyScreen) |> Socket.switch_tab(:settings, transition: :puhs)
      end
    end

    test "rejects an explicit :none transition" do
      assert_raise ArgumentError, ~r/invalid transition :none/, fn ->
        Socket.new(MyScreen) |> Socket.switch_tab(:settings, transition: :none)
      end
    end
  end
end
