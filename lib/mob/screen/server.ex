defmodule Mob.Screen.Server do
  @moduledoc """
  One process per live screen, owning that screen's socket.

  Before MOB-112 a single `Mob.Screen` process held `{module, socket,
  nav_history, render_mode}` and swapped the first two in place on navigation.
  Every screen shared one mailbox, so a crash in any `handle_event` took down
  navigation and every other screen with it — the isolation `Mob.Screen`'s
  moduledoc claimed and mob#76 had to write around.

  `Mob.Router` owns navigation and starts one of these per live screen. A crash
  here kills this screen only; the router sees the exit, restarts it, and
  re-renders.

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

  require Logger

  @state_sync_interval_ms 30_000

  @typedoc """
  Identifies this screen to `Mob.Sender`. Unique per **screen**, not per stack.

  Every screen is a live process that repaints on any message it receives,
  including the ones below the top of a stack. Keyed by stack they would share
  a ref, and a timer tick in a screen the user cannot see would commit its tree
  over the one they can. The sender only commits the active ref.
  """
  @type render_ref :: reference()

  defstruct [:module, :socket, :render_mode, :ref, :owner, :nif, persist_on_terminate: true]

  @doc """
  Start a screen linked to the calling process.

  `:owner` receives nav actions and the exit signal. `:ref` identifies this
  screen to `Mob.Sender` and is unique per screen — see `t:render_ref/0`.

  `Mob.Router` links *and* traps exits. Linking alone would make the owner die
  with any screen it stopped or that crashed; trapping alone would leave every
  screen orphaned when the owner died — and an orphaned persisted screen keeps
  dumping to `Mob.ScreenState` under the same key as its live replacement.
  Together the owner observes each exit as a message without sharing its fate,
  and screens still come down with it.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Run a user event, returning any navigation action it produced."
  @spec dispatch(pid(), String.t(), map()) :: {:ok, term() | nil}
  def dispatch(pid, event, params) do
    # No deadline. The screen returns its nav action in the reply, having
    # already cleared it from its socket, so a timeout here does not fail the
    # event — it silently discards the navigation the user asked for. A slow
    # handle_event is a slow app; it is not a lost push.
    GenServer.call(pid, {:event, event, params}, :infinity)
  end

  @doc "This screen's current socket."
  @spec socket(pid()) :: Mob.Socket.t()
  def socket(pid), do: GenServer.call(pid, :get_socket)

  @doc false
  @spec discard_persisted_state(pid(), timeout()) :: :ok
  def discard_persisted_state(pid, timeout \\ 5_000) do
    GenServer.call(pid, :discard_persisted_state, timeout)
  end

  @doc """
  Render this screen's tree, in this screen's process.

  For inspection only — it does not commit anything. Running `render/1` in the
  caller instead would put user code in the owner, where a raise takes down
  navigation and every other screen.
  """
  @spec tree(pid()) :: map()
  def tree(pid), do: GenServer.call(pid, :get_tree)

  @doc "Paint this screen, with the given navigation transition."
  @spec render(pid(), atom()) :: :ok
  def render(pid, transition \\ :none), do: GenServer.cast(pid, {:render, transition})

  @doc false
  @spec render(pid(), atom(), reference() | nil) :: :ok
  def render(pid, transition, activation_token),
    do: GenServer.cast(pid, {:render, transition, activation_token})

  @doc "Paint and block until the frame has been committed."
  @spec render_sync(pid(), atom()) :: :ok
  def render_sync(pid, transition \\ :none) do
    # Matches Mob.Sender.sync(:infinity) one hop down: rendering was never
    # time-bounded, and bounding it here would kill the screen on a slow frame.
    GenServer.call(pid, {:render_sync, transition}, :infinity)
  end

  @doc false
  @spec render_sync(pid(), atom(), reference() | nil) :: :ok
  def render_sync(pid, transition, activation_token) do
    GenServer.call(pid, {:render_sync, transition, activation_token}, :infinity)
  end

  @doc "Repaint with the screen module's newly loaded code."
  @spec hot_reload(pid()) :: :ok
  def hot_reload(pid), do: GenServer.cast(pid, :__mob_hot_reload__)

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Trapping so this screen shuts down gracefully when its owner exits:
    # gen_server turns the parent's EXIT into a terminate/2 call, which is what
    # runs the user's terminate/2 and the final Mob.ScreenState dump. Without
    # it a screen is killed by the link and neither happens.
    Process.flag(:trap_exit, true)

    module = Keyword.fetch!(opts, :module)
    render_mode = Keyword.get(opts, :render_mode, :no_render)
    platform = Keyword.get(opts, :platform, :android)
    # Injectable for the same reason Mob.Renderer and Mob.Sender take it as a
    # parameter: without it nothing can exercise the render path off-device.
    nif = Keyword.get(opts, :nif, :mob_nif)

    socket =
      module
      |> Mob.Socket.new(platform: platform)
      |> then(fn socket ->
        {insets, status} = initial_safe_area(render_mode, nif)

        socket
        |> Mob.Socket.assign(:safe_area, insets)
        |> Mob.Socket.put_mob(:safe_area_confirmed, status == :confirmed)
      end)

    case module.mount(Keyword.get(opts, :params, %{}), %{}, socket) do
      {:ok, mounted} ->
        # Restore persisted assigns after mount so mount always runs cleanly.
        socket =
          if Keyword.get(opts, :restore_persisted_state, true) do
            maybe_load_state(module, mounted)
          else
            mounted
          end

        if module.__mob_persist__(), do: schedule_state_sync()

        {:ok,
         %__MODULE__{
           module: module,
           socket: socket,
           render_mode: render_mode,
           ref: Keyword.get(opts, :ref, :__mob_single__),
           owner: Keyword.fetch!(opts, :owner),
           nif: nif
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:event, event, params}, _from, state) do
    # MOB-155. The receipt is assembled around the callback rather than inside
    # it, so the stages are observed rather than reported: a handler cannot
    # claim it changed something it did not.
    started = System.monotonic_time(:microsecond)
    # The term itself, not a hash of it. `!==` answers "did assigns change"
    # exactly, and short-circuits: 0.01us against 43us for a deep phash2 over a
    # 1000-row list screen's assigns, twice per event. The hash was answering a
    # boolean question the expensive way, on the path of every event in the app.
    before_assigns = state.socket.assigns
    before_tree = Map.get(state.socket.__mob__, :last_frame)

    receipt = %Mob.Agent.Receipt{
      action_id: Mob.Agent.Receipt.new_action_id(),
      screen: state.module,
      event: event,
      stages: [:dispatched],
      before_frame_fingerprint: before_tree,
      monotonic_us: started
    }

    try do
      state.module.handle_event(event, params, state.socket)
    catch
      kind, reason ->
        # `catch` hands back the raw Erlang reason — `:function_clause`, not a
        # `%FunctionClauseError{}` — and the raw atom cannot say *which*
        # function failed to match. Normalising recovers the module, function
        # and arity, which is what separates "no clause for this event" from
        # "the handler crashed".
        # `catch` hands back the raw Erlang reason, and the raw atom cannot say
        # *which* function failed to match, so normalise first — for `:error`
        # only; `Exception.normalize/3` returns `:throw` and `:exit` reasons
        # unchanged, which is fine because neither can be an unmatched event.
        normalized = Exception.normalize(kind, reason, __STACKTRACE__)

        record_receipt(receipt, state, before_assigns, before_tree, started,
          error: {kind, normalized},
          stacktrace: __STACKTRACE__
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      {:noreply, socket} ->
        finish_event(socket, state, receipt, before_assigns, before_tree, started)

      {:reply, _payload, socket} ->
        finish_event(socket, state, receipt, before_assigns, before_tree, started)
    end
  end

  def handle_call(:get_socket, _from, state), do: {:reply, state.socket, state}

  def handle_call(:discard_persisted_state, _from, state) do
    if state.module.__mob_persist__(), do: Mob.ScreenState.delete(state.module, state.socket)
    {:reply, :ok, Map.put(state, :persist_on_terminate, false)}
  end

  def handle_call(:get_tree, _from, state) do
    {:reply, state.module.render(state.socket.assigns), state}
  end

  def handle_call({:render_sync, transition}, _from, state) do
    {:reply, :ok, %{state | socket: paint(state, transition, :sync)}}
  end

  def handle_call({:render_sync, transition, activation_token}, _from, state) do
    {:reply, :ok, %{state | socket: paint(state, transition, :sync, activation_token)}}
  end

  defp finish_event(socket, state, receipt, before_assigns, before_tree, started) do
    # The handler's own assigns, captured before the paint. `do_paint/5` runs
    # `ensure_safe_area/3`, which writes `:safe_area` the first time insets
    # resolve and on rotation — reading assigns afterwards reported
    # `:assigns_changed` for an inert handler and blamed `render/1` for a
    # framework-written assign.
    handler_assigns = socket.assigns
    # Read before `reply_after_callback/2` clears it. A handler that navigated
    # is the reason this screen does not paint, so without this the receipt
    # infers "nothing happened" from an absence the framework created on
    # purpose — and calls a screen push `:inert`.
    #
    # This records the *request*. Whether the router honours it is not
    # observable from here, which is why the stage and its verdict are named
    # for the ask rather than the outcome.
    navigated? = not is_nil(socket.__mob__.nav_action)

    {:reply, reply, new_state} = reply_after_callback(socket, state)

    record_receipt(receipt, new_state, before_assigns, before_tree, started,
      navigated: navigated?,
      after_assigns: handler_assigns
    )

    {:reply, reply, new_state}
  end

  # Stages are derived from what actually changed, not from what ran. `handled`
  # is the only one the callback itself proves; every later stage is a
  # comparison the screen makes for itself.
  #
  # Wrapped: this runs after a successful event, and a diagnostic that can crash
  # the screen it is observing is worse than no diagnostic. In the `catch`
  # clause it would be worse still — it would replace the handler's exception
  # with its own and destroy the report the feature exists to produce.
  defp record_receipt(receipt, state, before_assigns, before_tree, started, opts) do
    build_receipt(receipt, state, before_assigns, before_tree, started, opts)
    |> Mob.Agent.Receipts.record()
  rescue
    _ -> receipt
  catch
    _, _ -> receipt
  end

  defp build_receipt(receipt, state, before_assigns, before_tree, started, opts) do
    error = Keyword.get(opts, :error)
    navigated? = Keyword.get(opts, :navigated, false)
    observable? = state.render_mode == :render
    after_assigns = Keyword.get(opts, :after_assigns, state.socket.assigns)
    after_frame = Map.get(state.socket.__mob__, :last_frame)

    unmatched? = Mob.Agent.Receipt.unmatched_event?(error, state.module)

    stages =
      [:dispatched]
      |> add_if(unmatched?, :unhandled)
      |> add_if(is_nil(error) and not observable?, :unobservable)
      |> add_if(is_nil(error), :handled)
      |> add_if(is_nil(error) and after_assigns !== before_assigns, :assigns_changed)
      |> add_if(is_nil(error) and navigated?, :navigation_requested)
      # A frame is only observable in :render mode — `do_paint/5`'s :no_render
      # clause never touches :last_frame, so comparing it there would report
      # "the render function ignored your assigns" for every action.
      |> add_if(is_nil(error) and observable? and after_frame != before_tree, :frame_changed)
      # Every event paint runs with skippable: false, so a paint that happened
      # always handed a frame over. `navigated?` is exactly the case where no
      # paint happened.
      |> add_if(is_nil(error) and observable? and not navigated?, :committed)

    %{
      receipt
      | stages: stages,
        handler: if(unmatched?, do: nil, else: {state.module, :handle_event, 3}),
        after_frame_fingerprint: after_frame,
        error: summarize(error, Keyword.get(opts, :stacktrace, [])),
        elapsed_us: System.monotonic_time(:microsecond) - started
    }
  end

  defp add_if(list, true, stage), do: list ++ [stage]
  defp add_if(list, false, _stage), do: list

  defp summarize(nil, _stacktrace), do: nil

  defp summarize({kind, reason}, stacktrace),
    do: Mob.Agent.Receipt.summarize_error(kind, reason, stacktrace)

  @impl GenServer
  def handle_cast({:render, transition}, state) do
    {:noreply, %{state | socket: paint(state, transition)}}
  end

  def handle_cast({:render, transition, activation_token}, state) do
    {:noreply, %{state | socket: paint(state, transition, :async, activation_token)}}
  end

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

  # The window now exists, so the insets this screen is holding may be a
  # placeholder taken before it did. Drop the confirmation and repaint; the
  # paint re-reads. Intercepted here rather than forwarded to the user's
  # handle_info, which has no reason to know about windows.
  #
  # Without this the correction had no trigger: `ensure_safe_area/3` is only
  # reached from a paint, and nothing repaints when a scene connects. A screen
  # that painted during a prewarmed launch would show its placeholder as the
  # user's first visible frame and keep it until they interacted.
  @impl GenServer
  def handle_info({:mob_window, :connected}, state) do
    socket = Mob.Socket.put_mob(state.socket, :safe_area_confirmed, false)
    state = %{state | socket: socket}
    {:noreply, %{state | socket: do_paint(state, :none, :async, nil, false)}}
  end

  # Periodic state sync — intercepted before the user's handle_info so the
  # screen module never sees this internal message.
  def handle_info(:__mob_sync_state__, state) do
    if Map.get(state, :persist_on_terminate, true) and state.module.__mob_persist__() do
      Mob.ScreenState.dump(state.module, state.socket)
      schedule_state_sync()
    end

    {:noreply, state}
  end

  # Android file/camera/photo/scan results arrive JSON-encoded; decode and
  # re-dispatch as the user-facing event tuple.
  def handle_info({:mob_file_result, event, sub, json_binary}, state) do
    handle_info(decode_file_result(event, sub, json_binary), state)
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

  # Trapping exits means a linked task's crash arrives here as a message
  # instead of killing this screen. Passing it to the user's handle_info would
  # silently swallow it — the default clause ignores unknown messages — so say
  # so, then let the screen see it in case it wants to react.
  def handle_info({:EXIT, pid, reason} = message, state)
      when reason != :normal and pid != :erlang.map_get(:owner, state) do
    Logger.warning(
      "[mob] #{inspect(state.module)}: linked process #{inspect(pid)} exited: " <>
        "#{inspect(reason)}"
    )

    forward(message, state)
  end

  def handle_info(message, state), do: forward(message, state)

  @impl GenServer
  def terminate(reason, state) do
    if Map.get(state, :persist_on_terminate, true) and state.module.__mob_persist__() do
      Mob.ScreenState.dump(state.module, state.socket)
    end

    result = state.module.terminate(reason, state.socket)

    # MOB-156. A screen stopping is when a leaked component becomes visible —
    # its owner is gone and nothing else is going to notice. Run after the
    # user's terminate/2 so their cleanup has happened first, and wrapped
    # because a diagnostic must never be the reason a teardown fails.
    #
    # This screen is still alive here — it is running its own terminate/2 — so a
    # check never sees this screen's own components. What it sees is what an
    # earlier screen left behind. Confirmation across samples is what keeps that
    # from reporting components merely mid-reap.
    try do
      Mob.Invariant.run(:on_screen_stop, %{screen: self(), screen_module: state.module})
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    result
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp forward(message, state) do
    {:noreply, socket} = state.module.handle_info(message, state.socket)

    case take_nav_action(socket) do
      {nil, socket} ->
        state = %{state | socket: socket}
        {:noreply, %{state | socket: repaint_if_changed(state)}}

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

  defp paint(state, transition, mode \\ :async, activation_token \\ nil),
    do: do_paint(state, transition, mode, activation_token, false)

  # The ONLY path that may skip. Everything else — mount, activation, every
  # navigation, hot reload, a :sync caller — paints unconditionally.
  #
  # That restriction is what makes this safe rather than clever. The router
  # paints with `transition: :none` on every push, pop and reset (the transition
  # rides on the activation, not the paint), and the activation token is
  # conditional on `activation_frame_supported?/0`, the hot-code-push fallback.
  # So neither the transition nor the token is a reliable "this is a navigation"
  # signal. Popping back to a resident screen whose tree has not changed would
  # otherwise skip its repaint and leave the pushed screen's tree on display.
  #
  # It also sidesteps Mob.Sender dropping frames for non-active screens: a
  # background screen's fingerprint may describe a tree that was never
  # committed, but it cannot act on that, because becoming active goes through
  # the router and therefore through an unconditional paint.
  defp repaint_if_changed(state), do: do_paint(state, :none, :async, nil, true)

  defp do_paint(%{render_mode: :no_render} = state, _transition, _mode, _token, _skippable),
    do: state.socket

  defp do_paint(state, transition, mode, activation_token, skippable) do
    socket = ensure_safe_area(state.socket, state.socket.__mob__.platform, state.nif)
    platform = socket.__mob__.platform
    list_renderers = Map.get(socket.__mob__, :list_renderers, %{})

    Mob.RenderStats.start_frame(state.module, transition)

    raw = Mob.RenderStats.time(:render_us, fn -> state.module.render(socket.assigns) end)

    {tree, active_component_keys} =
      Mob.RenderStats.time(:expand_us, fn ->
        raw
        # Third expansion pass FIRST: pure-Elixir composites may themselves emit
        # <List> nodes / native_view components for the later passes.
        |> Mob.Composite.expand(self())
        |> Mob.List.expand(list_renderers, self())
        |> Mob.Component.expand(self(), platform)
      end)

    Mob.RenderStats.time(:reconcile_us, fn ->
      Mob.ComponentRegistry.reconcile(self(), active_component_keys)
    end)

    fingerprint = fingerprint(tree)

    if skippable and Map.get(socket.__mob__, :last_frame) == fingerprint do
      # The platform is already showing exactly this tree. Everything below —
      # clear_taps, a register_tap per interactive node, serialisation, set_root
      # and the native tree rebuild — would reproduce what is on screen.
      #
      # Not a rare case: forward/2 repaints after EVERY handle_info, whether or
      # not the message changed anything, so a 30 Hz scroll handler drove 30 full
      # renders per second. It also fed a feedback loop — each render calls
      # clear_taps, which zeroes the per-handle throttle state, so the native
      # throttle was defeated by the very events it throttled. MOB-134 measured
      # 68 vs 69 events for a throttled and an unthrottled handler delivered to a
      # screen, against 33 vs 5 for the same handlers delivered to a plain
      # process.
      #
      # Recorded as an uncommitted frame rather than dropped silently, so the
      # meter says how many repaints were skipped.
      # Tagged. drop_frame/1 already records uncommitted frames — superseded,
      # inactive, discarded at a navigation — and skips now vastly outnumber all
      # of them: at 30 Hz the 500-entry ring is entirely no-op skips within ~17
      # seconds, evicting exactly the committed frames and navigation-boundary
      # drops MOB-124 is trying to measure. The reason keeps them separable.
      Mob.RenderStats.take_frame()
      |> then(fn
        nil -> nil
        frame -> Map.put(frame, :reason, :unchanged)
      end)
      |> Mob.RenderStats.drop_frame()

      socket
    else
      Mob.RenderStats.hand_off(state.ref)

      if activation_token && function_exported?(Mob.Sender, :render, 6) do
        Mob.Sender.render(state.ref, tree, platform, state.nif, transition, activation_token)
      else
        Mob.Sender.render(state.ref, tree, platform, state.nif, transition)
      end

      if mode == :sync, do: Mob.Sender.sync(:infinity)

      socket
      |> Mob.Socket.put_mob(:last_frame, fingerprint)
      |> Mob.Socket.put_root_view(:json_tree)
    end
  end

  # What the next frame is compared against.
  #
  # Includes the theme, because the tree alone is not enough: token resolution
  # (`:on_background` -> ARGB), the font default, the type scale, spacing and
  # radii all happen in Mob.Renderer, which runs DOWNSTREAM of this comparison.
  # A screen written the idiomatic way — `text_color: :on_background` —
  # produces a byte-identical tree before and after `Mob.Theme.set/1`, so
  # comparing the tree alone skips the repaint and leaves the old palette on
  # screen. Worse than nothing: Mob.Theme.set/1 pushes the resolved palette to
  # native itself, so theme-driven surfaces would follow while every
  # explicitly-tokened node did not — a half-themed screen.
  #
  # A hash rather than the tree itself. Retaining the expanded tree per live
  # screen roughly doubles steady-state footprint on a list screen — Mob.List
  # materialises a wrapper plus the rendered row per item — for screens the user
  # cannot even see, and it would be copied across process boundaries by
  # Mob.Screen.Server.socket/1, i.e. over dist on every Mob.Test.assigns/1.
  # The trade, stated accurately: ~1 in 4 billion per message that a frame
  # collides with the previous one and its repaint is skipped. It is NOT
  # self-healing. On a collision `last_frame` still holds the OLD tree's hash
  # while the new tree is what render produces, so every subsequent frame
  # rendering that same new tree — the normal case, since changed state stays
  # changed — hashes identically and is skipped again. The screen stays wrong
  # until the tree moves to a third value, which on a settled screen can mean
  # until the next user interaction. Any interaction produces one, so it
  # recovers in practice, but "one dropped frame" would be the wrong summary.
  defp fingerprint(tree), do: :erlang.phash2({tree, Mob.Theme.current()}, 4_294_967_296)

  @zero_insets %{top: 0.0, right: 0.0, bottom: 0.0, left: 0.0}

  # The `:safe_area` assign is always present — screens are documented to read
  # `assigns.safe_area` directly, so it must never be missing — but a reading
  # taken before iOS has a window is a placeholder, not an answer, and must not
  # be kept. `nif.safe_area()` answers `:no_window` for exactly that case.
  #
  # It matters because the BEAM can reach here before a window exists: a
  # background launch connects no window scene at all, and an iOS 15+ prewarmed
  # launch runs `didFinishLaunchingWithOptions:` long before the user taps the
  # icon. `ensure_safe_area/3` used to stop asking as soon as the key existed,
  # so a placeholder taken then left the root screen laid out under the notch
  # and home indicator for the rest of its life.
  defp initial_safe_area(:render, nif), do: read_safe_area(nif)
  defp initial_safe_area(_mode, _nif), do: {@zero_insets, :placeholder}

  defp read_safe_area(nif) do
    case nif.safe_area() do
      {t, r, b, l} ->
        {%{top: t, right: r, bottom: b, left: l}, :confirmed}

      :no_window ->
        {@zero_insets, :placeholder}

      other ->
        # Android answers `:error` when it cannot attach to the JVM, and a
        # future platform may answer something else again. Treating an
        # unrecognised reply as a placeholder means a screen degrades to zeros
        # and retries, rather than dying in init/1 with a CaseClauseError.
        Logger.warning("[mob] unexpected safe_area/0 result: #{inspect(other)}")
        {@zero_insets, :placeholder}
    end
  end

  defp ensure_safe_area(socket, platform, nif) do
    cond do
      platform != :ios ->
        Mob.Socket.assign_new(socket, :safe_area, fn -> @zero_insets end)

      # Confirmed readings are not re-read on every paint — each read is a hop
      # to the main thread. They are not permanent either: insets DO change
      # under a screen (rotation, a resized scene), so `{:mob_window,
      # :connected}` clears this flag and the next paint asks again.
      socket.__mob__[:safe_area_confirmed] ->
        socket

      true ->
        {insets, status} = read_safe_area(nif)

        socket
        |> Mob.Socket.assign(:safe_area, insets)
        |> Mob.Socket.put_mob(:safe_area_confirmed, status == :confirmed)
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

  # Android file/camera/photo/scan results arrive JSON-encoded from native.
  defp decode_file_result(event, sub, json_binary) do
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

  defp schedule_state_sync do
    Process.send_after(self(), :__mob_sync_state__, @state_sync_interval_ms)
  end
end
