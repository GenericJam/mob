defmodule Mob.Sender do
  @moduledoc """
  The only process permitted to call the render NIFs.

  ## Why this is forced

  Not a style choice — the native tap registry requires it. From
  `ios/mob_nif.m` (the Android side in `android/jni/mob_nif.zig` is the same
  shape):

      static TapHandle tap_tables[2][MAX_TAP_HANDLES];
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

  defstruct active: nil, pending: %{}, reserved_transition: nil, activation_gate: nil

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
  @spec activate(screen_ref(), atom()) :: :ok
  def activate(ref, transition) do
    if running?(), do: GenServer.call(__MODULE__, {:activate, ref, transition}), else: :ok
  end

  @doc false
  @spec activate_frame(screen_ref(), atom()) :: reference() | nil
  def activate_frame(ref, transition) do
    if running?() do
      GenServer.call(__MODULE__, {:activate_frame, ref, transition})
    end
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

  @impl GenServer
  def handle_call({:activate, ref, transition}, _from, state) do
    reserved_transition = if transition == :none, do: nil, else: {ref, transition}

    # An inactive screen may have queued a repaint just before activation.
    # That tree predates the navigation boundary and must not become the first
    # frame of the newly active screen; the router requests a fresh paint next.
    pending = Map.delete(state.pending, ref)

    {:reply, :ok,
     %{state | active: ref, pending: pending, reserved_transition: reserved_transition}}
  end

  def handle_call({:activate_frame, ref, transition}, _from, state) do
    token = make_ref()

    state =
      state
      |> Map.put(:active, ref)
      |> Map.put(:pending, Map.delete(state.pending, ref))
      |> Map.put(:reserved_transition, nil)
      |> Map.put(:activation_gate, {ref, token, transition})

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

  def handle_cast({:render, ref, tree, platform, nif, transition}, state) do
    handle_cast({:render, ref, tree, platform, nif, transition, nil}, state)
  end

  def handle_cast(
        {:render, ref, tree, platform, nif, transition, activation_token},
        %{activation_gate: {ref, expected_token, reserved}} = state
      ) do
    if activation_token == expected_token do
      transition = if transition == :none, do: reserved, else: transition
      pending = Map.put(state.pending, ref, {tree, platform, nif, transition})
      send(self(), :flush)
      {:noreply, %{state | pending: pending, activation_gate: nil}}
    else
      # This render began before the router activated the screen. The router's
      # tokened paint follows it from the same screen process, so dropping it
      # prevents a stale target frame from consuming the navigation boundary.
      {:noreply, state}
    end
  end

  def handle_cast({:render, ref, tree, platform, nif, transition, _activation_token}, state) do
    # Overwrite rather than append: a newer tree for the same screen supersedes
    # the one waiting, which is the whole point of queueing here. The transition
    # is the exception — it describes the navigation animation for this frame,
    # not the frame's content, so a push superseded by an ordinary re-render
    # still has to animate as a push or the transition is silently swallowed.
    {transition, reserved_transition} =
      take_transition(state.pending, state.reserved_transition, ref, transition)

    pending = Map.put(state.pending, ref, {tree, platform, nif, transition})
    send(self(), :flush)
    {:noreply, %{state | pending: pending, reserved_transition: reserved_transition}}
  end

  defp take_transition(pending, {ref, reserved}, ref, :none),
    do: {carry_transition(pending, ref, reserved), nil}

  defp take_transition(pending, {ref, _reserved}, ref, transition),
    do: {carry_transition(pending, ref, transition), nil}

  defp take_transition(pending, reserved, ref, transition),
    do: {carry_transition(pending, ref, transition), reserved}

  defp carry_transition(pending, ref, :none) do
    case Map.fetch(pending, ref) do
      {:ok, {_tree, _platform, _nif, superseded}} -> superseded
      :error -> :none
    end
  end

  defp carry_transition(_pending, _ref, transition), do: transition

  @impl GenServer
  def handle_info(:flush, state), do: {:noreply, flush(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp flush(state) do
    case Map.fetch(state.pending, state.active) do
      {:ok, payload} -> commit(payload)
      :error -> :ok
    end

    # Everything else waiting belongs to a screen that is not active. Dropping
    # it is deliberate: by the time such a screen becomes active it will have
    # re-rendered, so committing a queued tree would only show a stale frame.
    %{state | pending: %{}}
  end

  defp commit({tree, platform, nif, transition}) do
    Mob.Renderer.render(tree, platform, nif, transition)
  rescue
    error ->
      # A render that raises must not take the sender down with it: every other
      # screen renders through this process, so losing it freezes the whole UI.
      Logger.error("[mob] render failed: " <> Exception.format(:error, error, __STACKTRACE__))
      :error
  end
end
