defmodule Mob.ComponentServer do
  @moduledoc false
  # GenServer wrapping a Mob.Component module. Each native_view instance on a
  # screen gets its own process. Started unlinked (isolated from the screen).

  use GenServer

  @doc "Start a component process (not linked to the caller)."
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc "Get the current rendered props from the component."
  @spec render_props(pid()) :: map()
  def render_props(pid), do: GenServer.call(pid, :render_props)

  @doc "Get the persistent NIF handle allocated at mount time."
  @spec get_handle(pid()) :: integer()
  def get_handle(pid), do: GenServer.call(pid, :get_handle)

  @doc "Update the component with new props from the parent screen re-render."
  @spec update(pid(), map()) :: :ok
  def update(pid, props), do: GenServer.cast(pid, {:update, props})

  @doc "Deliver a native event to the component (called from the NIF callback path)."
  @spec dispatch(pid(), String.t(), map()) :: :ok
  def dispatch(pid, event, payload), do: GenServer.cast(pid, {:event, event, payload})

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    module = opts[:module]
    id = opts[:id]
    screen_pid = opts[:screen_pid]
    props = opts[:props]
    platform = opts[:platform]

    socket = Mob.Socket.new(module, platform: platform)

    case module.mount(props, socket) do
      {:ok, socket} ->
        Mob.ComponentRegistry.register(screen_pid, id, module, self())

        handle =
          if platform != :no_render do
            :mob_nif.register_component(self())
          else
            0
          end

        {:ok, %{module: module, socket: socket, screen_pid: screen_pid, id: id, handle: handle}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:render_props, _from, %{module: module, socket: socket} = state) do
    {:reply, module.render(socket.assigns), state}
  end

  def handle_call(:get_handle, _from, %{handle: handle} = state) do
    {:reply, handle, state}
  end

  @impl GenServer
  def handle_cast({:update, new_props}, %{module: module, socket: socket} = state) do
    case module.update(new_props, socket) do
      {:ok, new_socket} -> {:noreply, %{state | socket: new_socket}}
      _ -> {:noreply, state}
    end
  end

  def handle_cast(
        {:event, event, payload},
        %{module: module, socket: socket, screen_pid: screen_pid, id: id} = state
      ) do
    {:noreply, new_socket} = module.handle_event(event, payload, socket)
    send(screen_pid, {:component_changed, id, module})
    {:noreply, %{state | socket: new_socket}}
  end

  @impl GenServer
  def handle_info(
        {:component_event, event, payload_json},
        %{module: module, socket: socket, screen_pid: screen_pid, id: id} = state
      ) do
    payload =
      case :json.decode(payload_json) do
        map when is_map(map) -> map
        _ -> %{}
      end

    {:noreply, new_socket} = module.handle_event(event, payload, socket)
    send(screen_pid, {:component_changed, id, module})
    {:noreply, %{state | socket: new_socket}}
  end

  def handle_info(
        message,
        %{module: module, socket: socket, screen_pid: screen_pid, id: id} = state
      ) do
    {:noreply, new_socket} = module.handle_info(message, socket)
    send(screen_pid, {:component_changed, id, module})
    {:noreply, %{state | socket: new_socket}}
  end

  @impl GenServer
  def terminate(reason, %{
        module: module,
        socket: socket,
        screen_pid: screen_pid,
        id: id,
        handle: handle
      }) do
    Mob.ComponentRegistry.deregister(screen_pid, id, module)
    if handle != 0, do: :mob_nif.deregister_component(handle)
    module.terminate(reason, socket)
  end
end
