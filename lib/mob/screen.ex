defmodule Mob.Screen do
  @moduledoc """
  Behaviour and GenServer wrapper for a Mob screen.

  Each live screen runs in its own `Mob.Screen.Server` process holding a
  `Mob.Socket`. This module is their **owner**: it holds the navigation state,
  starts and stops screens, and restarts one that crashes.

  That gives you isolation — a buggy `handle_event` crashes its own screen and
  the owner restarts it without taking down navigation, sibling screens,
  background services, or the BEAM. The owner is not an OTP `Supervisor`; it
  restarts screens itself because only it knows where in the navigation a
  crashed screen sat (see
  `decisions/2026-08-28-screen-processes-and-supervision.md`). A restarted
  screen re-mounts and loses its assigns.

  Lifecycle callbacks (`mount`, `render`, `handle_event`, `handle_info`,
  `terminate`) map directly to the GenServer lifecycle, so the BEAM's existing
  tools (selective receive, monitors, hot code push) work on screens without
  any Mob-specific scaffolding.

  ## Usage

      defmodule MyApp.CounterScreen do
        use Mob.Screen

        def mount(_params, _session, socket) do
          {:ok, Mob.Socket.assign(socket, :count, 0)}
        end

        def render(assigns) do
          %{
            type: :column,
            props: %{},
            children: [
              %{type: :text, props: %{text: "Count: \#{assigns.count}"}, children: []}
            ]
          }
        end

        def handle_event("increment", _params, socket) do
          {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}
        end
      end

  ## Starting a screen

      {:ok, pid} = Mob.Screen.start_link(MyApp.CounterScreen, %{})

  ## Dispatching events

      :ok = Mob.Screen.dispatch(pid, "increment", %{})
  """

  @type socket :: Mob.Socket.t()

  @callback mount(params :: map(), session :: map(), socket :: socket()) ::
              {:ok, socket()} | {:error, term()}

  @callback render(assigns :: map()) :: map()

  @callback handle_event(event :: String.t(), params :: map(), socket :: socket()) ::
              {:noreply, socket()} | {:reply, map(), socket()}

  @callback handle_info(message :: term(), socket :: socket()) ::
              {:noreply, socket()}

  @callback terminate(reason :: term(), socket :: socket()) :: term()

  @doc """
  Serialise assigns for persistence. Return a plain map of the keys you want
  restored on next launch. Defaults to the full assigns map minus any
  non-serialisable values (PIDs, references, ports, functions).

  Only called when `use Mob.Screen, vsn: N` (N > 0) or `persist: true`.
  """
  @callback dump_state(assigns :: map()) :: map()

  @doc """
  Reconstruct assigns from a previously persisted map.

  `stored_vsn` is the version that was current when the data was saved.
  Match on it to migrate old shapes:

      def load_state(1, stored), do: stored
      def load_state(0, stored), do: Map.put(stored, :new_field, :default)

  The returned map is merged into the socket's assigns after `mount/3` runs.
  Only called when stored data exists.
  """
  @callback load_state(stored_vsn :: non_neg_integer(), stored :: map()) :: map()

  @doc """
  Return a stable string key for storing this screen's state.

  Implement when the same screen module holds per-user or parameterised state:

      def screen_key(assigns), do: "\#{__MODULE__}:\#{assigns.user_id}"

  Defaults to the module name string.
  """
  @callback screen_key(assigns :: map()) :: String.t()

  @optional_callbacks [handle_event: 3, handle_info: 2, terminate: 2, screen_key: 1]

  defmacro __using__(opts) do
    vsn = Keyword.get(opts, :vsn, 0)
    persist = Keyword.get(opts, :persist, vsn > 0)

    quote do
      @behaviour Mob.Screen
      import Mob.Sigil

      def __mob_vsn__, do: unquote(vsn)
      def __mob_persist__, do: unquote(persist)

      def dump_state(assigns), do: assigns
      def load_state(_vsn, stored), do: stored

      def handle_info(_message, socket), do: {:noreply, socket}
      def terminate(_reason, _socket), do: :ok

      def handle_event(event, _params, _socket) do
        raise "unhandled event #{inspect(event)} in #{inspect(__MODULE__)}. " <>
                "Add a handle_event/3 clause to handle it."
      end

      @before_compile Mob.Screen
      defoverridable dump_state: 1, load_state: 2, handle_info: 2, terminate: 2, handle_event: 3
    end
  end

  defmacro __before_compile__(env) do
    template = Path.rootname(env.file) <> ".mob.heex"

    cond do
      Module.defines?(env.module, {:render, 1}) ->
        quote(do: :ok)

      File.exists?(template) ->
        source =
          template
          |> File.read!()
          |> String.split("\n")
          |> Enum.map_join("\n", &("    " <> &1))

        render_ast =
          Code.string_to_quoted!("""
          def render(assigns) do
            import Mob.Sigil

            ~MOB\"\"\"
          #{source}
            \"\"\"
          end
          """)

        quote do
          @external_resource unquote(template)
          unquote(render_ast)
        end

      true ->
        quote(do: :ok)
    end
  end

  # ── Owner process ─────────────────────────────────────────────────────────
  #
  # This process owns navigation: which stacks exist, which is active, and one
  # `Mob.Screen.Server` process per live screen. It keeps the `:mob_screen`
  # registered name, so the native layer's `enif_whereis_pid` lookups (back
  # gesture, alert actions, launch notifications) are unaffected.
  #
  # A navigation entry is `%{module:, pid:, params:, ref:}`. The params and ref
  # are carried because a restart has to reproduce the screen exactly: a screen
  # that mounts on `%{id: id}` cannot come back from `%{}`, and a screen parked
  # under an inactive stack must keep that stack's render ref or its next
  # repaint would commit over the foreground tab.
  #
  # MOB-113 extracts this role into `Mob.Router`.

  use GenServer

  require Logger

  # Stopping a screen must not block the owner forever on one that is wedged in
  # a long callback. GenServer.stop/3 otherwise waits :infinity.
  @stop_timeout_ms 5_000

  @doc """
  Start a screen process linked to the calling process.

  `params` is passed as the first argument to `mount/3`.
  """
  @spec start_link(module(), map(), keyword()) :: GenServer.on_start()
  def start_link(screen_module, params, opts \\ []) do
    GenServer.start_link(__MODULE__, {screen_module, params, :no_render, :android}, opts)
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
    platform = :mob_nif.platform()
    GenServer.start_link(__MODULE__, {screen_module, params, :render, platform}, opts)
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
  @spec get_socket(pid()) :: socket() | nil
  def get_socket(pid), do: GenServer.call(pid, :get_socket)

  @doc """
  Return the pid of the process owning the currently active screen.

  Each live screen is its own process since MOB-112; this is how tooling
  reaches the one that is on screen.
  """
  @spec get_screen_pid(pid()) :: pid()
  def get_screen_pid(pid), do: GenServer.call(pid, :get_screen_pid)

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl GenServer
  def init({screen_module, params, render_mode, platform}) do
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
    ref = Mob.Nav.active_ref(nav)
    Mob.Sender.set_active(ref)

    state = %{
      current: nil,
      nav: nav,
      render_mode: render_mode,
      platform: platform,
      screens: %{}
    }

    case start_screen(screen_module, params, ref, state) do
      {:ok, entry, state} ->
        if render_mode == :render do
          # A notification that launched the app from a killed state. Sent to
          # self so it arrives via handle_info after init returns, consistent
          # with foreground notification delivery.
          case :mob_nif.take_launch_notification() do
            :none -> :ok
            json -> send(self(), {:mob_launch_notification, json})
          end

          paint(entry, :none, state)
        end

        {:ok, %{state | current: entry}}

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
    module = state.current.module
    socket = current_socket(state)

    info = %{
      screen: module,
      assigns: socket && socket.assigns,
      nav_history: Enum.map(Mob.Nav.history(state.nav), & &1.module),
      tree: socket && module.render(socket.assigns)
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
    handle_info({:notification, decode_notification_json(json)}, state)
  end

  # System back gesture (Android hardware/swipe, iOS edge-pan). Handled here so
  # every screen gets back navigation without implementing anything. If a
  # WebView is present and has internal history, navigate within it first.
  def handle_info({:mob, :back}, state) do
    if state.render_mode == :render && :mob_nif.webview_can_go_back() do
      :mob_nif.webview_go_back()
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
          if state.render_mode == :render, do: :mob_nif.exit_app()
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

  defp start_screen(module, params, ref, state) do
    opts = [
      module: module,
      params: params,
      ref: ref,
      owner: self(),
      render_mode: state.render_mode,
      platform: state.platform
    ]

    case Mob.Screen.Server.start_link(opts) do
      {:ok, pid} ->
        entry = %{module: module, pid: pid, params: params, ref: ref}
        {:ok, entry, %{state | screens: Map.put(state.screens, pid, entry)}}

      {:error, reason} ->
        {:error, reason}
    end
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
  defp restart_screen(%{pid: dead_pid} = entry, reason, state) do
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
        state = %{state | nav: Mob.Nav.put_history(state.nav, rest), current: previous}
        paint(previous, :pop, state)
        state

      true ->
        Logger.error(
          "[mob] #{inspect(entry.module)} could not be restarted and there is no screen " <>
            "beneath it. The app has no live screen."
        )

        state
    end
  end

  defp drop_entry(state, dead_pid) do
    keep = fn %{pid: pid} -> pid != dead_pid end

    nav =
      state.nav
      |> Mob.Nav.put_history(Enum.filter(Mob.Nav.history(state.nav), keep))
      |> Mob.Nav.map_parked(& &1)

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
  defp stop_screen(%{pid: pid}, state) do
    state = %{state | screens: Map.delete(state.screens, pid)}
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
      GenServer.stop(pid, :shutdown, @stop_timeout_ms)
    end
  catch
    :exit, _reason -> :ok
  end

  # ── Navigation ────────────────────────────────────────────────────────────

  defp apply_nav_action(nil, state, _mode), do: state

  defp apply_nav_action({:push, dest, params}, state, mode) do
    {new_module, route_params} = resolve_destination(dest)
    ref = Mob.Nav.active_ref(state.nav)
    mount_params = Map.merge(route_params, params)

    case start_screen(new_module, mount_params, ref, state) do
      {:ok, entry, state} ->
        nav = Mob.Nav.put_history(state.nav, [state.current | Mob.Nav.history(state.nav)])
        state = %{state | nav: nav, current: entry}
        do_paint(entry, :push, state, mode)
        state

      {:error, _reason} ->
        repaint_current(state, mode)
    end
  end

  defp apply_nav_action({:pop}, state, mode) do
    case Mob.Nav.history(state.nav) do
      [previous | rest] ->
        # The screen being popped off leaves the stack for good, so its process
        # goes with it. The ones still in `rest` stay resident — that is what
        # makes pop restore prior state without re-mounting.
        state = stop_screen(state.current, state)
        state = %{state | nav: Mob.Nav.put_history(state.nav, rest), current: previous}
        do_paint(previous, :pop, state, mode)
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
        state = %{state | nav: Mob.Nav.put_history(state.nav, []), current: root}
        do_paint(root, :pop, state, mode)
        state

      [] ->
        repaint_current(state, mode)
    end
  end

  defp apply_nav_action({:pop_to, dest}, state, mode) do
    target = resolve_module(dest)
    history = Mob.Nav.history(state.nav)

    case pop_to_module(history, target) do
      {:found, previous, rest} ->
        discarded = [state.current | Enum.take_while(history, &(&1.pid != previous.pid))]
        state = Enum.reduce(discarded, state, &stop_screen/2)
        state = %{state | nav: Mob.Nav.put_history(state.nav, rest), current: previous}
        do_paint(previous, :pop, state, mode)
        state

      :not_found ->
        repaint_current(state, mode)
    end
  end

  defp apply_nav_action({:reset, dest, params}, state, mode) do
    {new_module, route_params} = resolve_destination(dest)
    ref = Mob.Nav.active_ref(state.nav)
    mount_params = Map.merge(route_params, params)

    case start_screen(new_module, mount_params, ref, state) do
      {:ok, entry, state} ->
        discarded = [state.current | Mob.Nav.history(state.nav)]
        state = Enum.reduce(discarded, state, &stop_screen/2)
        state = %{state | nav: Mob.Nav.put_history(state.nav, []), current: entry}
        do_paint(entry, :reset, state, mode)
        state

      {:error, _reason} ->
        repaint_current(state, mode)
    end
  end

  defp apply_nav_action({:switch_tab, tab}, state, mode) do
    case Mob.Nav.switch(state.nav, tab, state.current) do
      {:switched, nav, entry} ->
        # The restored screen already carries the ref of the stack it was
        # parked under, which is the one becoming active.
        Mob.Sender.set_active(Mob.Nav.active_ref(nav))
        state = %{state | nav: nav, current: entry}
        do_paint(entry, :none, state, mode)
        state

      {:mount_root, nav, root_module} ->
        # Start first, mutate after. Switching nav and the sender's active ref
        # before the mount could fail leaves the sender addressing a stack whose
        # screen never started, and every frame the live screen produces is then
        # dropped — a silent freeze.
        ref = Mob.Nav.active_ref(nav)

        case start_screen(root_module, %{}, ref, state) do
          {:ok, entry, state} ->
            Mob.Sender.set_active(ref)
            state = %{state | nav: nav, current: entry}
            do_paint(entry, :none, state, mode)
            state

          {:error, _reason} ->
            repaint_current(state, mode)
        end

      :noop ->
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

  defp resolve_module(dest) when is_atom(dest) do
    {module, _route_params} = resolve_destination(dest)
    module
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
                  "Mob.Screen: unknown navigation destination #{inspect(dest)}. " <>
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

  @doc false
  # Public only so Mob.Screen.Server can reuse it — the decoding belongs with
  # the rest of the native-event translation, not duplicated per process.
  @spec decode_file_result(String.t(), String.t(), binary()) :: tuple()
  def decode_file_result(event, sub, json_binary) do
    event_atom = String.to_atom(event)
    sub_atom = String.to_atom(sub)

    items =
      case :json.decode(json_binary) do
        list when is_list(list) ->
          Enum.map(list, fn item when is_map(item) ->
            Map.new(item, fn {k, v} -> {String.to_atom(k), v} end)
          end)

        _ ->
          []
      end

    case {event_atom, sub_atom} do
      {:camera, :photo} ->
        {:camera, :photo, List.first(items) || %{}}

      {:camera, :video} ->
        {:camera, :video, List.first(items) || %{}}

      {:camera, :cancelled} ->
        {:camera, :cancelled}

      {:photos, :picked} ->
        {:photos, :picked, items}

      {:files, :picked} ->
        {:files, :picked, items}

      {:audio, :recorded} ->
        {:audio, :recorded, List.first(items) || %{}}

      {:storage, :saved_to_library} ->
        {:storage, :saved_to_library, (List.first(items) || %{})[:path]}

      {:scan, :result} ->
        scan_result(List.first(items) || %{})

      _ ->
        {event_atom, sub_atom, items}
    end
  end

  defp scan_result(item) do
    {:scan, :result, %{type: to_atom_safe(item[:type]), value: item[:value]}}
  end

  defp to_atom_safe(nil), do: :qr
  defp to_atom_safe(s) when is_binary(s), do: String.to_atom(s)
  defp to_atom_safe(a) when is_atom(a), do: a

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
