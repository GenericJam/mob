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
        props: %{text: "#{assigns.count}", text_color: :on_background},
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

    # Capture the theme that was actually in force. Restoring Mob.Theme.Dark
    # instead would INSTALL a theme nobody set — Mob.Theme.default/0 is
    # %Mob.Theme{}, not Dark — and later tests in the same run would then
    # resolve colours against it.
    theme_before = Mob.Theme.current()

    {:ok, router} = Mob.Router.start_root(Screen, %{}, nif: CountingNif)
    screen = Mob.Screen.get_screen_pid(router)

    on_exit(fn ->
      stop_safely(router)
      for pid <- started, do: stop_safely(pid)
      # Mob.Router.start_root starts Mob.Listener when render_mode is :render,
      # globally named and unlinked. Leaving it running makes Mob.Renderer route
      # every later tap through it, so other files see {listener_pid, {:mob_route,
      # ...}} where they assert {pid, tag}. Two renderer_test cases failed that
      # way, and only when the files happened to run in the wrong order.
      if pid = Process.whereis(Mob.Listener), do: stop_safely(pid)
      Mob.Theme.set(theme_before)
    end)

    settle(screen)
    %{screen: screen}
  end

  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # Deterministic, not timing-based.
  #
  # A poll that waits for the counter to stop moving returns immediately on the
  # "must not repaint" tests — the counter never moves — so it never confirms
  # the screen even processed the message. Those assertions would then be
  # satisfied by "nothing has happened yet", which is the flake direction that
  # silently stops testing anything.
  #
  # Instead: a call to the screen proves it handled the message and issued its
  # render cast (calls are ordered behind the send), and a call to the sender
  # proves the cast was processed.
  defp settle(screen) do
    _ = Mob.Screen.Server.socket(screen)
    Mob.Sender.sync(:infinity)
    :ok
  end

  defp renders, do: :ets.lookup_element(@counts, :set_root, 2, 0)

  defp after_sending(screen, msg) do
    before = renders()
    send(screen, msg)
    settle(screen)
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
    settle(screen)
    assert renders() - before == 0
  end

  test "a real change after no-ops still lands", %{screen: screen} do
    for _ <- 1..5, do: send(screen, :noop)
    settle(screen)
    assert after_sending(screen, :bump) == 1
  end

  test "an explicit render request always paints, even with an unchanged tree", %{screen: screen} do
    # The router paints with `transition: :none` on every push, pop and reset —
    # the transition rides on the activation, not the paint — and the activation
    # token is conditional on activation_frame_supported?/0, the hot-code-push
    # fallback. So neither is a reliable "this is a navigation" signal, and a pop
    # back to a resident screen whose tree has not changed must not be skipped:
    # the user would tap back and keep looking at the screen they left.
    #
    # Only forward/2 may skip. This pins that.
    before = renders()
    Mob.Screen.Server.render(screen, :none)
    settle(screen)
    assert renders() - before == 1
  end

  test "a sync render always paints", %{screen: screen} do
    # A :sync caller is waiting on a flush; skipping would return before the
    # frame it is waiting for exists.
    before = renders()
    Mob.Screen.Server.render_sync(screen, :none)
    settle(screen)
    assert renders() - before == 1
  end

  test "the theme is part of the comparison, not just the tree", %{screen: screen} do
    # Belt and braces alongside the :theme message test above. The fixture uses
    # `text_color: :on_background` — a TOKEN — because token resolution happens
    # in Mob.Renderer, downstream of the comparison. An earlier version of this
    # file baked `Mob.Theme.current().background` into the tree instead, which
    # made the theme test pass against an implementation that ignored the theme
    # entirely. That is the one shape real screens do not use.
    assert File.read!(__ENV__.file) =~ "text_color: :on_background"
  end
end
