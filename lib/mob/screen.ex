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

  @doc """
  Start a screen process linked to the calling process.

  `params` is passed as the first argument to `mount/3`.
  """
  @spec start_link(module(), map(), keyword()) :: GenServer.on_start()
  def start_link(screen_module, params, opts \\ []) do
    GenServer.start_link(__MODULE__, {screen_module, params, :no_render, :android}, opts)
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

    case screen_module.mount(params, %{}, socket) do
      {:ok, mounted_socket} ->
        socket =
          if render_mode == :render do
            do_render(screen_module, mounted_socket)
          else
            mounted_socket
          end
        {:ok, {screen_module, socket, render_mode}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:event, event, params}, _from, {module, socket, render_mode}) do
    case module.handle_event(event, params, socket) do
      {:noreply, new_socket} ->
        new_socket =
          if render_mode == :render do
            do_render(module, new_socket)
          else
            new_socket
          end
        {:reply, :ok, {module, new_socket, render_mode}}

      {:reply, _response, new_socket} ->
        new_socket =
          if render_mode == :render do
            do_render(module, new_socket)
          else
            new_socket
          end
        {:reply, :ok, {module, new_socket, render_mode}}
    end
  end

  def handle_call(:get_socket, _from, {_module, socket, _mode} = state) do
    {:reply, socket, state}
  end

  @impl GenServer
  def handle_info(message, {module, socket, render_mode}) do
    {:noreply, new_socket} = module.handle_info(message, socket)
    new_socket =
      if render_mode == :render do
        do_render(module, new_socket)
      else
        new_socket
      end
    {:noreply, {module, new_socket, render_mode}}
  end

  @impl GenServer
  def terminate(reason, {module, socket, _render_mode}) do
    module.terminate(reason, socket)
  end

  # ── Render pipeline ───────────────────────────────────────────────────────

  defp do_render(module, socket) do
    platform = socket.__mob__.platform
    tree = module.render(socket.assigns)
    case Mob.Renderer.render(tree, platform) do
      {:ok, root_ref} ->
        :mob_nif.set_root(root_ref)
        Mob.Socket.put_root_view(socket, root_ref)
      {:error, reason} ->
        require Logger
        Logger.error("Mob.Screen render failed: #{inspect(reason)}")
        socket
    end
  end
end
