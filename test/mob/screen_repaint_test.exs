defmodule Mob.ScreenRepaintTest do
  @moduledoc """
  A message that changes nothing must not cross to native.

  `forward/2` used to repaint after every `handle_info`, whether or not the
  message changed anything. That is one full render — clear_taps, a register_tap
  per interactive node, serialisation, set_root, native tree rebuild — per
  inbound message, so a 30 Hz scroll handler drove 30 of them a second. It also
  fed a feedback loop, because each render's clear_taps zeroes the per-handle
  native throttle state: MOB-134 measured 68 vs 69 events for a throttled and an
  unthrottled handler delivered to a screen, against 33 vs 5 for the same
  handlers delivered to a plain process.

  Counted at the NIF rather than inferred, so it keeps holding when the render
  path is rearranged.
  """
  use ExUnit.Case, async: false

  @counts :screen_repaint_counts

  defmodule CountingNif do
    def platform, do: :android
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def take_launch_notification, do: :none
    def set_transition(_), do: :ok
    def register_tap(_), do: 0
    def clear_taps, do: bump(:clear_taps)
    def set_root(_json), do: bump(:set_root)

    defp bump(key) do
      :ets.update_counter(:screen_repaint_counts, key, 1, {key, 0})
      :ok
    end
  end

  defmodule Screen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :count, 0)}

    def render(assigns) do
      %{
        type: :text,
        props: %{text: "#{assigns.count}", text_color: Mob.Theme.current().background},
        children: []
      }
    end

    # Changes an assign — must repaint.
    def handle_info(:bump, socket),
      do: {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}

    # Changes nothing — must NOT repaint.
    def handle_info(:noop, socket), do: {:noreply, socket}

    # Assigns the SAME value — the socket is "touched" but the tree is identical.
    def handle_info(:reassign_same, socket),
      do: {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count)}

    # Changes something render/1 reads that is NOT in assigns. This is why the
    # check compares the rendered tree and not the assigns.
    def handle_info(:theme, socket) do
      Mob.Theme.set(Mob.Theme.Light)
      {:noreply, socket}
    end

    def handle_info(_msg, socket), do: {:noreply, socket}
  end

  setup do
    :ets.new(@counts, [:public, :named_table, :set])

    # Both must be RUNNING, not stopped: the render path reconciles components
    # and hands off to Mob.Sender, and set_root is only reached through Sender.
    started =
      for mod <- [Mob.ComponentRegistry, Mob.Sender], is_nil(Process.whereis(mod)) do
        {:ok, pid} = mod.start_link()
        pid
      end

    {:ok, router} = Mob.Router.start_root(Screen, %{}, nif: CountingNif)
    screen = Mob.Screen.get_screen_pid(router)

    on_exit(fn ->
      stop_safely(router)
      for pid <- started, do: stop_safely(pid)
      Mob.Theme.set(Mob.Theme.Dark)
    end)

    settle()
    %{screen: screen}
  end

  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # Mob.Sender.render is a cast, so the count lags the send. Wait for the
  # counter to stop moving rather than calling Mob.Sender.sync/1 — a sync that
  # exits (Sender restarted, or not the one this ref belongs to) is swallowed by
  # the catch and reads the counter too early, which turns every "must repaint"
  # assertion into a silent false failure. That happened while writing this.
  defp settle(tries \\ 20) do
    before = renders()
    Process.sleep(25)

    cond do
      tries == 0 -> :ok
      renders() != before -> settle(tries - 1)
      true -> :ok
    end
  end

  defp renders, do: :ets.lookup_element(@counts, :set_root, 2, 0)

  defp after_sending(screen, msg) do
    before = renders()
    send(screen, msg)
    settle()
    renders() - before
  end

  test "a message that changes nothing does not cross to native", %{screen: screen} do
    assert after_sending(screen, :noop) == 0
  end

  test "assigning the same value again does not cross to native", %{screen: screen} do
    # A dirty flag set by `assign/3` would repaint here — the socket was written
    # to, but the user sees nothing new. Comparing the rendered tree does not.
    assert after_sending(screen, :reassign_same) == 0
  end

  test "a message that changes the view does cross to native", %{screen: screen} do
    assert after_sending(screen, :bump) == 1
  end

  test "a change render/1 reads from outside assigns still repaints", %{screen: screen} do
    # The reason this compares the tree rather than the assigns. Mob.Theme.set/1
    # changes what render/1 produces without touching a single assign; an
    # assigns-based check would skip the repaint and leave the old theme on
    # screen.
    assert after_sending(screen, :theme) == 1
  end

  test "repeated no-op messages stay at zero", %{screen: screen} do
    before = renders()
    for _ <- 1..25, do: send(screen, :noop)
    settle()
    assert renders() - before == 0
  end

  test "a real change after no-ops still lands", %{screen: screen} do
    for _ <- 1..5, do: send(screen, :noop)
    settle()
    assert after_sending(screen, :bump) == 1
  end
end
