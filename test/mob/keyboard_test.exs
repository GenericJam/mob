defmodule Mob.KeyboardTest do
  # The NIF itself needs a device (same as Mob.Haptic / Mob.Clipboard). What
  # the host can check: dismiss/1 hands the socket back untouched even though
  # the NIF library never loads here — a screen chaining it must not crash on
  # the host. nif_declaration_test.exs checks both native tables against the
  # stub's -nifs list; nif_scheduling_completeness_test.exs classifies the iOS
  # entry as IO_BOUND.
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

  defmodule FakeNif do
    @moduledoc false
    # Stands in for :mob_nif: reports the call to the test that set itself up.
    def dismiss_keyboard do
      send(:persistent_term.get({__MODULE__, :test}), :dismiss_keyboard)
      :ok
    end
  end

  test "dismiss takes the keyboard down through the NIF and returns the socket" do
    :persistent_term.put({FakeNif, :test}, self())
    on_exit(fn -> :persistent_term.erase({FakeNif, :test}) end)
    socket = Mob.Socket.new(Screen, platform: :no_render)

    assert Mob.Keyboard.__dismiss__(socket, FakeNif) == socket
    assert_received :dismiss_keyboard
  end
end
