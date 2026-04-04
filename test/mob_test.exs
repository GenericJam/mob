defmodule MobTest do
  use ExUnit.Case, async: true

  test "assign/3 convenience delegate works" do
    socket = Mob.Socket.new(SomeScreen)
    socket = Mob.assign(socket, :count, 42)
    assert socket.assigns.count == 42
  end

  test "assign/2 convenience delegate works" do
    socket = Mob.Socket.new(SomeScreen)
    socket = Mob.assign(socket, count: 1, name: "mob")
    assert socket.assigns.count == 1
    assert socket.assigns.name == "mob"
  end
end
