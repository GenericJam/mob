defmodule Mob.ScreenCaseAsyncTest do
  use Mob.ScreenCase, async: true

  import ExUnit.CaptureLog

  defmodule ProfileScreen do
    use Mob.Screen

    def mount(params, _session, socket) do
      {:ok,
       socket
       |> Mob.Socket.assign(:profile, :loading)
       |> Mob.Socket.assign(:avatar, nil)
       |> Mob.Socket.start_async(:profile, params.load)}
    end

    def render(assigns),
      do: %{type: :text, props: %{text: inspect(assigns.profile)}, children: []}

    # Loading the avatar needs the profile first, so it starts from here.
    def handle_async(:profile, {:ok, profile}, socket) do
      {:noreply,
       socket
       |> Mob.Socket.assign(:profile, profile)
       |> Mob.Socket.start_async(:avatar, fn -> "#{profile}.png" end)}
    end

    def handle_async(:profile, {:exit, reason}, socket),
      do: {:noreply, Mob.Socket.assign(socket, :profile, {:failed, reason})}

    def handle_async(:avatar, {:ok, avatar}, socket),
      do: {:noreply, Mob.Socket.assign(socket, :avatar, avatar)}
  end

  test "render_async delivers results, including a task handle_async started" do
    view = mount_screen(ProfileScreen, %{load: fn -> "ada" end})
    assert assigns(view).profile == :loading

    view = render_async(view)

    assert assigns(view).profile == "ada"
    assert assigns(view).avatar == "ada.png"
  end

  test "a crashing task is reported to handle_async and does not take the test process down" do
    view = mount_screen(ProfileScreen, %{load: fn -> raise "api down" end})

    {view, _log} = with_log(fn -> render_async(view) end)

    assert {:failed, {%RuntimeError{message: "api down"}, _stacktrace}} = assigns(view).profile
  end

  test "a task killed through a link it made is reported, and the test process survives" do
    # The worker dies from the inner task's exit signal, not from a raise of
    # its own, so nothing inside it can catch the crash.
    load = fn -> Task.async(fn -> raise "inner down" end) |> Task.await() end
    view = mount_screen(ProfileScreen, %{load: load})

    {view, _log} = with_log(fn -> render_async(view) end)

    assert {:failed, {%RuntimeError{message: "inner down"}, _stacktrace}} = assigns(view).profile
  end

  test "render_async on one view leaves another view's results alone" do
    first = mount_screen(ProfileScreen, %{load: fn -> "first" end})
    second = mount_screen(ProfileScreen, %{load: fn -> "second" end})
    # Both results are in the mailbox before either view awaits.
    wait_for_messages(2)

    second = render_async(second)
    first = render_async(first)

    assert assigns(second).profile == "second"
    assert assigns(first).profile == "first"
  end

  test "render_async flunks when a task does not finish in time" do
    view =
      mount_screen(ProfileScreen, %{
        load: fn ->
          receive do
            :never -> :ok
          end
        end
      })

    assert_raise ExUnit.AssertionError, ~r/ProfileScreen still has start_async/, fn ->
      render_async(view, 50)
    end
  end

  defp wait_for_messages(count) do
    {:message_queue_len, queued} = Process.info(self(), :message_queue_len)

    if queued < count do
      Process.sleep(5)
      wait_for_messages(count)
    end
  end
end
