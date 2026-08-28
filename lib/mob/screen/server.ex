defmodule Mob.Screen.Server do
  @moduledoc """
  One process per live screen, owning that screen's socket.

  Before MOB-112 a single `Mob.Screen` process held `{module, socket,
  nav_history, render_mode}` and swapped the first two in place on navigation.
  Every screen shared one mailbox, so a crash in any `handle_event` took down
  navigation and every other screen with it — the isolation `Mob.Screen`'s
  moduledoc claimed and mob#76 had to write around.

  Now `Mob.Screen` owns navigation and starts one of these per live screen. A
  crash here kills this screen only; the owner sees the `:DOWN`, restarts it,
  and re-renders.

  ## `self()` means what users already assume

  Inside a screen callback `self()` is now the screen's own pid, not the
  process registered as `:mob_screen`. Screens already wrote
  `on_tap: {self(), :save}` and started tasks expecting exactly that; before,
  those resolved to the one shared process, which is what let a task started by
  screen A be delivered into screen B's `handle_info` with B's socket
  (MOB-107).

  ## A restart re-mounts

  A restarted screen runs `mount/3` again and loses its assigns. Persisted
  screens (`use Mob.Screen, vsn: N` or `persist: true`) get their dumped state
  back through `load_state/2`; everything else starts fresh. Stated rather than
  implied, because it is the visible consequence of the isolation: the screen
  survives, its in-memory state does not.

  ## Navigation is not this process's business

  A user callback that sets a nav action — `push_screen/2`, `pop_screen/1`,
  `switch_tab/2` — has that action handed to the owner, and this process does
  **not** paint. The owner decides which screen is current and tells that
  screen to paint; painting here would flash this screen's tree for a frame
  before the navigation replaced it. Ordinary messages never reach the owner,
  which is what keeps it off the hot path (MOB-113).
  """

  use GenServer

  @state_sync_interval_ms 30_000

  @typedoc "Which navigation stack this screen belongs to, for addressing renders."
  @type render_ref :: atom()

  defstruct [:module, :socket, :render_mode, :ref, :owner]

  @doc """
  Start a screen process.

  `:owner` receives nav actions and monitors this process. `:ref` is the
  navigation stack this screen belongs to, used to address its renders at
  `Mob.Sender`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Start a screen process **unlinked**.

  This is what `Mob.Screen` uses. Linking would defeat the point: the owner
  would die with any screen it stopped or that crashed, taking navigation and
  every sibling screen with it — exactly the coupling MOB-112 removes. The
  owner monitors instead, so it observes the exit without sharing its fate.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc "Run a user event, returning any navigation action it produced."
  @spec dispatch(pid(), String.t(), map()) :: {:ok, term() | nil}
  def dispatch(pid, event, params), do: GenServer.call(pid, {:event, event, params})

  @doc "This screen's current socket."
  @spec socket(pid()) :: Mob.Socket.t()
  def socket(pid), do: GenServer.call(pid, :get_socket)

  @doc "Paint this screen, with the given navigation transition."
  @spec render(pid(), atom()) :: :ok
  def render(pid, transition \\ :none), do: GenServer.cast(pid, {:render, transition})

  @doc "Paint and block until the frame has been committed."
  @spec render_sync(pid(), atom()) :: :ok
  def render_sync(pid, transition \\ :none), do: GenServer.call(pid, {:render_sync, transition})

  @doc "Tell this screen which stack it now belongs to."
  @spec set_ref(pid(), render_ref()) :: :ok
  def set_ref(pid, ref), do: GenServer.cast(pid, {:set_ref, ref})

  @doc "Repaint with the screen module's newly loaded code."
  @spec hot_reload(pid()) :: :ok
  def hot_reload(pid), do: GenServer.cast(pid, :__mob_hot_reload__)

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    module = Keyword.fetch!(opts, :module)
    render_mode = Keyword.get(opts, :render_mode, :no_render)
    platform = Keyword.get(opts, :platform, :android)

    socket =
      module
      |> Mob.Socket.new(platform: platform)
      |> Mob.Socket.assign(:safe_area, initial_safe_area(render_mode))

    case module.mount(Keyword.get(opts, :params, %{}), %{}, socket) do
      {:ok, mounted} ->
        # Restore persisted assigns after mount so mount always runs cleanly.
        socket = maybe_load_state(module, mounted)
        if module.__mob_persist__(), do: schedule_state_sync()

        {:ok,
         %__MODULE__{
           module: module,
           socket: socket,
           render_mode: render_mode,
           ref: Keyword.get(opts, :ref, :__mob_single__),
           owner: Keyword.fetch!(opts, :owner)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:event, event, params}, _from, state) do
    case state.module.handle_event(event, params, state.socket) do
      {:noreply, socket} -> reply_after_callback(socket, state)
      {:reply, _payload, socket} -> reply_after_callback(socket, state)
    end
  end

  def handle_call(:get_socket, _from, state), do: {:reply, state.socket, state}

  def handle_call({:render_sync, transition}, _from, state) do
    {:reply, :ok, %{state | socket: paint(state, transition, :sync)}}
  end

  @impl GenServer
  def handle_cast({:render, transition}, state) do
    {:noreply, %{state | socket: paint(state, transition)}}
  end

  def handle_cast({:set_ref, ref}, state), do: {:noreply, %{state | ref: ref}}

  def handle_cast(:__mob_hot_reload__, state) do
    {:noreply, %{state | socket: paint(state, :none)}}
  end

  @impl GenServer
  # A list row selection arrives as a tap with a structured tag; the user sees
  # the simpler {:select, id, index}.
  def handle_info({:tap, {:list, id, :select, index}}, state) do
    forward({:select, id, index}, state)
  end

  # A component's state changed — repaint so the native view gets fresh props.
  def handle_info({:component_changed, _id, _module}, state) do
    {:noreply, %{state | socket: paint(state, :none)}}
  end

  # Periodic state sync — intercepted before the user's handle_info so the
  # screen module never sees this internal message.
  def handle_info(:__mob_sync_state__, state) do
    if state.module.__mob_persist__() do
      Mob.ScreenState.dump(state.module, state.socket)
      schedule_state_sync()
    end

    {:noreply, state}
  end

  # Android file/camera/photo/scan results arrive JSON-encoded; decode and
  # re-dispatch as the user-facing event tuple.
  def handle_info({:mob_file_result, event, sub, json_binary}, state) do
    handle_info(Mob.Screen.decode_file_result(event, sub, json_binary), state)
  end

  # A few Peripheral.* events carry JSON-encoded device records; the
  # transport's own module knows how to decode them.
  def handle_info({:peripheral, :vendor_usb, _tag, _session, _payload} = msg, state) do
    handle_info(Mob.VendorUsb.normalize_message(msg), state)
  end

  # Activated plugins get first crack at every notification. One whose :match
  # matches handles it and the screen never sees it.
  def handle_info({:notification, payload} = message, state) when is_map(payload) do
    case Mob.Plugins.dispatch_notification(payload) do
      :handled -> {:noreply, state}
      :unhandled -> forward(message, state)
    end
  end

  def handle_info(message, state), do: forward(message, state)

  @impl GenServer
  def terminate(reason, state) do
    if state.module.__mob_persist__(), do: Mob.ScreenState.dump(state.module, state.socket)
    state.module.terminate(reason, state.socket)
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp forward(message, state) do
    {:noreply, socket} = state.module.handle_info(message, state.socket)

    case take_nav_action(socket) do
      {nil, socket} ->
        state = %{state | socket: socket}
        {:noreply, %{state | socket: paint(state, :none)}}

      {action, socket} ->
        send(state.owner, {:nav_action, action, self()})
        {:noreply, %{state | socket: socket}}
    end
  end

  defp reply_after_callback(socket, state) do
    case take_nav_action(socket) do
      {nil, socket} ->
        state = %{state | socket: socket}
        {:reply, {:ok, nil}, %{state | socket: paint(state, :none, :sync)}}

      {action, socket} ->
        # Returned rather than sent: Mob.Screen.dispatch/3 is synchronous, so
        # the owner applies the action before replying to its own caller.
        {:reply, {:ok, action}, %{state | socket: socket}}
    end
  end

  defp take_nav_action(socket) do
    case socket.__mob__.nav_action do
      nil -> {nil, socket}
      action -> {action, Mob.Socket.put_mob(socket, :nav_action, nil)}
    end
  end

  defp paint(state, transition, mode \\ :async)
  defp paint(%{render_mode: :no_render} = state, _transition, _mode), do: state.socket

  defp paint(state, transition, mode) do
    socket = ensure_safe_area(state.socket, state.socket.__mob__.platform)
    platform = socket.__mob__.platform
    list_renderers = Map.get(socket.__mob__, :list_renderers, %{})

    {tree, active_component_keys} =
      state.module.render(socket.assigns)
      # Third expansion pass FIRST: pure-Elixir composites may themselves emit
      # <List> nodes / native_view components for the later passes.
      |> Mob.Composite.expand(self())
      |> Mob.List.expand(list_renderers, self())
      |> Mob.Component.expand(self(), platform)

    Mob.ComponentRegistry.reconcile(self(), active_component_keys)
    Mob.Sender.render(state.ref, tree, platform, :mob_nif, transition)
    if mode == :sync, do: Mob.Sender.sync(:infinity)

    Mob.Socket.put_root_view(socket, :json_tree)
  end

  defp initial_safe_area(:render) do
    {t, r, b, l} = :mob_nif.safe_area()
    %{top: t, right: r, bottom: b, left: l}
  end

  defp initial_safe_area(_mode), do: %{top: 0.0, right: 0.0, bottom: 0.0, left: 0.0}

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

  defp schedule_state_sync do
    Process.send_after(self(), :__mob_sync_state__, @state_sync_interval_ms)
  end
end
