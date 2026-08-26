defmodule Mob.ComponentServer do
  @moduledoc false
  # GenServer wrapping a Mob.Component module. Each native_view instance on a
  # screen gets its own process. Started unlinked (isolated from the screen).

  use GenServer
  require Logger

  @default_nif :mob_nif

  # Sentinel for "no native handle assigned" — used both when the platform
  # doesn't render natively (:no_render, e.g. in tests) and when the native
  # component slot pool is exhausted (MOB-100). Slot 0 is a legitimate pool
  # index returned by :mob_nif.register_component/1, so it cannot double as
  # this sentinel the way it used to (that conflation leaked slot 0 forever).
  @no_handle -1

  @doc "Start a component process (not linked to the caller)."
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
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
    # MOB-100: Mob.ComponentRegistry.reconcile/2 stops a component that has
    # left the tree via Process.exit(pid, :shutdown). A GenServer that isn't
    # trapping exits terminates immediately on that signal WITHOUT running
    # terminate/2 — the native handle (and, before this fix, the registry
    # entry) leaked on every single screen navigation, not just for slot 0.
    # Trapping exits turns that signal into a regular {:EXIT, _, reason}
    # message (handled below) that goes through the normal {:stop, ...}
    # path instead, so terminate/2 — and its deregister_component call —
    # actually runs.
    Process.flag(:trap_exit, true)

    module = opts[:module]
    id = opts[:id]
    screen_pid = opts[:screen_pid]
    props = opts[:props]
    platform = opts[:platform]
    nif = opts[:nif] || @default_nif

    socket = Mob.Socket.new(module, platform: platform)

    case module.mount(props, socket) do
      {:ok, socket} ->
        Mob.ComponentRegistry.register(screen_pid, id, module, self())

        handle = register_native_handle(nif, platform, module, id)

        {:ok,
         %{
           module: module,
           socket: socket,
           screen_pid: screen_pid,
           id: id,
           handle: handle,
           nif: nif
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp register_native_handle(_nif, :no_render, _module, _id), do: @no_handle

  defp register_native_handle(nif, _platform, module, id) do
    case nif.register_component(self()) do
      {:ok, handle} ->
        handle

      {:error, :component_slots_exhausted} ->
        Logger.error(
          "[mob_component_server] native component slot pool exhausted — " <>
            "#{inspect(module)} id=#{inspect(id)} will not receive native events"
        )

        @no_handle
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
    event = to_binary(event)
    payload = decode_payload(payload_json)

    {:noreply, new_socket} = module.handle_event(event, payload, socket)
    send(screen_pid, {:component_changed, id, module})
    {:noreply, %{state | socket: new_socket}}
  end

  # Trapping exits (see init/1) turns Mob.ComponentRegistry.reconcile/2's
  # Process.exit(pid, :shutdown) into this message instead of an untrappable
  # kill — route it through the normal stop path so terminate/2 runs.
  def handle_info({:EXIT, _from, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(
        message,
        %{module: module, socket: socket, screen_pid: screen_pid, id: id} = state
      ) do
    {:noreply, new_socket} = module.handle_info(message, socket)
    send(screen_pid, {:component_changed, id, module})
    {:noreply, %{state | socket: new_socket}}
  end

  # The native contract is binaries (see mob_send_component_event on both
  # platforms). This stays TEMPORARILY so a hot-deployed BEAM doesn't crash
  # against an older native shell that still emits charlists — MOB-98.
  #
  # IO.iodata_to_binary/1, not List.to_string/1: the legacy charlist came
  # from ObjC's enif_make_string(env, cstr, ERL_NIF_LATIN1), which maps
  # codepoint N to byte N — the same as raw-byte iodata, NOT Unicode
  # codepoints. List.to_string/1 would UTF-8-encode any byte > 127 into two
  # bytes, corrupting non-ASCII legacy payloads instead of reproducing them.
  #
  # Never raises: this is the component-event boundary from native code, and
  # a malformed shape here (however unlikely) must not crash the component
  # process over a value it never asked for.
  @doc false
  @spec to_binary(term()) :: binary()
  def to_binary(value) when is_binary(value), do: value

  def to_binary(value) when is_list(value) do
    IO.iodata_to_binary(value)
  rescue
    ArgumentError -> log_unexpected_shape(value)
  end

  def to_binary(other), do: log_unexpected_shape(other)

  defp log_unexpected_shape(value) do
    Logger.warning(
      "[mob_component_server] expected a binary or charlist event/payload, got: #{inspect(value)}"
    )

    ""
  end

  # payload_json arrives as a binary (fixed native contract) or, from an
  # older native shell, a charlist — same compat window as to_binary/1
  # above. :json.decode/1 raises on genuinely malformed input rather than
  # returning an error tuple; both that and a validly-decoded non-map value
  # (e.g. a bare `"5"` or `"null"`) fall back to %{} rather than crashing
  # the component process over a bad event payload.
  @doc false
  @spec decode_payload(binary() | charlist()) :: map()
  def decode_payload(json) do
    case :json.decode(to_binary(json)) do
      map when is_map(map) -> map
      _ -> %{}
    end
  rescue
    ErlangError -> %{}
  end

  @impl GenServer
  def terminate(reason, %{
        module: module,
        socket: socket,
        screen_pid: screen_pid,
        id: id,
        handle: handle,
        nif: nif
      }) do
    Mob.ComponentRegistry.deregister(screen_pid, id, module)
    if handle >= 0, do: nif.deregister_component(handle)
    module.terminate(reason, socket)
  end
end
