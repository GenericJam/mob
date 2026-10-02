defmodule Mob.ScreenCaseSizeClassTest do
  # MOB-204. A screen that lays out by `assigns.size_class` must be testable
  # in-BEAM in every class, and see a change exactly as it would on device.
  use Mob.ScreenCase, async: true

  defmodule Screen do
    @moduledoc false
    use Mob.Screen

    # Reads the assign in mount, which only works if it is set before mount.
    def mount(_p, _s, socket),
      do: {:ok, Mob.Socket.assign(socket, :mounted_as, socket.assigns.size_class)}

    def handle_info({:mob_size_class_changed, new}, socket),
      do: {:noreply, Mob.Socket.assign(socket, :told, new)}

    def handle_info(_other, socket), do: {:noreply, socket}

    def render(assigns) do
      case assigns.size_class do
        {:regular, _} -> %{type: :row, props: %{id: "two_pane"}, children: []}
        {:compact, _} -> %{type: :column, props: %{id: "one_pane"}, children: []}
      end
    end
  end

  defmodule NoClauseScreen do
    @moduledoc false
    use Mob.Screen

    def mount(_p, _s, socket), do: {:ok, socket}
    def handle_info(:only_this, socket), do: {:noreply, socket}
    def render(_assigns), do: %{type: :column, props: %{}, children: []}
  end

  test "mount_screen gives the socket a portrait-phone size class by default" do
    view = mount_screen(Screen)

    assert assigns(view).size_class == {:compact, :regular}
    assert assigns(view).mounted_as == {:compact, :regular}
    assert find(view, :column, id: "one_pane")
  end

  test "mount_screen takes the size class to mount in" do
    view = mount_screen(Screen, %{}, %{}, size_class: {:regular, :regular})

    assert assigns(view).mounted_as == {:regular, :regular}
    assert find(view, :row, id: "two_pane")
  end

  test "mount_screen rejects a malformed size class" do
    assert_raise ArgumentError, fn -> mount_screen(Screen, %{}, %{}, size_class: :regular) end
  end

  test "change_size_class updates the assign and tells the screen" do
    view = Screen |> mount_screen() |> change_size_class({:regular, :compact})

    assert assigns(view).size_class == {:regular, :compact}
    assert assigns(view).told == {:regular, :compact}
    assert find(view, :row, id: "two_pane")
  end

  test "change_size_class to the value already held does not tell the screen" do
    view = Screen |> mount_screen() |> change_size_class({:compact, :regular})

    refute Map.has_key?(assigns(view), :told)
  end

  test "change_size_class on a screen with no clause for it keeps the new value" do
    view = NoClauseScreen |> mount_screen() |> change_size_class({:regular, :regular})

    assert assigns(view).size_class == {:regular, :regular}
  end
end
