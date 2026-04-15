defmodule Mob.Screen do
  @moduledoc """
  The behaviour and process wrapper for a Mob screen.

  A screen is a supervised GenServer. Its state is a `Mob.Socket`. Lifecycle
  callbacks (`mount`, `render`, `handle_event`, `handle_info`, `terminate`) map
  directly to the GenServer lifecycle.

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

  @optional_callbacks [handle_event: 3, handle_info: 2, terminate: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour Mob.Screen
      import Mob.Sigil

      def handle_info(_message, socket), do: {:noreply, socket}

      def terminate(_reason, _socket), do: :ok

      def handle_event(event, _params, _socket) do
        raise "unhandled event #{inspect(event)} in #{inspect(__MODULE__)}. " <>
                "Add a handle_event/3 clause to handle it."
      end

      defoverridable handle_info: 2, terminate: 2, handle_event: 3
    end
  end

  # ── GenServer wrapper ─────────────────────────────────────────────────────

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
        socket =
          if render_mode == :render do
            do_render(screen_module, mounted_socket)
          else
            mounted_socket
          end
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

  def handle_call(:get_socket, _from, {_module, socket, _nav_history, _mode} = state) do
    {:reply, socket, state}
  end

  def handle_call(:get_current_module, _from, {module, _socket, _nav_history, _mode} = state) do
    {:reply, module, state}
  end

  def handle_call(:get_nav_history, _from, {_module, _socket, nav_history, _mode} = state) do
    {:reply, nav_history, state}
  end

  # System back gesture (Android hardware/swipe, iOS edge-pan).
  # Handled here — before the user's handle_info — so every screen gets back
  # navigation for free without implementing anything.
  @impl GenServer
  def handle_info({:mob, :back}, {module, socket, nav_history, render_mode}) do
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

  @impl GenServer
  def terminate(reason, {module, socket, _nav_history, _render_mode}) do
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
        new_base = Mob.Socket.new(new_module, platform: platform)
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
        new_base = Mob.Socket.new(new_module, platform: platform)
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

  # ── Render pipeline ───────────────────────────────────────────────────────

  defp do_render(module, socket, transition \\ :none) do
    platform = socket.__mob__.platform
    tree = module.render(socket.assigns)
    case Mob.Renderer.render(tree, platform, :mob_nif, transition) do
      {:ok, token} ->
        Mob.Socket.put_root_view(socket, token)
      {:error, reason} ->
        Logger.error("Mob.Screen render failed: #{inspect(reason)}")
        socket
    end
  end
end
