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

  A `:persistent_term` read and an immediate return. No process, no ETS lookup,
  no allocation. `:persistent_term.get/2` is a direct read of an immutable term
  with no copying, which is why it is the right switch for something on the
  frame path.

  Measured: 49 ns per call, six calls per frame — 0.29 us against a ~378 us
  frame, or 0.08%. That is the number that matters, because unlike the recording
  path this one ships and runs on every frame of every app.

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
  @spec enable() :: :ok
  def enable do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :persistent_term.put(@flag, true)
    :ok
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
          :encode_us,
          :set_root_us,
          :total_us
        ]

        %{
          frames: length(frames),
          screens: frames |> Enum.map(& &1.screen) |> Enum.uniq(),
          nodes: percentiles(frames, :nodes),
          taps: percentiles(frames, :taps),
          bytes: percentiles(frames, :bytes),
          stages: Map.new(stages, &{&1, percentiles(frames, &1)})
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
  def resume_frame(nil), do: :ok
  def resume_frame(frame), do: Process.put(@frame, frame) && :ok

  @doc """
  Record a frame whose tree was never committed.

  A superseded or inactive tree still cost the BEAM everything up to the
  hand-off, and a render pipeline that throws away half its work is a finding
  rather than a detail.
  """
  @spec drop_frame(map() | nil) :: :ok
  def drop_frame(nil), do: :ok

  def drop_frame(frame) do
    store(
      frame
      |> Map.drop([:started])
      |> Map.merge(%{
        total_us: now() - frame.started,
        nodes: nil,
        taps: nil,
        bytes: 0,
        committed: false
      })
    )
  end

  @doc "Add a measured value to the frame in progress."
  @spec add(atom(), number()) :: :ok
  def add(key, value) do
    case Process.get(@frame) do
      nil -> :ok
      frame -> Process.put(@frame, Map.put(frame, key, value)) && :ok
    end
  end

  @doc """
  Close the frame, counting the prepared tree and storing the record.

  `tree` is the prepared tree and `bytes` the encoded payload. The node and tap
  walk happens here, after every timed stage, so it cannot inflate them.
  """
  @spec finish(term(), non_neg_integer()) :: :ok
  def finish(tree, bytes) do
    case Process.get(@frame) do
      nil ->
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

  # The prepared tree is a map with string keys by this point. An interactive
  # node is one whose props carry a handle, which the renderer has already
  # turned into an integer.
  defp count(node, {nodes, taps}) when is_map(node) do
    taps = taps + if(interactive?(node), do: 1, else: 0)
    children = Map.get(node, "children") || Map.get(node, :children) || []
    Enum.reduce(children, {nodes + 1, taps}, &count/2)
  end

  defp count(_other, acc), do: acc

  @handle_props MapSet.new(~w(on_tap on_change on_focus on_blur on_submit on_dismiss on_select
                     on_scroll on_drag on_pinch on_rotate on_long_press on_double_tap
                     on_swipe on_compose on_end_reached on_tab_select on_pointer_move))

  # Walk the node's own props rather than probing for all eighteen handler
  # names: a node carries a handful of props, so this turns ~18 map lookups per
  # node into ~4 set lookups. On a 780-node tree that is the difference between
  # the meter costing more than the render and costing a fraction of it.
  defp interactive?(node) do
    props = Map.get(node, "props") || Map.get(node, :props) || %{}

    Enum.any?(props, fn {key, value} ->
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

  defp at(sorted, q) do
    index = min(round(q * length(sorted)), length(sorted) - 1)
    Enum.at(sorted, index)
  end

  # ── Table owner ───────────────────────────────────────────────────────────

  use GenServer

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :ordered_set, write_concurrency: true])
    {:ok, %{}}
  end
end
