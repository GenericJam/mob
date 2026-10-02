defmodule Mob.Sender do
  @moduledoc """
  The only process permitted to call the render NIFs.

  ## Why this is forced

  Not a style choice — the native tap registry requires it. From
  `ios/mob_nif.m` (the Android side in `android/jni/mob_nif.zig` is the same
  shape):

      static TapHandle *tap_tables[2];   // grown on demand, see MOB-133
      static int tap_active = 0;
      static int tap_build_count = 0;   // cursor into the BUILDING table

  `clear_taps` prepares the inactive table and resets the cursor, `register_tap`
  appends at `tap_build_count++`, and `set_root` swaps the tables atomically.
  The double buffering makes a *concurrent reader* safe — a drag or scroll event
  arriving mid-render still resolves against the last committed table. It does
  nothing for concurrent *writers*: there is one global build cursor, so two
  renders in flight interleave their handles into the same building table, and
  whichever reaches `set_root` first commits a table holding both screens'
  handles while the other screen's tree is never committed at all.

  So `clear_taps -> register_tap* -> set_root` is one indivisible sequence, and
  serialising it through a single process is the only thing that keeps it that
  way once more than one screen is live (MOB-112).

  ## Coalescing falls out of it

  Because renders are queued rather than executed by the caller, the sender can
  look at what is waiting and commit only what matters:

  * for a given screen, only the newest tree is committed — a screen that
    re-renders three times before the sender gets to it produces one commit, not
    three
  * a tree for a screen that is not active is dropped, never committed

  That second point is what lets an inactive tab keep its state without
  rendering. It is also why switching stacks re-renders: the incoming screen's
  tree is produced fresh at switch time rather than replayed from a queue.

  ## Ordering

  `render/5` is asynchronous, so a caller that needs the commit to have landed
  calls `sync/1`, which performs the flush itself rather than waiting for the
  self-sent one.

  It has to. `send(self(), :flush)` during the render cast appends to the *back*
  of the mailbox — behind a `sync/1` the caller has already queued — so a
  `sync/1` that merely replied would return before the frame was committed.
  Mailbox order is the wrong tool here, and it looks like the right one.

  `Mob.Router` uses an activation-frame token before asking a screen to paint.
  Activation is synchronous and carries the navigation transition; only the
  router-requested paint bearing that token may cross the boundary. A timer
  repaint that began while the screen was parked is therefore dropped even if
  its cast reaches the sender after activation.

  `Mob.Router` uses `sync/1` on its `handle_call` paths to keep the guarantee
  `Mob.Test` documents for the synchronous navigation helpers. Note the ordering
  guarantee only covers renders cast by the *calling* process; the BEAM promises
  nothing about the relative order of sends from different processes.

  ## One active screen per window scene

  Every window scene shows its own screen (MOB-245), so "the active screen" is
  per scene. The top-level `active`, `reserved_transition`, `activation_gate`
  and `active_screen` fields describe the unbound scene (`nil`): the primary
  router's, i.e. every single-window app's. `scenes` holds the same four for
  each scene a router is bound to, keyed by scene id. A flush commits the
  newest tree of every scene's active screen, each into its own scene. See
  `decisions/2026-10-02-one-router-per-window-scene.md`.
  """

  use GenServer

  require Logger

  @typedoc """
  Identifies which screen a tree belongs to — one per live screen since
  MOB-112, not one per navigation stack. Screens below the top of a stack are
  live processes that repaint, so a stack-wide key would let a background
  screen's tree commit over the foreground one.
  """
  @type screen_ref :: reference() | atom()

  @typedoc """
  A navigation transition, optionally tagged as replacing the stack.

  The bare atom is the wire vocabulary the platforms understand. The
  `{transition, :replace}` form additionally says the outgoing screen's process
  is gone and its retained view tree can be released once the animation ends;
  `Mob.Renderer` unwraps it and still sends a plain atom.

  Only `activate/2` and `activate_frame/2` take this form. `render/5,6` are
  always called with a plain atom; the reserved transition is substituted into
  a pending render inside `handle_cast/2`, after the public function has been
  called, so the tuple never crosses that boundary.
  """
  @type transition :: atom() | {atom(), :replace}

  @typedoc "A window scene id (`UISceneSession.persistentIdentifier`), or `nil` for the unbound scene."
  @type scene :: String.t() | nil

  defstruct active: nil,
            pending: %{},
            reserved_transition: nil,
            activation_gate: nil,
            frames: %{},
            active_screen: nil,
            scenes: %{}

  @slot_keys [:active, :reserved_transition, :activation_gate, :active_screen]
  @empty_slot %{active: nil, reserved_transition: nil, activation_gate: nil, active_screen: nil}

  @doc "Start the sender. Named, so there is exactly one."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether the sender is running. Renders are silently dropped when it is not."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @doc """
  Start the sender if it is not already running.

  `Mob.App.start/0` starts it on the normal boot path, but a screen can be
  started without going through `Mob.App` — `liveview_notes.md` documents
  exactly that — and a missing sender fails in the worst possible way: renders
  are casts, so they vanish silently and the app shows a blank screen with no
  log, until the first synchronous render exits `:noproc`. `Mob.Router` calls
  this so no render path can reach that state.

  Deliberately unlinked. The caller is usually a screen, and a screen crash must
  not take down the process every other screen renders through.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    if running?() do
      :ok
    else
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  @doc """
  Declare which screen's trees may be committed.

  A render for any other screen is dropped. `Mob.Router` sets this;
  MOB-113's router takes it over.
  """
  @spec set_active(screen_ref()) :: :ok
  def set_active(ref), do: GenServer.cast(__MODULE__, {:set_active, ref})

  @doc """
  Activate a screen and reserve its navigation transition for the next frame.

  Unlike `set_active/1`, this call is synchronous. The router uses it at the
  navigation boundary so paints sent by different screen processes cannot be
  observed before the transition intent. The first tree for `ref` consumes the
  reservation; later ordinary repaints remain `:none`.

  A `:none` transition only activates the screen and creates no reservation.
  """
  @spec activate(screen_ref(), transition()) :: :ok
  def activate(ref, transition), do: activate(ref, transition, nil)

  @doc """
  `activate/2` for the screen a router bound to window scene `scene` shows.
  `nil` is the unbound scene, i.e. `activate/2`.
  """
  @spec activate(screen_ref(), transition(), scene()) :: :ok
  def activate(ref, transition, scene) do
    if running?(), do: GenServer.call(__MODULE__, {:activate, ref, transition, scene}), else: :ok
  end

  @doc false
  @spec activate_frame(screen_ref(), transition()) :: reference() | nil
  def activate_frame(ref, transition), do: activate_frame(ref, transition, nil)

  @doc false
  @spec activate_frame(screen_ref(), transition(), scene()) :: reference() | nil
  def activate_frame(ref, transition, scene) do
    if running?() do
      GenServer.call(__MODULE__, {:activate_frame, ref, transition, scene})
    end
  end

  @doc """
  Forget window scene `scene`: its pending tree is dropped and nothing is
  committed to it again until a screen is activated there. `Mob.Scenes` calls
  this when it stops the router of a scene that went away.
  """
  @spec deactivate_scene(String.t()) :: :ok
  def deactivate_scene(scene) when is_binary(scene) do
    if running?(), do: GenServer.cast(__MODULE__, {:deactivate_scene, scene}), else: :ok
  end

  @doc false
  # The router names the module of the screen it is about to activate, so a
  # committed frame can say which screen it came from (the :after_first_render
  # hook's argument). Sent before the activation from the same process, so it
  # arrives first. Only the active ref's trees are committed, so one pair is
  # all the sender needs to hold.
  @spec note_active_screen(screen_ref(), module()) :: :ok
  def note_active_screen(ref, module), do: note_active_screen(ref, module, nil)

  @doc false
  @spec note_active_screen(screen_ref(), module(), scene()) :: :ok
  def note_active_screen(ref, module, scene) do
    if running?(),
      do: GenServer.cast(__MODULE__, {:active_screen, ref, module, scene}),
      else: :ok
  end

  @doc """
  Queue `tree` for commit on behalf of screen `ref`.

  Returns immediately. The tree is committed only if `ref` is active when the
  sender gets to it, and only if no newer tree for `ref` has arrived by then.
  """
  @spec render(screen_ref(), map(), atom(), module() | atom(), atom()) :: :ok
  def render(ref, tree, platform, nif, transition) do
    GenServer.cast(__MODULE__, {:render, ref, tree, platform, nif, transition})
  end

  @doc false
  @spec render(screen_ref(), map(), atom(), module() | atom(), atom(), reference() | nil) :: :ok
  def render(ref, tree, platform, nif, transition, activation_token) do
    GenServer.cast(
      __MODULE__,
      {:render, ref, tree, platform, nif, transition, activation_token}
    )
  end

  @doc """
  Block until every render queued before this call has been committed or
  dropped.

  "Queued before" means cast by the *calling* process — the BEAM orders sends
  between a given pair of processes and says nothing about sends from different
  ones. Committed *or dropped*: a return of `:ok` does not promise the caller's
  own tree reached the screen, only that the sender has caught up. A tree for a
  screen that is not active is dropped, and `sync/1` returns `:ok` all the same.
  """
  @spec sync(timeout()) :: :ok
  def sync(timeout \\ 5000), do: GenServer.call(__MODULE__, :sync, timeout)

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    {:ok, %__MODULE__{active: Keyword.get(opts, :active)}}
  end

  # Drop a queued tree AND record its frame. Both activation paths throw a
  # pending tree away, and the frame paired with it measured real BEAM work that
  # produced no pixels — which is exactly what `committed: false` is for. Losing
  # it here would make the meter undercount dropped frames at navigation
  # boundaries, the transitions MOB-124 is most interested in.
  defp discard_pending(pending, ref) do
    case Map.pop(pending, ref) do
      {{_tree, _platform, _nif, _transition, frame}, rest} ->
        Mob.RenderStats.drop_frame(frame)
        rest

      # Anything else is a pending entry written by a previous version of this
      # module. mob's dev loop reloads code onto a running BEAM, so the sender
      # can meet state it did not write; crashing here would take down the one
      # process every screen renders through.
      {_other, rest} ->
        rest
    end
  end

  @impl GenServer
  # The three-element forms are what a router started before MOB-245 sends
  # (hot code push); they mean the unbound scene.
  def handle_call({:activate, ref, transition}, from, state),
    do: handle_call({:activate, ref, transition, nil}, from, state)

  def handle_call({:activate, ref, transition, scene}, _from, state) do
    reserved_transition = if transition == :none, do: nil, else: {ref, transition}

    # An inactive screen may have queued a repaint just before activation.
    # That tree predates the navigation boundary and must not become the first
    # frame of the newly active screen; the router requests a fresh paint next.
    pending = discard_pending(state.pending, ref)

    slot = %{slot(state, scene) | active: ref, reserved_transition: reserved_transition}
    {:reply, :ok, state |> Map.put(:pending, pending) |> put_slot(scene, slot)}
  end

  def handle_call({:activate_frame, ref, transition}, from, state),
    do: handle_call({:activate_frame, ref, transition, nil}, from, state)

  def handle_call({:activate_frame, ref, transition, scene}, _from, state) do
    token = make_ref()

    slot = %{
      slot(state, scene)
      | active: ref,
        reserved_transition: nil,
        activation_gate: {ref, token, transition}
    }

    state =
      state
      |> Map.put(:pending, discard_pending(state.pending, ref))
      |> put_slot(scene, slot)

    {:reply, token, state}
  end

  def handle_call(:sync, _from, state) do
    # Flush here rather than just replying. The `:flush` this render self-sent
    # lands at the BACK of the mailbox, which is behind a `sync` the caller has
    # already queued — replying without flushing would return before the frame
    # was committed, which is the one thing this function promises not to do.
    {:reply, :ok, flush(state)}
  end

  @impl GenServer
  def handle_cast({:set_active, ref}, state) do
    {:noreply, %{state | active: ref, reserved_transition: nil}}
  end

  def handle_cast({:active_screen, ref, module}, state),
    do: handle_cast({:active_screen, ref, module, nil}, state)

  def handle_cast({:active_screen, ref, module, scene}, state) do
    {:noreply, put_slot(state, scene, %{slot(state, scene) | active_screen: {ref, module}})}
  end

  def handle_cast({:deactivate_scene, scene}, state) do
    {slot, scenes} = Map.pop(scenes(state), scene)
    pending = if slot, do: discard_pending(state.pending, slot.active), else: state.pending
    {:noreply, state |> Map.put(:scenes, scenes) |> Map.put(:pending, pending)}
  end

  # Staged, not paired: the screen process casts its stats immediately before the
  # render they describe, so this frame belongs to the very next `:render` for
  # `ref`. Pairing happens there, not here, so that a frame and the tree it
  # measured travel together through coalescing and flush.
  def handle_cast({:render_stats, ref, frame}, state) do
    # A frame already staged for this ref described a render that never arrived.
    Mob.RenderStats.drop_frame(Map.get(state.frames, ref))
    {:noreply, %{state | frames: Map.put(state.frames, ref, frame)}}
  end

  def handle_cast({:render, ref, tree, platform, nif, transition}, state) do
    handle_cast({:render, ref, tree, platform, nif, transition, nil}, state)
  end

  def handle_cast({:render, ref, tree, platform, nif, transition, activation_token}, state) do
    scene = scene_of(state, ref)
    slot = slot(state, scene)
    {frame, frames} = Map.pop(state.frames, ref)
    state = %{state | frames: frames}

    case slot.activation_gate do
      {^ref, ^activation_token, reserved} ->
        transition = if transition == :none, do: reserved, else: transition
        pending = put_pending(state.pending, ref, {tree, platform, nif, transition, frame})
        send(self(), :flush)

        {:noreply,
         state |> Map.put(:pending, pending) |> put_slot(scene, %{slot | activation_gate: nil})}

      {^ref, _expected_token, _reserved} ->
        # This render began before the router activated the screen. The router's
        # tokened paint follows it from the same screen process, so dropping it
        # prevents a stale target frame from consuming the navigation boundary.
        # Its frame goes with it, or it would be resumed against a later tree.
        Mob.RenderStats.drop_frame(frame)
        {:noreply, state}

      _no_gate_for_this_screen ->
        # Overwrite rather than append: a newer tree for the same screen
        # supersedes the one waiting, which is the whole point of queueing
        # here. The transition is the exception — it describes the navigation
        # animation for this frame, not the frame's content, so a push
        # superseded by an ordinary re-render still has to animate as a push or
        # the transition is silently swallowed.
        {transition, reserved_transition} =
          take_transition(state.pending, slot.reserved_transition, ref, transition)

        pending = put_pending(state.pending, ref, {tree, platform, nif, transition, frame})
        send(self(), :flush)

        {:noreply,
         state
         |> Map.put(:pending, pending)
         |> put_slot(scene, %{slot | reserved_transition: reserved_transition})}
    end
  end

  # ── Scene slots ───────────────────────────────────────────────────────────

  # The unbound scene's slot is the top-level fields, so a single-window app's
  # state is shaped exactly as before MOB-245. Map.get throughout: a sender
  # started before a field existed (hot code push) lacks it.
  defp slot(state, nil), do: Map.new(@slot_keys, &{&1, Map.get(state, &1)})
  defp slot(state, scene), do: Map.get(scenes(state), scene, @empty_slot)

  defp put_slot(state, nil, slot), do: Map.merge(state, slot)

  defp put_slot(state, scene, slot),
    do: Map.put(state, :scenes, Map.put(scenes(state), scene, slot))

  defp scenes(state), do: Map.get(state, :scenes, %{})

  # Which scene a screen ref renders into: the bound scene whose slot names it
  # (active, gated or holding its reserved transition), else the unbound one.
  # A screen belongs to one router, and a router to one scene, so at most one
  # slot can name a ref.
  defp scene_of(state, ref) do
    Enum.find_value(scenes(state), fn {scene, slot} -> if names?(slot, ref), do: scene end)
  end

  defp names?(%{active: ref}, ref), do: true
  defp names?(%{activation_gate: {ref, _token, _transition}}, ref), do: true
  defp names?(%{reserved_transition: {ref, _transition}}, ref), do: true
  defp names?(_slot, _ref), do: false

  # A superseded tree's frame is real work that was paid for but never shown.
  defp put_pending(pending, ref, payload) do
    case Map.fetch(pending, ref) do
      {:ok, {_tree, _platform, _nif, _transition, superseded}} ->
        Mob.RenderStats.drop_frame(superseded)

      :error ->
        :ok
    end

    Map.put(pending, ref, payload)
  end

  defp take_transition(pending, {ref, reserved}, ref, :none),
    do: {carry_transition(pending, ref, reserved), nil}

  defp take_transition(pending, {ref, _reserved}, ref, transition),
    do: {carry_transition(pending, ref, transition), nil}

  defp take_transition(pending, reserved, ref, transition),
    do: {carry_transition(pending, ref, transition), reserved}

  defp carry_transition(pending, ref, :none) do
    case Map.fetch(pending, ref) do
      {:ok, {_tree, _platform, _nif, superseded, _frame}} -> superseded
      :error -> :none
    end
  end

  defp carry_transition(_pending, _ref, transition), do: transition

  @impl GenServer
  def handle_info(:flush, state), do: {:noreply, flush(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp flush(state) do
    # One commit per scene: the newest tree of the screen active there.
    actives =
      [{nil, slot(state, nil)} | Enum.to_list(scenes(state))]
      |> Enum.reject(fn {_scene, slot} -> is_nil(slot.active) end)

    rest =
      Enum.reduce(actives, state.pending, fn {scene, slot}, pending ->
        case Map.pop(pending, slot.active) do
          {{tree, platform, nif, transition, frame}, rest} ->
            Mob.RenderStats.resume_frame(frame)
            commit({tree, platform, nif, transition}, active_screen(slot), scene)
            rest

          {_nothing_or_pre_reload_shape, rest} ->
            rest
        end
      end)

    # Everything else waiting belongs to a screen that is not active. Dropping
    # it is deliberate: by the time such a screen becomes active it will have
    # re-rendered, so committing a queued tree would only show a stale frame.
    # Their BEAM-side cost was still paid, so record it rather than losing it.
    Enum.each(rest, fn
      {_ref, {_t, _p, _n, _tr, frame}} -> Mob.RenderStats.drop_frame(frame)
      {_ref, _pre_reload_shape} -> :ok
    end)

    # Staged frames survive a flush. The render cast that pairs a staged frame
    # with its tree may still be in the mailbox behind the `:flush` message, so
    # clearing here would throw away a frame whose render is about to arrive.
    #
    # They are not self-limiting, though. A screen process killed between
    # `hand_off/1` and `Mob.Sender.render/5` — a narrow window, but a real one —
    # leaves an entry no later cast will ever claim, and nothing else removes it.
    # Sweeping by age bounds the map and records the work rather than losing it.
    %{state | pending: %{}, frames: sweep_stale(state.frames)}
  end

  defp active_screen(%{active: ref, active_screen: {ref, module}}), do: module
  defp active_screen(_slot), do: nil

  # A staged frame is claimed by the render cast that follows it from the same
  # process, so anything still waiting after this long belongs to a screen that
  # is never going to send one.
  @stale_frame_us 5_000_000

  defp sweep_stale(frames) when map_size(frames) == 0, do: frames

  defp sweep_stale(frames) do
    cutoff = System.monotonic_time(:microsecond) - @stale_frame_us

    Enum.reduce(frames, frames, fn {ref, frame}, acc ->
      if is_map(frame) and Map.get(frame, :started, cutoff) < cutoff do
        Mob.RenderStats.drop_frame(frame)
        Map.delete(acc, ref)
      else
        acc
      end
    end)
  end

  # The unbound scene renders through the four-argument call, exactly as before
  # scenes existed.
  defp commit({tree, platform, nif, transition}, screen, scene) do
    result =
      if scene,
        do: Mob.Renderer.render(tree, platform, nif, transition, scene),
        else: Mob.Renderer.render(tree, platform, nif, transition)

    # Here, not in the router: its first paint is a cast, so the root screen's
    # render/1 has not run when the router's init returns. A plugin that ends
    # an update's probation on this hook (mob_deliver) must not hear "stable"
    # from a screen whose render raises on every attempt.
    Mob.Router.Hooks.after_first_render(screen)
    result
  rescue
    error ->
      # A render that raises must not take the sender down with it: every other
      # screen renders through this process, so losing it freezes the whole UI.
      Logger.error("[mob] render failed: " <> Exception.format(:error, error, __STACKTRACE__))
      :error
  end
end
