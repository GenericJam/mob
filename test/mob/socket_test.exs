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
end
