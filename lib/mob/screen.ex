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
    GenServer.start_link(__MODULE__, {screen_module, params}, opts)
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
  def init({screen_module, params}) do
    socket = Mob.Socket.new(screen_module)

    case screen_module.mount(params, %{}, socket) do
      {:ok, mounted_socket} ->
        {:ok, {screen_module, mounted_socket}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:event, event, params}, _from, {module, socket}) do
    case module.handle_event(event, params, socket) do
      {:noreply, new_socket} ->
        {:reply, :ok, {module, new_socket}}

      {:reply, _response, new_socket} ->
        {:reply, :ok, {module, new_socket}}
    end
  end

  def handle_call(:get_socket, _from, {_module, socket} = state) do
    {:reply, socket, state}
  end

  @impl GenServer
  def handle_info(message, {module, socket}) do
    {:noreply, new_socket} = module.handle_info(message, socket)
    {:noreply, {module, new_socket}}
  end

  @impl GenServer
  def terminate(reason, {module, socket}) do
    module.terminate(reason, socket)
  end
end
