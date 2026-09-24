defmodule Mob.KeyboardTest do
  # The NIF itself needs a device (same as Mob.Haptic / Mob.Clipboard). What
  # the host can check: dismiss/1 hands the socket back untouched even though
  # the NIF library never loads here — a screen chaining it must not crash on
  # the host. That the stub and both native tables agree on name and arity is
  # covered by nif_scheduling_completeness_test.exs, which reads the tables.
  use ExUnit.Case, async: true

  defmodule Screen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "hi"}, children: []}
  end

  test "dismiss/1 returns the socket unchanged off-device" do
    socket = Mob.Socket.new(Screen, platform: :no_render)
    assert Mob.Keyboard.dismiss(socket) == socket
  end
end
