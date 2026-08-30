defmodule Mob.Router do
  @moduledoc """
  Owns navigation, and the one process per live screen that serves it.

  Which stacks exist, which is active, and one `Mob.Screen.Server` per live
  screen — this process starts them, stops them, and restarts one that crashes.
  It keeps the `:mob_screen` registered name, so the native layer's
  `enif_whereis_pid` lookups (back gesture, alert actions, launch
  notifications) are unaffected.

  ## Not in the per-message path

  A screen handling an ordinary message never touches this process. Native
  events reach a screen directly: `Mob.Listener` unwraps the envelope and sends
  to the screen's own pid, the screen renders, and `Mob.Sender` commits. The
  router hears only about navigation.

  That is the property MOB-113 exists to guarantee, and it is what makes one
  process per screen affordable. An earlier costing of this design assumed a
  router in the loop and concluded per-screen processes could not escape a hop
  per message; splitting the router from the sender is what dissolved that.

  `Mob.Screen` delegates its public API here, so callers keep using
  `Mob.Screen.dispatch/3` and friends.

  ## A navigation entry

  `%{module:, pid:, params:, ref:}`.

  `params` is carried because a restart has to reproduce the screen exactly —
  one that mounts on `%{id: id}` cannot come back from `%{}`.

  `ref` identifies the screen to `Mob.Sender`, and is unique **per screen**,
  not per stack. Every screen is a live process that repaints on any message it
  receives, including the ones below the top of a stack; keyed by stack, a timer
  tick in a screen the user cannot see would commit its tree — tap table
  included — over the screen they can. The sender only commits the tree whose
  ref is active. The ref survives a restart, because the replacement is the same
  logical screen.

  See `decisions/2026-08-28-screen-processes-and-supervision.md`.
  """

  use GenServer

  require Logger

  # Stopping a screen must not block the owner forever on one that is wedged in
  # a long callback. GenServer.stop/3 otherwise waits :infinity.
  @stop_timeout_ms 5_000

  # A screen that mounts fine but crashes on every render otherwise loops at
  # full speed — measured at ~6500 restarts/sec, each writing a log line. An
  # OTP supervisor would cap this with max_restart_intensity; the owner restarts
  # screens itself (it is the only thing that knows where one sat), so it has to
  # carry the ceiling too.
  @max_restarts 5
  @restart_window_ms 10_000

  @doc """
  Start a screen process linked to the calling process.

  `params` is passed as the first argument to `mount/3`.
  """
  @spec start_link(module(), map(), keyword()) :: GenServer.on_start()
  def start_link(screen_module, params, opts \\ []) do
    {nif, opts} = Keyword.pop(opts, :nif, :mob_nif)
    GenServer.start_link(__MODULE__, {screen_module, params, :no_render, :android, nif}, opts)
  end

  @doc """
  Return the module of the currently active screen in the navigation stack.
  Intended for testing and debugging.
  """
  @spec get_current_module(pid()) :: module()
  def get_current_module(pid), do: GenServer.call(pid, :get_current_module)

  @doc """
  Return the navigation history (list of `{module, socket}` pairs, head = most recent).
  Intended for testing and debugging.
  """
  @spec get_nav_history(pid()) :: [{module(), Mob.Socket.t() | nil}]
  def get_nav_history(pid), do: GenServer.call(pid, :get_nav_history)

  @doc """
  Start a screen as the root UI screen. Calls mount, renders the component tree
  via `Mob.Renderer`, and calls `set_root` on the resulting view.

  This is the main entry point for production use. `start_link/2` is for tests
  (no NIF calls).
  """
  @spec start_root(module(), map(), keyword()) :: GenServer.on_start()
  def start_root(screen_module, params \\ %{}, opts \\ []) do
    {nif, opts} = Keyword.pop(opts, :nif, :mob_nif)
    platform = nif.platform()
    GenServer.start_link(__MODULE__, {screen_module, params, :render, platform, nif}, opts)
  end

  @doc """
  Dispatch a UI event to the screen process. Returns `:ok` synchronously once
  the event has been processed and the state updated.
  """
  @spec dispatch(pid(), String.t(), map()) :: :ok
  def dispatch(pid, event, params), do: GenServer.call(pid, {:event, event, params}, :infinity)

  @doc """
  Return the current socket state of a running screen, or `nil` while that
  screen is being restarted.

  Intended for testing and debugging — not for production app logic.
  """
  @spec get_socket(pid()) :: Mob.Socket.t() | nil
  def get_socket(pid), do: GenServer.call(pid, :get_socket)

  @doc """
  Return the pid of the process owning the currently active screen.

  Each live screen is its own process since MOB-112; this is how tooling
  reaches the one that is on screen.
  """
  @spec get_screen_pid(GenServer.server()) :: pid()
  def get_screen_pid(pid), do: GenServer.call(pid, :get_screen_pid)

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl GenServer
  def init({screen_module, params, render_mode, platform, nif}) do
    # Linked *and* trapping. Linking alone makes the owner die with any screen
    # it stops or that crashes; trapping alone orphans every screen when the
    # owner dies — and an orphaned persisted screen keeps dumping to
    # Mob.ScreenState under the same key as its live replacement. Together the
    # owner sees each exit as a message and screens still come down with it.
    Process.flag(:trap_exit, true)

    if render_mode == :render do
      Process.register(self(), :mob_screen)
      # Renders are casts, so a missing sender would blank the screen silently.
      Mob.Sender.ensure_started()
      # Started before the first render: that render is what bakes the
      # listener's pid into the native tap handles.
      Mob.Listener.ensure_started()
    end

    # Seed the stacks this app declared. The screen we are about to mount
    # becomes the active stack's current screen; every other declared stack
    # stays unmounted until first visited.
    nav = Mob.Nav.from_layout(Mob.Nav.Registry.layout(platform), screen_module)

    state = %{
      current: nil,
      nav: nav,
      render_mode: render_mode,
      platform: platform,
      nif: nif,
      screens: %{},
      restarts: %{}
    }

    case start_screen(screen_module, params, state) do
      {:ok, entry, state} ->
        state = make_current(state, entry, :none)

        if render_mode == :render do
          # A notification that launched the app from a killed state. Sent to
          # self so it arrives via handle_info after init returns, consistent
          # with foreground notification delivery.
          case nif.take_launch_notification() do
            :none -> :ok
            json -> send(self(), {:mob_launch_notification, json})
          end

          paint(entry, :none, state)
        end

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:event, event, params}, _from, state) do
    # The whole point of MOB-112: a crash in the user's handle_event must not
    # come back up this call and take the owner — and with it navigation and
    # every sibling screen — down. The exit that follows restarts the screen.
    case safe_call(fn -> Mob.Screen.Server.dispatch(state.current.pid, event, params) end) do
      {:ok, {:ok, nav_action}} -> {:reply, :ok, apply_nav_action(nav_action, state, :sync)}
      {:exit, _reason} -> {:reply, :ok, state}
    end
  end

  def handle_call({:navigate, nav_action}, _from, state) do
    {:reply, :ok, apply_nav_action(nav_action, state, :sync)}
  end

  def handle_call(:get_socket, _from, state) do
    {:reply, current_socket(state), state}
  end

  def handle_call(:get_screen_pid, _from, state) do
    {:reply, state.current.pid, state}
  end

  def handle_call(:get_current_module, _from, state) do
    {:reply, state.current.module, state}
  end

  def handle_call(:get_nav_history, _from, state) do
    {:reply, Enum.map(Mob.Nav.history(state.nav), &entry_with_socket/1), state}
  end

  def handle_call(:inspect, _from, state) do
    socket = current_socket(state)

    # The tree is built in the screen's own process. Calling render/1 here would
    # run user code in the owner, so a raise in it — reached by Mob.Test.tree/1,
    # i.e. the debugging path — would kill navigation and every screen.
    tree =
      case safe_call(fn -> Mob.Screen.Server.tree(state.current.pid) end) do
        {:ok, tree} -> tree
        {:exit, _reason} -> nil
      end

    info = %{
      screen: state.current.module,
      assigns: socket && socket.assigns,
      nav_history: Enum.map(Mob.Nav.history(state.nav), & &1.module),
      tree: tree
    }

    {:reply, info, state}
  end

  @impl GenServer
  def handle_cast(:__mob_hot_reload__, state) do
    # A broadcast, not one cast: every live screen has to repaint with the
    # newly loaded code, not just the one on screen.
    Enum.each(all_entries(state), &Mob.Screen.Server.hot_reload(&1.pid))
    {:noreply, state}
  end

  @impl GenServer
  # A screen's callback asked to navigate. Only the active screen may drive
  # navigation — a background screen's timer must not yank the stack out from
  # under whatever the user is looking at.
  def handle_info({:nav_action, action, from}, state) do
    if from == state.current.pid do
      {:noreply, apply_nav_action(action, state, :async)}
    else
      {:noreply, state}
    end
  end

  # A screen exited. Trapping turns this into a message rather than the owner's
  # death — the isolation MOB-112 exists to deliver. A pid we have already
  # dropped from `screens` was stopped deliberately, so its exit is expected.
  def handle_info({:EXIT, pid, reason}, state) do
    case Map.pop(state.screens, pid) do
      {nil, _screens} -> {:noreply, state}
      {entry, screens} -> {:noreply, restart_screen(entry, reason, %{state | screens: screens})}
    end
  end

  # A notification that launched the app from a killed state.
  def handle_info({:mob_launch_notification, json}, state) do
    # Decoded here rather than in the screen because the payload comes from
    # native, not from a screen. :json.decode/1 raises on malformed input, and
    # this runs in the owner — so a bad payload would take down every screen.
    notification =
      try do
        decode_notification_json(json)
      rescue
        error ->
          Logger.error(
            "[mob] launch notification could not be decoded: " <> Exception.message(error)
          )

          %{source: :local, data: %{}}
      end

    handle_info({:notification, notification}, state)
  end

  # System back gesture (Android hardware/swipe, iOS edge-pan). Handled here so
  # every screen gets back navigation without implementing anything. If a
  # WebView is present and has internal history, navigate within it first.
  def handle_info({:mob, :back}, state) do
    if state.render_mode == :render && state.nif.webview_can_go_back() do
      state.nif.webview_go_back()
      {:noreply, state}
    else
      case {Mob.Nav.history(state.nav), Mob.Nav.back_target(state.nav)} do
        {[_ | _], _} ->
          {:noreply, apply_nav_action({:pop}, state, :async)}

        # Nothing left to pop on a secondary stack: fall back to the first one
        # rather than exiting and discarding every parked stack.
        {[], {:switch, target}} ->
          {:noreply, apply_nav_action({:switch_tab, target}, state, :async)}

        {[], :exit} ->
          if state.render_mode == :render, do: state.nif.exit_app()
          {:noreply, state}
      end
    end
  end

  # Anything else addressed to :mob_screen — device events, notifications,
  # plugin messages — belongs to the screen the user is looking at.
  def handle_info(message, state) do
    send(state.current.pid, message)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    # Deliberately does NOT stop screens. They are linked and trap exits, so
    # each shuts down gracefully on its own — gen_server turns the parent's EXIT
    # into a terminate/2 call, which runs the user's terminate/2 and the final
    # state dump.
    #
    # Calling GenServer.stop/3 here instead corrupts the owner's own exit: the
    # screen's :shutdown travels back while the owner is mid-terminate and
    # replaces its reason, so a clean stop(owner, :normal) exits :shutdown.
    :ok
  end

  # ── Screen lifecycle ──────────────────────────────────────────────────────

  # Calling into a screen that is mid-crash must not propagate into the owner.
  # The exit signal that follows is what actually repairs the screen.
  defp safe_call(fun) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:exit, reason}
  end

  defp start_screen(module, params, state), do: start_screen(module, params, make_ref(), state)

  defp start_screen(module, params, ref, state) do
    opts = [
      module: module,
      params: params,
      ref: ref,
      owner: self(),
      render_mode: state.render_mode,
      platform: state.platform,
      nif: state.nif
    ]

    case Mob.Screen.Server.start_link(opts) do
      {:ok, pid} ->
        entry = %{module: module, pid: pid, params: params, ref: ref}
        {:ok, entry, %{state | screens: Map.put(state.screens, pid, entry)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The single place `current` changes. The sender is told here and nowhere
  # else, so only the screen the user is looking at can commit a frame.
  defp make_current(state, entry, transition) do
    Mob.Sender.activate(entry.ref, transition)
    %{state | current: entry}
  end

  defp all_entries(state) do
    parked =
      state.nav
      |> Map.get(:parked, %{})
      |> Enum.flat_map(fn {_name, %{current: current, history: history}} ->
        [current | history]
      end)

    ([state.current] ++ Mob.Nav.history(state.nav) ++ parked)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.pid)
  end

  defp current_socket(state) do
    case safe_call(fn -> Mob.Screen.Server.socket(state.current.pid) end) do
      {:ok, socket} -> socket
      {:exit, _reason} -> nil
    end
  end

  defp entry_with_socket(entry) do
    case safe_call(fn -> Mob.Screen.Server.socket(entry.pid) end) do
      {:ok, socket} -> {entry.module, socket}
      {:exit, _reason} -> {entry.module, nil}
    end
  end

  # A crashed screen is re-mounted in place, with the params and stack ref it
  # was created with. It loses its assigns — a restart runs mount/3 again —
  # which is the documented consequence of the isolation.
  defp restart_screen(entry, reason, state) do
    {allowed?, state} = record_restart(entry.ref, state)

    if allowed? do
      do_restart_screen(entry, reason, state)
    else
      Logger.error(
        "[mob] screen #{inspect(entry.module)} crashed #{@max_restarts + 1} times in " <>
          "#{@restart_window_ms}ms and is being given up on rather than restarted in a loop. " <>
          "Reason: #{inspect(reason)}"
      )

      recover_from_failed_restart(entry, state)
    end
  end

  # Sliding window per screen ref, so the ceiling follows a logical screen
  # across its restarts rather than resetting with each new pid.
  defp record_restart(ref, state) do
    now = System.monotonic_time(:millisecond)
    recent = Map.get(state.restarts, ref, []) |> Enum.filter(&(now - &1 < @restart_window_ms))
    state = %{state | restarts: Map.put(state.restarts, ref, [now | recent])}
    {length(recent) < @max_restarts, state}
  end

  defp do_restart_screen(%{pid: dead_pid} = entry, reason, state) do
    log_restart(entry.module, reason)

    case start_screen(entry.module, entry.params, entry.ref, state) do
      {:ok, new_entry, state} ->
        state = substitute(state, dead_pid, new_entry)
        if state.current.pid == new_entry.pid, do: paint(new_entry, :none, state)
        state

      {:error, mount_reason} ->
        # Re-mounting failed, so the screen cannot come back. Leaving the dead
        # entry in place would freeze the app silently — every later event
        # would call a corpse and return :ok. Pop to whatever is underneath if
        # there is anything; otherwise say so loudly rather than pretend.
        log_restart_failure(entry.module, mount_reason)
        recover_from_failed_restart(entry, state)
    end
  end

  defp substitute(state, dead_pid, new_entry) do
    replace = fn
      %{pid: ^dead_pid} -> new_entry
      other -> other
    end

    nav =
      state.nav
      |> Mob.Nav.put_history(Enum.map(Mob.Nav.history(state.nav), replace))
      |> Mob.Nav.map_parked(replace)

    current = if state.current.pid == dead_pid, do: new_entry, else: state.current
    %{state | nav: nav, current: current}
  end

  defp recover_from_failed_restart(%{pid: dead_pid} = entry, state) do
    cond do
      state.current.pid != dead_pid ->
        # A background screen. Drop it from the stack it sat in rather than
        # leave a corpse for a later pop or tab switch to restore.
        drop_entry(state, dead_pid)

      Mob.Nav.history(state.nav) != [] ->
        state = drop_entry(state, dead_pid)
        [previous | rest] = Mob.Nav.history(state.nav)
        state = make_current(%{state | nav: Mob.Nav.put_history(state.nav, rest)}, previous, :pop)
        paint(previous, :none, state)
        state

      true ->
        fall_back_to_parked_stack(entry, state)
    end
  end

  # "Nothing beneath it" is the *common* shape in a tab-bar app — every tab root
  # has an empty history — and there is usually a live screen parked under
  # another tab. Leaving a dead pid as `current` bricks the app: every later
  # event is safe_call'd into a corpse and replies :ok, while a perfectly good
  # screen sits parked one call away.
  defp fall_back_to_parked_stack(entry, state) do
    with [name | _] <- Mob.Nav.parked_stacks(state.nav),
         {:switched, nav, live} <- Mob.Nav.switch(state.nav, name, entry) do
      # switch/3 parks the dead entry under the outgoing stack; drop it straight
      # after, so nothing can restore a corpse by switching back.
      nav = Mob.Nav.drop_parked(nav, &(&1.pid == entry.pid))
      state = make_current(%{state | nav: nav}, live, :pop)
      paint(live, :none, state)
      state
    else
      _ ->
        Logger.error(
          "[mob] #{inspect(entry.module)} could not be restarted and there is no other live " <>
            "screen to fall back to. The app has no live screen."
        )

        state
    end
  end

  defp drop_entry(state, dead_pid) do
    dead? = fn %{pid: pid} -> pid == dead_pid end

    nav =
      state.nav
      |> Mob.Nav.put_history(Enum.reject(Mob.Nav.history(state.nav), dead?))
      |> Mob.Nav.drop_parked(dead?)

    %{state | nav: nav}
  end

  defp log_restart(module, reason) do
    Logger.error(
      "[mob] screen #{inspect(module)} crashed and is being restarted; its assigns are lost. " <>
        "Reason: #{inspect(reason)}"
    )
  end

  defp log_restart_failure(module, reason) do
    Logger.error(
      "[mob] screen #{inspect(module)} could not be restarted — mount/3 failed: " <>
        "#{inspect(reason)}"
    )
  end

  defp paint(entry, transition, state), do: do_paint(entry, transition, state, :async)

  defp do_paint(_entry, _transition, %{render_mode: :no_render}, _mode), do: :ok

  defp do_paint(entry, transition, _state, :sync) do
    # Unprotected, this is the other way a screen crash killed the owner: the
    # user's render/1 runs inside the screen, and a raise there exits this call.
    case safe_call(fn -> Mob.Screen.Server.render_sync(entry.pid, transition) end) do
      {:ok, _} -> :ok
      {:exit, _reason} -> :ok
    end
  end

  defp do_paint(entry, transition, _state, :async),
    do: Mob.Screen.Server.render(entry.pid, transition)

  # Drop the entry from tracking BEFORE stopping, so the exit we asked for is
  # recognised as deliberate rather than restarted as a crash.
  defp stop_screen(%{pid: pid} = entry, state) do
    # Forget the restart history too — the map is keyed by screen ref and
    # nothing else ever removes a key, so it grows for the owner's lifetime.
    state = %{
      state
      | screens: Map.delete(state.screens, pid),
        restarts: Map.delete(state.restarts, entry.ref)
    }

    stop_process(pid)
    state
  end

  defp stop_process(pid) do
    if Process.alive?(pid) do
      # Unlink first. We are discarding this screen deliberately, so its
      # :shutdown exit must not travel back up the link — during the owner's own
      # terminate/2 that signal overrides the owner's exit reason, which turns a
      # clean GenServer.stop(owner, :normal) into an exit with :shutdown.
      Process.unlink(pid)

      try do
        GenServer.stop(pid, :shutdown, @stop_timeout_ms)
      catch
        # A wedged screen ignores the shutdown request. GenServer.stop/3 kills
        # only its own proxy on timeout, so without this the screen survives —
        # unlinked, untracked, and still dumping to Mob.ScreenState under the
        # same key as its replacement. That is the orphan hazard linking exists
        # to prevent.
        :exit, _reason -> Process.exit(pid, :kill)
      end
    end

    :ok
  end

  # ── Navigation ────────────────────────────────────────────────────────────

  defp apply_nav_action(nil, state, _mode), do: state

  defp apply_nav_action({:push, dest, params}, state, mode) do
    with {:ok, new_module, route_params} <- safe_resolve(dest, state) do
      push_resolved(new_module, Map.merge(route_params, params), state, mode)
    end
  end

  defp apply_nav_action({:pop}, state, mode) do
    case Mob.Nav.history(state.nav) do
      [previous | rest] ->
        # The screen being popped off leaves the stack for good, so its process
        # goes with it. The ones still in `rest` stay resident — that is what
        # makes pop restore prior state without re-mounting.
        state = stop_screen(state.current, state)

        state =
          make_current(%{state | nav: Mob.Nav.put_history(state.nav, rest)}, previous, :pop)

        do_paint(previous, :none, state, mode)
        state

      [] ->
        repaint_current(state, mode)
    end
  end

  defp apply_nav_action({:pop_to_root}, state, mode) do
    case Enum.reverse(Mob.Nav.history(state.nav)) do
      [root | _] ->
        discarded = [
          state.current | Enum.reject(Mob.Nav.history(state.nav), &(&1.pid == root.pid))
        ]

        state = Enum.reduce(discarded, state, &stop_screen/2)
        state = make_current(%{state | nav: Mob.Nav.put_history(state.nav, [])}, root, :pop)
        do_paint(root, :none, state, mode)
        state

      [] ->
        repaint_current(state, mode)
    end
  end

  defp apply_nav_action({:pop_to, dest}, state, mode) do
    with {:ok, target, _params} <- safe_resolve(dest, state) do
      pop_to_resolved(target, state, mode)
    end
  end

  # The three-element form predates the transition option. It still arrives from
  # `Mob.Test.reset_to/3`, and from any socket built before a hot code push, so
  # it keeps working and means what it always did.
  defp apply_nav_action({:reset, dest, params}, state, mode) do
    apply_nav_action({:reset, dest, params, :reset}, state, mode)
  end

  defp apply_nav_action({:reset, dest, params, transition}, state, mode) do
    with {:ok, new_module, route_params} <- safe_resolve(dest, state) do
      reset_resolved(new_module, Map.merge(route_params, params), transition, state, mode)
    end
  end

  defp apply_nav_action({:switch_tab, tab}, state, mode) do
    case Mob.Nav.switch(state.nav, tab, state.current) do
      {:switched, nav, entry} ->
        state = make_current(%{state | nav: nav}, entry, :none)
        do_paint(entry, :none, state, mode)
        state

      {:mount_root, nav, root_module} ->
        # Start first, mutate after. Switching nav before the mount could fail
        # leaves navigation pointing at a stack whose screen never started.
        case start_screen(root_module, %{}, state) do
          {:ok, entry, state} ->
            state = make_current(%{state | nav: nav}, entry, :none)
            do_paint(entry, :none, state, mode)
            state

          {:error, _reason} ->
            repaint_current(state, mode)
        end

      :noop ->
        repaint_current(state, mode)
    end
  end

  # A shape this router does not know. Reachable during a hot code push, where
  # module loading is not atomic: a screen already running new code can hand an
  # action to a router still running old code. Unmatched, that is a
  # FunctionClauseError in the owner — navigation and every live screen down,
  # which is the failure safe_resolve/2 and safe_call/1 exist to prevent.
  # Repaint and carry on instead.
  defp apply_nav_action(action, state, mode) do
    Logger.error(
      "[mob] unrecognised navigation action #{inspect(action)} was ignored. " <>
        "If this followed a hot code push, restart the app to clear it."
    )

    repaint_current(state, mode)
  end

  defp push_resolved(new_module, mount_params, state, mode) do
    case start_screen(new_module, mount_params, state) do
      {:ok, entry, state} ->
        nav = Mob.Nav.put_history(state.nav, [state.current | Mob.Nav.history(state.nav)])
        state = make_current(%{state | nav: nav}, entry, :push)
        do_paint(entry, :none, state, mode)
        state

      {:error, _reason} ->
        repaint_current(state, mode)
    end
  end

  defp reset_resolved(new_module, mount_params, transition, state, mode) do
    case start_screen(new_module, mount_params, state) do
      {:ok, entry, state} ->
        discarded = [state.current | Mob.Nav.history(state.nav)]
        state = Enum.reduce(discarded, state, &stop_screen/2)

        state =
          make_current(%{state | nav: Mob.Nav.put_history(state.nav, [])}, entry, transition)

        do_paint(entry, :none, state, mode)
        state

      {:error, _reason} ->
        repaint_current(state, mode)
    end
  end

  defp pop_to_resolved(target, state, mode) do
    history = Mob.Nav.history(state.nav)

    case pop_to_module(history, target) do
      {:found, previous, rest} ->
        discarded = [state.current | Enum.take_while(history, &(&1.pid != previous.pid))]
        state = Enum.reduce(discarded, state, &stop_screen/2)

        state =
          make_current(%{state | nav: Mob.Nav.put_history(state.nav, rest)}, previous, :pop)

        do_paint(previous, :none, state, mode)
        state

      :not_found ->
        repaint_current(state, mode)
    end
  end

  # A nav action that changed nothing still has to paint. The screen deliberately
  # does not paint when it produced an action, so without this the assigns it set
  # in the same callback would never reach the screen — re-tapping the active tab
  # being the everyday case.
  defp repaint_current(state, mode) do
    do_paint(state.current, :none, state, mode)
    state
  end

  # `push_screen/2` and friends take any atom, and an unregistered one raises.
  # That raise runs in the OWNER, where it would kill navigation and every
  # screen — falsifying the isolation this module's moduledoc promises, over a
  # typo. A bad destination leaves navigation untouched and repaints instead.
  #
  # Returns the state unchanged (via repaint_current/2) rather than an error
  # tuple, so the `with` in each caller falls straight through.
  defp safe_resolve(dest, state) do
    {module, route_params} = resolve_destination(dest)
    {:ok, module, route_params}
  rescue
    error ->
      Logger.error(
        "[mob] navigation to #{inspect(dest)} failed and was ignored: " <>
          Exception.message(error)
      )

      repaint_current(state, :async)
  end

  # Resolves a navigation destination to {module, route_params}. A loaded
  # module navigates directly (no route-bound params); a registered route atom
  # may carry params (Mob.Nav.Registry.register/3 — the data-driven-plugin
  # pattern), merged UNDER the caller's push params at the mount call site.
  defp resolve_destination(dest) when is_atom(dest) do
    case Code.ensure_loaded(dest) do
      {:module, ^dest} ->
        {dest, %{}}

      _ ->
        case Mob.Nav.Registry.lookup_route(dest) do
          {:ok, module, route_params} ->
            {module, route_params}

          {:error, :not_found} ->
            raise ArgumentError,
                  "Mob.Router: unknown navigation destination #{inspect(dest)}. " <>
                    "Register it via Mob.Nav.Registry.register/2 or declare it in " <>
                    "your App.navigation/1."
        end
    end
  end

  defp pop_to_module([], _target), do: :not_found

  defp pop_to_module([%{module: module} = entry | rest], target) do
    if module == target do
      {:found, entry, rest}
    else
      pop_to_module(rest, target)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp decode_notification_json(json) when is_binary(json) do
    case :json.decode(json) do
      map when is_map(map) ->
        source =
          case Map.get(map, "source", "local") do
            "push" -> :push
            _ -> :local
          end

        data =
          case Map.get(map, "data") do
            d when is_map(d) -> Map.new(d, fn {k, v} -> {String.to_atom(k), v} end)
            _ -> %{}
          end

        %{
          id: Map.get(map, "id"),
          title: Map.get(map, "title"),
          body: Map.get(map, "body"),
          data: data,
          source: source
        }

      _ ->
        %{source: :local, data: %{}}
    end
  end
end
