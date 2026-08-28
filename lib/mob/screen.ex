defmodule Mob.Screen do
  @moduledoc """
  Behaviour and GenServer wrapper for a Mob screen.

  Each screen runs as a supervised GenServer whose state is a `Mob.Socket`.
  Putting one process per screen — instead of one big process for the whole
  app — gives you isolation: a buggy `handle_event` crashes its own screen
  and the supervisor restarts it without taking down navigation, audio,
  background services, or the BEAM itself. Lifecycle callbacks (`mount`,
  `render`, `handle_event`, `handle_info`, `terminate`) map directly to the
  GenServer lifecycle, so the BEAM's existing concurrency tools (selective
  receive, monitors, hot code push) work on screens without any Mob-specific
  scaffolding.

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
  # Its state mirrors what it held before MOB-112 — `{module, socket, nav,
  # render_mode}` — with the socket replaced by the pid of the process that now
  # owns it. MOB-113 extracts this role into `Mob.Router`.

  use GenServer

  require Logger

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
  @spec get_nav_history(pid()) :: [{module(), Mob.Socket.t()}]
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
  def dispatch(pid, event, params), do: GenServer.call(pid, {:event, event, params})

  @doc """
  Return the current socket state of a running screen.
  Intended for testing and debugging — not for production app logic.
  """
  @spec get_socket(pid()) :: socket()
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
    # Registered under :mob_screen so the C layer's mob_handle_back() and the
    # launch-notification fallback find the owner. Only in :render mode;
    # tests use :no_render and run without a NIF.
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
    # stays unmounted until first visited. With no declaration (or no registry,
    # as in tests) this is an empty single-stack state.
    nav = Mob.Nav.from_layout(Mob.Nav.Registry.layout(platform), screen_module)
    ref = Mob.Nav.active_ref(nav)
    Mob.Sender.set_active(ref)

    state = %{
      current: nil,
      nav: nav,
      render_mode: render_mode,
      platform: platform,
      monitors: %{}
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
    {_module, pid} = state.current

    # The whole point of MOB-112: a crash in the user's handle_event must not
    # come back up this call and take the owner — and with it navigation and
    # every sibling screen — down. The :DOWN that follows restarts the screen.
    case safe_call(fn -> Mob.Screen.Server.dispatch(pid, event, params) end) do
      {:ok, {:ok, nav_action}} -> {:reply, :ok, apply_nav_action(nav_action, state, :sync)}
      {:exit, _reason} -> {:reply, :ok, state}
    end
  end

  def handle_call({:navigate, nav_action}, _from, state) do
    {:reply, :ok, apply_nav_action(nav_action, state, :sync)}
  end

  def handle_call(:get_socket, _from, state) do
    {_module, pid} = state.current

    case safe_call(fn -> Mob.Screen.Server.socket(pid) end) do
      {:ok, socket} -> {:reply, socket, state}
      {:exit, _reason} -> {:reply, nil, state}
    end
  end

  def handle_call(:get_screen_pid, _from, state) do
    {_module, pid} = state.current
    {:reply, pid, state}
  end

  def handle_call(:get_current_module, _from, state) do
    {module, _pid} = state.current
    {:reply, module, state}
  end

  def handle_call(:get_nav_history, _from, state) do
    {:reply, Enum.map(Mob.Nav.history(state.nav), &entry_with_socket/1), state}
  end

  def handle_call(:inspect, _from, state) do
    {module, pid} = state.current
    {:ok, socket} = safe_call(fn -> Mob.Screen.Server.socket(pid) end)

    info = %{
      screen: module,
      assigns: socket.assigns,
      nav_history: Enum.map(Mob.Nav.history(state.nav), fn {mod, _} -> mod end),
      tree: module.render(socket.assigns)
    }

    {:reply, info, state}
  end

  @impl GenServer
  def handle_cast(:__mob_hot_reload__, state) do
    # A broadcast, not one cast: every live screen has to repaint with the
    # newly loaded code, not just the one on screen.
    Enum.each(all_screen_pids(state), &Mob.Screen.Server.hot_reload/1)
    {:noreply, state}
  end

  @impl GenServer
  # A screen's callback asked to navigate. Only the active screen may drive
  # navigation — a background screen's timer must not yank the stack out from
  # under whatever the user is looking at.
  def handle_info({:nav_action, action, from}, state) do
    {_module, current_pid} = state.current

    if from == current_pid do
      {:noreply, apply_nav_action(action, state, :async)}
    else
      {:noreply, state}
    end
  end

  # A screen crashed. This is the isolation MOB-112 exists to deliver: the
  # owner is still here, navigation is intact, and the screen comes back.
  def handle_info({:DOWN, _monitor_ref, :process, pid, reason}, state) do
    state = %{state | monitors: Map.delete(state.monitors, pid)}
    {:noreply, restart_screen(pid, reason, state)}
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
    {_module, pid} = state.current
    send(pid, message)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Screens are linked, so they come down with us; stopping them explicitly
    # is what gives each one its terminate/2 and a final state dump.
    Enum.each(all_screen_pids(state), fn pid ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)
  end

  # ── Screen lifecycle ──────────────────────────────────────────────────────

  # Calling into a screen that is mid-crash must not propagate into the owner.
  # The monitor that follows is what actually repairs the screen.
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

    case Mob.Screen.Server.start(opts) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)
        {:ok, {module, pid}, %{state | monitors: Map.put(state.monitors, pid, monitor_ref)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp all_screen_pids(state) do
    current = if state.current, do: [elem(state.current, 1)], else: []

    parked =
      state.nav
      |> Map.get(:parked, %{})
      |> Enum.flat_map(fn {_name, %{current: current, history: history}} ->
        [current | history]
      end)

    (current ++
       Enum.map(Mob.Nav.history(state.nav), &elem(&1, 1)) ++ Enum.map(parked, &elem(&1, 1)))
    |> Enum.uniq()
  end

  # A crashed screen is re-mounted in place. It loses its assigns — a restart
  # runs mount/3 again — which is the documented consequence of the isolation.
  defp restart_screen(dead_pid, reason, state) do
    ref = Mob.Nav.active_ref(state.nav)

    case state.current do
      {module, ^dead_pid} ->
        log_restart(module, reason)

        case start_screen(module, %{}, ref, state) do
          {:ok, entry, state} ->
            state = %{state | current: entry}
            paint(entry, :none, state)
            state

          {:error, _reason} ->
            state
        end

      _ ->
        replace_background_screen(dead_pid, reason, state)
    end
  end

  # A background screen (in the active stack's history, or parked under another
  # stack) is re-mounted eagerly rather than lazily. A crash is rare, and
  # keeping every entry a live pid means popping or switching back never has to
  # deal with a corpse.
  defp replace_background_screen(dead_pid, reason, state) do
    replace = fn
      {module, ^dead_pid} = entry ->
        log_restart(module, reason)

        case start_screen(module, %{}, Mob.Nav.active_ref(state.nav), state) do
          {:ok, new_entry, _state} -> new_entry
          {:error, _} -> entry
        end

      entry ->
        entry
    end

    nav =
      state.nav
      |> Mob.Nav.put_history(Enum.map(Mob.Nav.history(state.nav), replace))
      |> Mob.Nav.map_parked(replace)

    # Re-monitor whatever came back. Cheap, and it keeps `monitors` honest
    # without threading state through the replace function.
    monitors =
      nav
      |> then(fn n -> %{state | nav: n} end)
      |> all_screen_pids()
      |> Enum.reject(&Map.has_key?(state.monitors, &1))
      |> Map.new(&{&1, Process.monitor(&1)})

    %{state | nav: nav, monitors: Map.merge(state.monitors, monitors)}
  end

  defp log_restart(module, reason) do
    Logger.error(
      "[mob] screen #{inspect(module)} crashed and is being restarted; its assigns are lost. " <>
        "Reason: #{inspect(reason)}"
    )
  end

  defp entry_with_socket({module, pid}) do
    case safe_call(fn -> Mob.Screen.Server.socket(pid) end) do
      {:ok, socket} -> {module, socket}
      {:exit, _reason} -> {module, nil}
    end
  end

  defp paint(_entry, _transition, %{render_mode: :no_render}), do: :ok
  defp paint({_module, pid}, transition, _state), do: Mob.Screen.Server.render(pid, transition)

  defp paint_sync(_entry, _transition, %{render_mode: :no_render}), do: :ok

  defp paint_sync({_module, pid}, transition, _state),
    do: Mob.Screen.Server.render_sync(pid, transition)

  defp do_paint(entry, transition, state, :sync), do: paint_sync(entry, transition, state)
  defp do_paint(entry, transition, state, :async), do: paint(entry, transition, state)

  # Demonitor before stopping, or the shutdown we asked for comes back as a
  # :DOWN and the screen gets "restarted" immediately after being discarded.
  defp stop_screen({_module, pid}, state) do
    {monitor_ref, monitors} = Map.pop(state.monitors, pid)
    if monitor_ref, do: Process.demonitor(monitor_ref, [:flush])
    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    %{state | monitors: monitors}
  end

  # ── Navigation ────────────────────────────────────────────────────────────

  defp apply_nav_action(nil, state, _mode), do: state

  defp apply_nav_action({:push, dest, params}, state, mode) do
    {new_module, route_params} = resolve_destination(dest)
    ref = Mob.Nav.active_ref(state.nav)

    case start_screen(new_module, Map.merge(route_params, params), ref, state) do
      {:ok, entry, state} ->
        nav = Mob.Nav.put_history(state.nav, [state.current | Mob.Nav.history(state.nav)])
        state = %{state | nav: nav, current: entry}
        do_paint(entry, :push, state, mode)
        state

      {:error, _reason} ->
        state
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
        state
    end
  end

  defp apply_nav_action({:pop_to_root}, state, mode) do
    case Enum.reverse(Mob.Nav.history(state.nav)) do
      [root | _] ->
        discarded = [state.current | Enum.reject(Mob.Nav.history(state.nav), &(&1 == root))]
        state = Enum.reduce(discarded, state, &stop_screen/2)
        state = %{state | nav: Mob.Nav.put_history(state.nav, []), current: root}
        do_paint(root, :pop, state, mode)
        state

      [] ->
        state
    end
  end

  defp apply_nav_action({:pop_to, dest}, state, mode) do
    target = resolve_module(dest)
    history = Mob.Nav.history(state.nav)

    case pop_to_module(history, target) do
      {:found, previous, rest} ->
        discarded = [state.current | Enum.take_while(history, &(&1 != previous))]
        state = Enum.reduce(discarded, state, &stop_screen/2)
        state = %{state | nav: Mob.Nav.put_history(state.nav, rest), current: previous}
        do_paint(previous, :pop, state, mode)
        state

      :not_found ->
        state
    end
  end

  defp apply_nav_action({:reset, dest, params}, state, mode) do
    {new_module, route_params} = resolve_destination(dest)
    ref = Mob.Nav.active_ref(state.nav)

    case start_screen(new_module, Map.merge(route_params, params), ref, state) do
      {:ok, entry, state} ->
        discarded = [state.current | Mob.Nav.history(state.nav)]
        state = Enum.reduce(discarded, state, &stop_screen/2)
        state = %{state | nav: Mob.Nav.put_history(state.nav, []), current: entry}
        do_paint(entry, :reset, state, mode)
        state

      {:error, _reason} ->
        state
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
        ref = Mob.Nav.active_ref(nav)
        Mob.Sender.set_active(ref)
        state = %{state | nav: nav}

        case start_screen(root_module, %{}, ref, state) do
          {:ok, entry, state} ->
            state = %{state | current: entry}
            do_paint(entry, :none, state, mode)
            state

          {:error, _reason} ->
            state
        end

      :noop ->
        state
    end
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

  defp pop_to_module([{module, _pid} = entry | rest], target) do
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
