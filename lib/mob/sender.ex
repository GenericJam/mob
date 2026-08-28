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
  calls `sync/1`. That works by mailbox ordering rather than by tracking work:
  the flush is self-sent during the render cast, so it is already queued ahead
  of any later `sync/1` call. `Mob.Screen` uses this to keep the guarantee
  `Mob.Test` documents — that `tap/2` and `navigate/2` return only once the
  re-render is complete.
  """

  use GenServer

  require Logger

  @typedoc """
  Identifies which screen a tree belongs to. Today this is the active
  navigation stack's name (see `Mob.Nav.active_ref/1`); MOB-112 replaces it with
  a per-screen reference.
  """
  @type screen_ref :: atom() | reference()

  defstruct active: nil, pending: %{}

  @doc "Start the sender. Named, so there is exactly one."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether the sender is running. Renders are dropped when it is not."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @doc """
  Declare which screen's trees may be committed.

  A render for any other screen is dropped. `Mob.Screen` sets this today;
  MOB-113's router takes it over.
  """
  @spec set_active(screen_ref()) :: :ok
  def set_active(ref), do: GenServer.cast(__MODULE__, {:set_active, ref})

  @doc """
  Queue `tree` for commit on behalf of screen `ref`.

  Returns immediately. The tree is committed only if `ref` is active when the
  sender gets to it, and only if no newer tree for `ref` has arrived by then.
  """
  @spec render(screen_ref(), map(), atom(), module() | atom(), atom()) :: :ok
  def render(ref, tree, platform, nif, transition) do
    GenServer.cast(__MODULE__, {:render, ref, tree, platform, nif, transition})
  end

  @doc """
  Block until every render queued before this call has been committed or
  dropped.
  """
  @spec sync(timeout()) :: :ok
  def sync(timeout \\ 5000), do: GenServer.call(__MODULE__, :sync, timeout)

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    {:ok, %__MODULE__{active: Keyword.get(opts, :active)}}
  end

  @impl GenServer
  def handle_cast({:set_active, ref}, state), do: {:noreply, %{state | active: ref}}

  def handle_cast({:render, ref, tree, platform, nif, transition}, state) do
    # Overwrite rather than append: a newer tree for the same screen supersedes
    # the one waiting, which is the whole point of queueing here.
    pending = Map.put(state.pending, ref, {tree, platform, nif, transition})
    send(self(), :flush)
    {:noreply, %{state | pending: pending}}
  end

  @impl GenServer
  def handle_info(:flush, state), do: {:noreply, flush(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:sync, _from, state) do
    # Flush here rather than just replying. The `:flush` this render self-sent
    # lands at the BACK of the mailbox, which is behind a `sync` the caller has
    # already queued — replying without flushing would return before the frame
    # was committed, which is the one thing this function promises not to do.
    {:reply, :ok, flush(state)}
  end

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
