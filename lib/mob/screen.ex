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

  # ── GenServer wrapper ─────────────────────────────────────────────────────

  use GenServer

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
  def get_current_module(pid) do
    GenServer.call(pid, :get_current_module)
  end

  @doc """
  Return the navigation history (list of `{module, socket}` pairs, head = most recent).
  Intended for testing and debugging.
  """
  @spec get_nav_history(pid()) :: [{module(), Mob.Socket.t()}]
  def get_nav_history(pid) do
    GenServer.call(pid, :get_nav_history)
  end

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
  def dispatch(pid, event, params) do
    GenServer.call(pid, {:event, event, params})
  end

  @doc """
  Return the current socket state of a running screen.
  Intended for testing and debugging — not for production app logic.
  """
  @spec get_socket(pid()) :: socket()
  def get_socket(pid) do
    GenServer.call(pid, :get_socket)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl GenServer
  def init({screen_module, params, render_mode, platform}) do
    socket = Mob.Socket.new(screen_module, platform: platform)

    # Register under :mob_screen so C-layer mob_handle_back() can find us.
    # Only in :render mode (production); tests use :no_render and run without a NIF.
    if render_mode == :render, do: Process.register(self(), :mob_screen)

    socket =
      if render_mode == :render do
        {t, r, b, l} = :mob_nif.safe_area()
        Mob.Socket.assign(socket, :safe_area, %{top: t, right: r, bottom: b, left: l})
      else
        Mob.Socket.assign(socket, :safe_area, %{top: 0.0, right: 0.0, bottom: 0.0, left: 0.0})
      end

    case screen_module.mount(params, %{}, socket) do
      {:ok, mounted_socket} ->
        # Restore persisted assigns after mount so mount always runs cleanly.
        # safe_area is re-applied from the current socket so a stale device
        # inset from storage never wins over the live value.
        loaded_socket = maybe_load_state(screen_module, mounted_socket)

        socket =
          if render_mode == :render do
            # Check for a notification that launched the app from a killed state.
            # Send it to self so it arrives via handle_info after init returns,
            # consistent with foreground notification delivery.
            case :mob_nif.take_launch_notification() do
              :none -> :ok
              json -> send(self(), {:mob_launch_notification, json})
            end

            do_render(screen_module, loaded_socket)
          else
            loaded_socket
          end

        if screen_module.__mob_persist__(), do: schedule_state_sync()
        {:ok, {screen_module, socket, [], render_mode}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:event, event, params}, _from, {module, socket, nav_history, render_mode}) do
    case module.handle_event(event, params, socket) do
      {:noreply, new_socket} ->
        {module, new_socket, nav_history, transition} =
          apply_nav_action(module, new_socket, nav_history)

        new_socket =
          if render_mode == :render do
            do_render(module, new_socket, transition)
          else
            new_socket
          end

        {:reply, :ok, {module, new_socket, nav_history, render_mode}}

      {:reply, _response, new_socket} ->
        {module, new_socket, nav_history, transition} =
          apply_nav_action(module, new_socket, nav_history)

        new_socket =
          if render_mode == :render do
            do_render(module, new_socket, transition)
          else
            new_socket
          end

        {:reply, :ok, {module, new_socket, nav_history, render_mode}}
    end
  end

  @doc """
  Apply a navigation action directly. Used by `Mob.Test` to drive navigation
  programmatically without needing a UI event. Synchronous — the caller blocks
  until the navigation (and re-render, in production mode) completes.

  Valid actions mirror the `Mob.Socket` navigation functions:
  - `{:push, dest, params}` — push a new screen
  - `{:pop}` — pop to the previous screen
  - `{:pop_to, dest}` — pop to a specific screen in history
  - `{:pop_to_root}` — pop to the root of the current stack
  - `{:reset, dest, params}` — replace the entire nav stack
  """
  def handle_call({:navigate, nav_action}, _from, {module, socket, nav_history, render_mode}) do
    socket = Mob.Socket.put_mob(socket, :nav_action, nav_action)

    {new_module, new_socket, new_history, transition} =
      apply_nav_action(module, socket, nav_history)

    new_socket =
      if render_mode == :render do
        do_render(new_module, new_socket, transition)
      else
        new_socket
      end

    {:reply, :ok, {new_module, new_socket, new_history, render_mode}}
  end

  def handle_call(:get_socket, _from, {_module, socket, _nav_history, _mode} = state) do
    {:reply, socket, state}
  end

  def handle_call(:inspect, _from, {module, socket, nav_history, _mode} = state) do
    tree = module.render(socket.assigns)

    info = %{
      screen: module,
      assigns: socket.assigns,
      nav_history: Enum.map(nav_history, fn {mod, _} -> mod end),
      tree: tree
    }

    {:reply, info, state}
  end

  def handle_call(:get_current_module, _from, {module, _socket, _nav_history, _mode} = state) do
    {:reply, module, state}
  end

  def handle_call(:get_nav_history, _from, {_module, _socket, nav_history, _mode} = state) do
    {:reply, nav_history, state}
  end

  # Notification that launched the app from a killed state.
  # Decoded from JSON and re-dispatched as the standard {:notification, map} message.
  # Hot-reload trigger sent by mob_dev after a dist push. Re-render with current code.
  @impl GenServer
  def handle_cast(:__mob_hot_reload__, {module, socket, nav_history, render_mode}) do
    new_socket =
      if render_mode == :render do
        do_render(module, socket)
      else
        socket
      end

    {:noreply, {module, new_socket, nav_history, render_mode}}
  end

  @impl GenServer
  def handle_info({:mob_launch_notification, json}, {module, socket, nav_history, render_mode}) do
    notif = decode_notification_json(json)
    handle_info({:notification, notif}, {module, socket, nav_history, render_mode})
  end

  # Android file/camera/photo/scan results arrive as {:mob_file_result, event, sub, json_binary}.
  # Decode the JSON and re-dispatch as the user-facing event tuple.
  def handle_info({:mob_file_result, event, sub, json_binary}, state) do
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

    msg =
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
          item = List.first(items) || %{}
          {:storage, :saved_to_library, item[:path]}

        {:scan, :result} ->
          item = List.first(items) || %{}
          {:scan, :result, %{type: item[:type] |> to_atom_safe(), value: item[:value]}}

        _ ->
          {event_atom, sub_atom, items}
      end

    handle_info(msg, state)
  end

  # Peripheral.* events: a few carry JSON-encoded device records under tags
  # like `:devices_json`, `:permission_granted_json`, etc. The transport's
  # own module knows how to decode them; we dispatch through its
  # `normalize_message/1` (a no-op for events without JSON payloads) before
  # the user's handle_info sees them.
  def handle_info({:peripheral, :vendor_usb, _tag, _session, _payload} = msg, state) do
    normalized = Mob.VendorUsb.normalize_message(msg)
    handle_info(normalized, state)
  end

  # System back gesture (Android hardware/swipe, iOS edge-pan).
  # Handled here — before the user's handle_info — so every screen gets back
  # navigation for free without implementing anything.
  # If a WebView is present and has internal history, navigate within it first
  # before popping the Mob nav stack.
  def handle_info({:mob, :back}, {module, socket, nav_history, render_mode}) do
    if render_mode == :render && :mob_nif.webview_can_go_back() do
      :mob_nif.webview_go_back()
      {:noreply, {module, socket, nav_history, render_mode}}
    else
      {module, new_socket, new_history, transition} =
        if nav_history == [] do
          if render_mode == :render, do: :mob_nif.exit_app()
          {module, socket, [], :none}
        else
          apply_nav_action(module, Mob.Socket.put_mob(socket, :nav_action, {:pop}), nav_history)
        end

      new_socket =
        if render_mode == :render do
          do_render(module, new_socket, transition)
        else
          new_socket
        end

      {:noreply, {module, new_socket, new_history, render_mode}}
    end
  end

  # List row selected — intercept before the user's handle_info and convert to
  # a plain {:select, id, index} message so screens don't need to know about
  # the internal {:tap, {:list, ...}} tag format.
  def handle_info({:tap, {:list, id, :select, index}}, {module, socket, nav_history, render_mode}) do
    {:noreply, new_socket} = module.handle_info({:select, id, index}, socket)

    {module, new_socket, nav_history, transition} =
      apply_nav_action(module, new_socket, nav_history)

    new_socket =
      if render_mode == :render do
        do_render(module, new_socket, transition)
      else
        new_socket
      end

    {:noreply, {module, new_socket, nav_history, render_mode}}
  end

  # A component's state changed — re-render so the native view gets fresh props.
  def handle_info({:component_changed, _id, _module}, {module, socket, nav_history, render_mode}) do
    new_socket =
      if render_mode == :render do
        do_render(module, socket)
      else
        socket
      end

    {:noreply, {module, new_socket, nav_history, render_mode}}
  end

  # Periodic state sync — intercepted before the user's handle_info so the
  # screen module never sees this internal message.
  def handle_info(:__mob_sync_state__, {module, socket, nav_history, render_mode}) do
    if module.__mob_persist__() do
      Mob.ScreenState.dump(module, socket)
      schedule_state_sync()
    end

    {:noreply, {module, socket, nav_history, render_mode}}
  end

  def handle_info(message, {module, socket, nav_history, render_mode}) do
    {:noreply, new_socket} = module.handle_info(message, socket)

    {module, new_socket, nav_history, transition} =
      apply_nav_action(module, new_socket, nav_history)

    new_socket =
      if render_mode == :render do
        do_render(module, new_socket, transition)
      else
        new_socket
      end

    {:noreply, {module, new_socket, nav_history, render_mode}}
  end

  defp to_atom_safe(nil), do: :qr
  defp to_atom_safe(s) when is_binary(s), do: String.to_atom(s)
  defp to_atom_safe(a) when is_atom(a), do: a

  @impl GenServer
  def terminate(reason, {module, socket, _nav_history, _render_mode}) do
    if module.__mob_persist__(), do: Mob.ScreenState.dump(module, socket)
    module.terminate(reason, socket)
  end

  # ── Navigation ────────────────────────────────────────────────────────────

  # Inspect the socket's nav_action and execute it, returning
  # {new_module, new_socket, new_nav_history, transition}.
  defp apply_nav_action(module, socket, nav_history) do
    case socket.__mob__.nav_action do
      nil ->
        {module, socket, nav_history, :none}

      {:push, dest, params} ->
        new_module = resolve_module(dest)
        platform = socket.__mob__.platform

        new_base =
          Mob.Socket.new(new_module, platform: platform)
          |> Mob.Socket.assign(:safe_area, socket.assigns.safe_area)

        {:ok, mounted} = new_module.mount(params, %{}, new_base)
        saved = {module, clear_nav_action(socket)}
        {new_module, mounted, [saved | nav_history], :push}

      {:pop} ->
        case nav_history do
          [{prev_module, prev_socket} | rest] ->
            {prev_module, prev_socket, rest, :pop}

          [] ->
            {module, clear_nav_action(socket), [], :none}
        end

      {:pop_to_root} ->
        case Enum.reverse(nav_history) do
          [{root_module, root_socket} | _] ->
            {root_module, root_socket, [], :pop}

          [] ->
            {module, clear_nav_action(socket), [], :none}
        end

      {:pop_to, dest} ->
        target = resolve_module(dest)

        case pop_to_module(nav_history, target) do
          {:found, prev_module, prev_socket, rest} ->
            {prev_module, prev_socket, rest, :pop}

          :not_found ->
            {module, clear_nav_action(socket), nav_history, :none}
        end

      {:reset, dest, params} ->
        new_module = resolve_module(dest)
        platform = socket.__mob__.platform

        new_base =
          Mob.Socket.new(new_module, platform: platform)
          |> Mob.Socket.assign(:safe_area, socket.assigns.safe_area)

        {:ok, mounted} = new_module.mount(params, %{}, new_base)
        {new_module, mounted, [], :reset}

      {:switch_tab, _tab} ->
        # Tab switching is handled renderer-side; clear the action.
        {module, clear_nav_action(socket), nav_history, :none}
    end
  end

  defp resolve_module(dest) when is_atom(dest) do
    case Code.ensure_loaded(dest) do
      {:module, ^dest} ->
        # dest is a loaded module — use it directly
        dest

      _ ->
        # dest is a registered screen name atom — look up in registry
        case Mob.Nav.Registry.lookup(dest) do
          {:ok, module} ->
            module

          {:error, :not_found} ->
            raise ArgumentError,
                  "Mob.Screen: unknown navigation destination #{inspect(dest)}. " <>
                    "Register it via Mob.Nav.Registry.register/2 or declare it in " <>
                    "your App.navigation/1."
        end
    end
  end

  defp pop_to_module([], _target), do: :not_found

  defp pop_to_module([{module, socket} | rest], target) do
    if module == target do
      {:found, module, socket, rest}
    else
      pop_to_module(rest, target)
    end
  end

  defp clear_nav_action(socket) do
    Mob.Socket.put_mob(socket, :nav_action, nil)
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
            d when is_map(d) ->
              Map.new(d, fn {k, v} -> {String.to_atom(k), v} end)

            _ ->
              %{}
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

  # ── State persistence ─────────────────────────────────────────────────────

  @state_sync_interval_ms 30_000

  defp schedule_state_sync do
    Process.send_after(self(), :__mob_sync_state__, @state_sync_interval_ms)
  end

  defp maybe_load_state(module, socket) do
    if module.__mob_persist__() do
      case Mob.ScreenState.load(module, socket) do
        {:ok, stored_vsn, raw} ->
          restored = module.load_state(stored_vsn, raw)

          socket
          |> Mob.Socket.assign(restored)
          |> Mob.Socket.assign(:safe_area, socket.assigns.safe_area)

        :not_found ->
          socket
      end
    else
      socket
    end
  end

  # ── Render pipeline ───────────────────────────────────────────────────────

  defp do_render(module, socket, transition \\ :none) do
    platform = socket.__mob__.platform
    list_renderers = Map.get(socket.__mob__, :list_renderers, %{})
    socket = ensure_safe_area(socket, platform)

    {tree, active_component_keys} =
      module.render(socket.assigns)
      |> Mob.List.expand(list_renderers, self())
      |> Mob.Component.expand(self(), platform)

    Mob.ComponentRegistry.reconcile(self(), active_component_keys)
    {:ok, token} = Mob.Renderer.render(tree, platform, :mob_nif, transition)
    Mob.Socket.put_root_view(socket, token)
  end

  defp ensure_safe_area(socket, platform) do
    if Map.has_key?(socket.assigns, :safe_area) do
      socket
    else
      safe_area =
        if platform == :ios do
          {t, r, b, l} = :mob_nif.safe_area()
          %{top: t, right: r, bottom: b, left: l}
        else
          %{top: 0.0, right: 0.0, bottom: 0.0, left: 0.0}
        end

      Mob.Socket.assign(socket, :safe_area, safe_area)
    end
  end
end
