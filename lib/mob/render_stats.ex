defmodule Mob.RenderStats do
  @moduledoc """
  Per-frame timing for the render pipeline, readable from a connected node.

  Exists because every proposal in the rendering-performance epic (MOB-124) is a
  guess without it. The pipeline has never been measured on a device: nobody
  knows whether a dense screen spends its time in the user's `render/1`, in tree
  expansion, in JSON encoding, or inside `set_root` — and the four candidate
  fixes attack four different ones of those.

  ## A frame spans two processes

  This is the thing that makes the implementation less obvious than it looks.
  `Mob.Screen.Server.paint/4` runs the user's `render/1`, the expansion passes
  and the component reconcile in the **screen's** process — then hands the tree
  to `Mob.Sender` as a *cast*, so `prepare`, `:json.encode` and `set_root` run
  in the **sender's** process. A process-dictionary accumulator started by the
  screen is simply not there when the renderer looks for it, and the first cut
  of this module recorded nothing at all on device for exactly that reason.

  So the screen times its stages, `hand_off/1` sends the partial frame to the
  sender, and the sender resumes it before committing. Frames the sender drops
  — superseded by a newer tree, or belonging to a screen that is not active —
  are recorded with `committed: false` rather than discarded, because BEAM-side
  work that gets thrown away is worth knowing about.

  ## Cost when disabled

  `time/2` reads a `:persistent_term` and returns; `accumulate/2` reads the
  process dictionary and returns. Neither allocates a record.

  The honest cost is dominated by `accumulate/2`, not by the six `time/2` sites:
  it wraps every `register_tap` call, so it runs once per *registered handler* —
  615 times on the 200-row benchmark, not six. It also allocates a closure the
  direct call did not. Measured on a development Mac, 29.2 ns per call before
  and 35.8 ns after, so ~4 us per dense frame here and plausibly 20-40 us on a
  phone. Against a 27 ms frame that is under 0.2%, but it is not free, and it
  ships on every frame of every app. Note also that pdict lookup cost grows with
  dictionary size (14.6 ns at ~10 entries, 30.3 ns at 200).

  ## Using it

  From a connected node (`mix mob.connect --no-iex`, then a script):

      :rpc.call(node, Mob.RenderStats, :enable, [])
      # ... drive the app ...
      :rpc.call(node, Mob.RenderStats, :summary, [])

  `summary/0` returns percentiles per stage. `frames/0` returns the raw records,
  newest first, for when a percentile hides the thing you are looking for.

  ## What the stages mean

  * `render_us` — the user's `render/1`
  * `expand_us` — `Mob.Composite`, `Mob.List` and `Mob.Component` expansion
  * `reconcile_us` — `Mob.ComponentRegistry.reconcile/2`
  * `prepare_us` — the renderer's tree walk: prop resolution, theme token
    lookup, and one `register_tap` per interactive node
  * `encode_us` — `:json.encode` plus `iodata_to_binary`
  * `set_root_us` — the `set_root` NIF as seen from the BEAM, so it includes the
    dirty-scheduler hop, which is the honest number from the caller's side

  `nodes` and `taps` are counted by a walk of the prepared tree that runs
  **after** every timed stage and after `total_us` is stamped, so it cannot
  inflate any of them.

  That walk is not free: measured on a ~780-node tree, recording costs about
  40% on top of the frame. The per-stage numbers stay honest because each is
  timed in isolation, but do not compare an *enabled* `total_us` against a frame
  budget — measure the stages, not the meter.
  """

  @table __MODULE__
  @flag {__MODULE__, :enabled}
  @frame {__MODULE__, :frame}
  @max_frames 500

  @doc """
  Start recording. Idempotent.

  Starts a process to own the ETS table. Without one the table belongs to
  whoever called `enable/0` first — over `:rpc.call/4` that is a transient
  process, so the table dies the instant enabling returns and every later write
  goes nowhere.
  """
  @spec enable() :: :ok | {:error, term()}
  def enable do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} ->
        :persistent_term.put(@flag, true)
        :ok

      {:error, {:already_started, _pid}} ->
        :persistent_term.put(@flag, true)
        :ok

      {:error, reason} ->
        # Leave the flag off rather than recording into a table that does not
        # exist: `store/1` would silently succeed and every frame would vanish.
        {:error, reason}
    end
  end

  @doc "Stop recording. Frames already collected are kept."
  @spec disable() :: :ok
  def disable do
    :persistent_term.put(@flag, false)
    :ok
  end

  @doc "Whether recording is on."
  @spec enabled?() :: boolean()
  def enabled?, do: :persistent_term.get(@flag, false)

  @doc "Discard every recorded frame."
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Recorded frames, newest first."
  @spec frames() :: [map()]
  def frames do
    if :ets.whereis(@table) == :undefined do
      []
    else
      read_frames()
    end
  end

  defp read_frames do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Percentiles per stage across the recorded frames.

  Reports p50, p95 and max rather than a mean: frame cost is not normally
  distributed, and the tail is what a user experiences as stutter.
  """
  @spec summary() :: map()
  def summary do
    case frames() do
      [] ->
        %{frames: 0}

      frames ->
        stages = [
          :render_us,
          :expand_us,
          :reconcile_us,
          :prepare_us,
          :register_tap_us,
          :register_tap_us_n,
          :encode_us,
          :set_root_us,
          :total_us
        ]

        # Percentiles come from committed frames only. A dropped frame never ran
        # prepare/encode/set_root, and its total_us is screen-side work plus
        # however long it waited in the sender — pooling the two makes a p50
        # that describes neither. The counts stay visible so `frames: 40` can
        # never be read as 40 rendered frames when 31 of them were thrown away.
        {committed, dropped} = Enum.split_with(frames, & &1.committed)

        %{
          frames: length(frames),
          committed: length(committed),
          dropped: length(dropped),
          screens: frames |> Enum.map(& &1.screen) |> Enum.uniq(),
          nodes: percentiles(committed, :nodes),
          taps: percentiles(committed, :taps),
          bytes: percentiles(committed, :bytes),
          stages: Map.new(stages, &{&1, percentiles(committed, &1)}),
          dropped_total_us: percentiles(dropped, :total_us)
        }
    end
  end

  # ── Recording ─────────────────────────────────────────────────────────────

  @doc """
  Begin a frame. Returns a token to thread through, or `nil` when disabled.

  The accumulator lives in the process dictionary because the whole pipeline —
  the screen's `paint/4` and the renderer it calls — runs in one screen process,
  and threading a struct through `Mob.Renderer`'s public API to carry timings
  would put measurement scaffolding in a shipped signature.
  """
  @spec start_frame(module(), term()) :: :ok
  def start_frame(screen, transition) do
    if enabled?() do
      Process.put(@frame, %{screen: screen, transition: transition, started: now()})
    end

    :ok
  end

  @doc "Record a stage's duration by timing `fun`. Runs `fun` either way."
  @spec time(atom(), (-> result)) :: result when result: term()
  def time(stage, fun) do
    if enabled?() && Process.get(@frame) do
      t0 = now()
      result = fun.()
      add(stage, now() - t0)
      result
    else
      fun.()
    end
  end

  @doc """
  Take the frame in progress out of this process, for handing to another.

  Returns `nil` when disabled or when no frame is open.
  """
  @spec take_frame() :: map() | nil
  def take_frame, do: Process.delete(@frame)

  @doc """
  Hand the frame in progress to `Mob.Sender`, which finishes it.

  Sent as its own cast rather than threaded through `Mob.Sender.render/5,6`:
  those are the shipped render entry points and one of them is already probed
  with `function_exported?/3` for version skew, so widening them to carry
  measurement scaffolding would be the wrong trade. Ordering holds because both
  messages come from the same process to the same mailbox.
  """
  @spec hand_off(term()) :: :ok
  def hand_off(ref) do
    case take_frame() do
      nil -> :ok
      frame -> GenServer.cast(Mob.Sender, {:render_stats, ref, frame})
    end
  end

  @doc "Install a frame taken from another process."
  @spec resume_frame(map() | nil) :: :ok
  def resume_frame(nil) do
    # Erase, not no-op. `finish/2` is the only thing that clears the key, and it
    # is skipped whenever the render raises — a path `Mob.Sender.commit/1`
    # exists specifically to rescue. A leftover frame would otherwise be resumed
    # against a later, unrelated tree and recorded with a total_us that is
    # mostly the gap between two frames.
    Process.delete(@frame)
    :ok
  end

  def resume_frame(frame) do
    Process.put(@frame, frame)
    :ok
  end

  @doc """
  Record a frame whose tree was never committed.

  A superseded or inactive tree still cost the BEAM everything up to the
  hand-off, and a render pipeline that throws away half its work is a finding
  rather than a detail.
  """
  @spec drop_frame(map() | nil) :: :ok
  def drop_frame(nil), do: :ok

  def drop_frame(frame) do
    if enabled?(), do: do_drop_frame(frame), else: :ok
  end

  defp do_drop_frame(frame) do
    store(
      frame
      |> Map.drop([:started])
      |> Map.merge(%{
        total_us: now() - frame.started,
        nodes: nil,
        taps: nil,
        bytes: nil,
        committed: false
      })
    )
  end

  @doc """
  Time `fun` and add it to a running total for this frame.

  For work that happens many times per frame — one `register_tap` per
  interactive node — where the sum is what matters, not each call.
  """
  @spec accumulate(atom(), (-> result)) :: result when result: term()
  def accumulate(key, fun) do
    case enabled?() && Process.get(@frame) do
      frame when not is_map(frame) ->
        fun.()

      frame ->
        t0 = now()
        result = fun.()
        elapsed = now() - t0
        count_key = :"#{key}_n"

        Process.put(
          @frame,
          frame
          |> Map.update(key, elapsed, &(&1 + elapsed))
          |> Map.update(count_key, 1, &(&1 + 1))
        )

        result
    end
  end

  @doc "Add a measured value to the frame in progress."
  @spec add(atom(), number()) :: :ok
  def add(key, value) do
    case Process.get(@frame) do
      nil ->
        :ok

      frame ->
        Process.put(@frame, Map.put(frame, key, value))
        :ok
    end
  end

  @doc """
  Close the frame, counting the prepared tree and storing the record.

  `tree` is the prepared tree and `bytes` the encoded payload. The node and tap
  walk happens here, after every timed stage, so it cannot inflate them.
  """
  @spec finish(term(), non_neg_integer()) :: :ok
  def finish(tree, bytes) do
    case enabled?() && Process.get(@frame) do
      frame when not is_map(frame) ->
        # Still clear: recording may have been disabled mid-frame, and a frame
        # left behind would be resumed against a later tree.
        Process.delete(@frame)
        :ok

      frame ->
        Process.delete(@frame)
        # Stamp the total BEFORE walking the tree, or the count inflates the
        # number it is meant to describe.
        total_us = now() - frame.started
        {nodes, taps} = count(tree, {0, 0})

        record =
          frame
          |> Map.drop([:started])
          |> Map.merge(%{
            total_us: total_us,
            nodes: nodes,
            taps: taps,
            bytes: bytes,
            committed: true
          })

        store(record)
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp now, do: System.monotonic_time(:microsecond)

  defp store(record) do
    if :ets.whereis(@table) == :undefined do
      :ok
    else
      do_store(record)
    end
  end

  defp do_store(record) do
    :ets.insert(@table, {System.unique_integer([:monotonic]), record})

    # Ring rather than unbounded: this runs on a memory-constrained device and a
    # long measurement session would otherwise grow without limit.
    if :ets.info(@table, :size) > @max_frames do
      case :ets.first(@table) do
        :"$end_of_table" -> :ok
        oldest -> :ets.delete(@table, oldest)
      end
    end

    :ok
  end

  # The prepared tree is a map with string keys by this point. Every handler prop
  # holds a handle the renderer got from one `register_tap` call, so counting
  # handle-valued props counts NIF calls. Counting interactive *nodes* instead
  # would undercount: one node carrying `on_tap` and `on_long_press` makes two
  # calls. `taps` is therefore directly comparable to `register_tap_us_n`, and
  # the two disagreeing means one of them has a bug.
  defp count(node, {nodes, taps}) when is_map(node) do
    children = Map.get(node, "children") || Map.get(node, :children) || []
    Enum.reduce(children, {nodes + 1, taps + handle_count(node)}, &count/2)
  end

  defp count(_other, acc), do: acc

  # Every prop `Mob.Renderer.register_handler/2` writes. Kept exhaustive on
  # purpose: a missing name silently undercounts, which is how the first version
  # of this reported 1 tap on a tree that made 12 calls.
  @handle_props MapSet.new(~w(on_tap on_change on_focus on_blur on_submit on_dismiss on_select
                     on_scroll on_drag on_pinch on_rotate on_long_press on_double_tap
                     on_swipe on_swipe_left on_swipe_right on_swipe_up on_swipe_down
                     on_compose on_end_reached on_tab_select on_pointer_move
                     on_scroll_began on_scroll_ended on_scroll_settled on_top_reached
                     on_scrolled_past))

  # Walk the node's own props rather than probing for all handler names: a node
  # carries a handful of props, so this turns ~27 map lookups per node into ~4
  # set lookups. On a 780-node tree that is the difference between the meter
  # costing more than the render and costing a fraction of it.
  defp handle_count(node) do
    props = Map.get(node, "props") || Map.get(node, :props) || %{}

    Enum.count(props, fn {key, value} ->
      is_integer(value) and MapSet.member?(@handle_props, key)
    end)
  end

  defp percentiles(frames, key) do
    values = frames |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1) |> Enum.sort()

    case values do
      [] -> nil
      _ -> %{p50: at(values, 0.5), p95: at(values, 0.95), max: List.last(values)}
    end
  end

  # Nearest-rank: the smallest value at or above the q-th fraction of the sample.
  # `round/1` here would return one rank too high at every q — a p50 that is the
  # 60th percentile at n=10, and a p95 that is literally the worst frame for any
  # n under 21, which is exactly the range a short measurement run lands in.
  defp at(sorted, q) do
    n = length(sorted)
    index = clamp(ceil(q * n) - 1, 0, n - 1)
    Enum.at(sorted, index)
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  # ── Table owner ───────────────────────────────────────────────────────────

  use GenServer

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :ordered_set, write_concurrency: true])
    {:ok, %{}}
  end
end
