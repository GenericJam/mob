defmodule Mob.Defect.Bus do
  @moduledoc """
  The bounded record of defects the framework has emitted, and the fanout to
  whoever subscribed to hear about them.

  ## Deduplication

  Every emit goes through `fingerprint`. One thousand emits of the same bug
  produce one class row whose occurrence counter reaches 1000 as each one
  lands, with the first-seen capsule held for the class and `last_seen_ms`
  moving forward. That is what makes the channel usable — a report system
  that emitted a thousand rows per bug would train its readers to stop
  reading it.

  The counter and last-seen fields are read directly from the row on each
  call to `classes/1`; both are updated by atomic ETS ops on the write path
  (`update_counter` and `update_element`), so a listing is consistent under
  concurrency down to the individual row.

  A parallel bounded ring keeps the most recent 64 raw capsules, keyed by
  sequence, for the case where a triager wants to walk through occurrences
  rather than classes. Ring rather than unbounded because a capsule is packaged
  memory in a production app, and defect-report storage that grows without
  limit is worse than a bug it might have described.

  Classes are bounded too, at 256. A fingerprint is only as stable as the
  `fingerprint_key` its caller supplied, and app code supplies some, so a key
  that carries per-occurrence data would otherwise add a class per emit for
  the life of the app. Past the bound the least recently seen class is evicted
  and counted (`Mob.Diag.health/0`, `class_evictions`).

  ## Fanout without a mailbox on the hot path

  Same reasoning as `Mob.Agent.Receipts`: an `emit/1` is on the path of every
  detected defect, and putting a GenServer in front of that path serialises
  every writer through one mailbox. Subscribers are kept by
  `Mob.Diag.Subscribers`, which monitors them and publishes the list to
  `:persistent_term`; the write path reads that once and sends to each pid
  directly. A subscriber lifecycle change is a rare event; a defect emit is not.

  ## Observation

  The bus keeps a watermark: the highest emit sequence someone has observed.
  Delivering a capsule to at least one subscriber observes it; `recent/1`,
  `classes/1` and `subscribe/1` observe everything emitted before them. The
  watermark is passed to `Mob.PostMortem.Journal.observed/1`, which clears
  post-mortem entries that a destructive OS drain handed over only once — the
  one thing on the bus that must outlive the boot until someone has seen it.
  An emit that reaches no subscriber does no extra work, and one that does
  pays a compare-and-swap and a `:persistent_term` read.

  ## No default sink

  A subscriber is a pid, and no pid is subscribed until an app registers one.
  Per the decision record, mob owns the format and the bus; it never owns a
  destination. The dev sink in `Mob.Defect.Sinks.Dev` is what a connected
  agent runs at its end after `mix mob.connect`.

  ## Subscribers must not crash the emit path

  A subscriber pid is a `send/2` target on the emit path. `send/2` never
  blocks and never raises on a dead pid, so a dead subscriber does not take
  down the emitter — its monitor prunes the pid from the cached list. But the
  *contents* of what a subscriber does with the message must not affect the
  emitter, which is the standard contract of message passing and not enforced
  here.

  `emit/1` itself never raises: a failure to record is counted as `lost` in
  `Mob.Diag.health/0`, because a defect reporter that crashes on the defect it
  is reporting destroys the report.
  """

  @behaviour Mob.Diag.Store

  require Logger

  alias Mob.Defect.Capsule
  alias Mob.Diag.{Store, Subscribers}

  @classes :mob_defect_classes
  @recent :mob_defect_recent
  @keep_recent 64
  @keep_classes 256

  # Indices into the state's `:atomics` array.
  @recent_seq 1
  @class_evictions 2

  @impl Store
  def tables do
    opts = [:set, :public, {:write_concurrency, true}]
    # `@classes` last: it is the flag `Mob.Diag.Store.ensure/1` checks.
    [{@recent, opts}, {@classes, opts}]
  end

  @impl Store
  def state_vsn, do: 2

  # A new state (first setup, or after a hot push onto an older `mob` whose
  # owner still holds the ring) continues from the highest sequence already in
  # it, so new capsules never sort under old ones. Version 1 had no `observed`
  # watermark; it starts at 0, which only means nothing was observed yet.
  @impl Store
  def new_state(previous) do
    seq =
      case previous && previous[:seq] do
        nil ->
          seq = :atomics.new(2, signed: false)
          :atomics.put(seq, @recent_seq, highest_recent_seq())
          seq

        seq ->
          seq
      end

    observed = (previous && previous[:observed]) || :atomics.new(1, signed: false)
    %{seq: seq, observed: observed}
  end

  defp highest_recent_seq do
    if :ets.whereis(@recent) == :undefined,
      do: 0,
      else: :ets.foldl(fn {seq, _}, acc -> max(seq, acc) end, 0, @recent)
  end

  @impl Store
  def health(%{seq: seq}) do
    %{
      emitted: :atomics.get(seq, @recent_seq),
      class_evictions: :atomics.get(seq, @class_evictions),
      class_limit: @keep_classes
    }
  end

  @doc false
  @spec start() :: :ok
  def start, do: Store.ensure(__MODULE__)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Emit a capsule.

  Records the class (incrementing occurrences), appends to the recent-ring,
  and fans out to every subscribed pid as `{:mob_defect, capsule}`.

  Returns the capsule, so this can sit at the end of a pipeline.
  """
  @spec emit(Capsule.t()) :: Capsule.t()
  def emit(%Capsule{} = capsule) do
    Store.guard(__MODULE__, capsule, fn ->
      Store.ensure(__MODULE__)
      state = Store.state(__MODULE__)

      record_class(state, capsule)
      seq = record_recent(state, capsule)
      fanout(state, seq, capsule)

      capsule
    end)
  end

  @doc """
  Every defect class currently held, newest first by `last_seen_at`.

  A class row carries the *first* capsule seen for that fingerprint plus the
  occurrence count and last-seen timestamp. Later occurrences are on the
  recent ring, not layered onto the class — that keeps the class row a
  bounded shape regardless of how noisy the defect gets.
  """
  @spec classes(pos_integer()) :: [map()]
  def classes(limit \\ 20) do
    Store.ensure(__MODULE__)
    observe_all()

    @classes
    |> :ets.tab2list()
    |> Enum.map(fn {_fp, base_row, occurrences, last_seen_ms} ->
      # `base_row` is written exactly once (on the first emit for this
      # fingerprint) with `occurrences: 1` and `last_seen_ms` equal to that
      # first-seen time. Overlay the two live atomic fields so a reader sees
      # a class row that is consistent with the counter and last-seen a
      # concurrent writer just advanced.
      base_row
      |> Map.put(:occurrences, occurrences)
      |> Map.put(:last_seen_ms, last_seen_ms)
    end)
    |> Enum.sort_by(& &1.last_seen_ms, :desc)
    |> Enum.take(limit)
  end

  @doc "How many distinct defect classes are held."
  @spec class_count() :: non_neg_integer()
  def class_count do
    Store.ensure(__MODULE__)
    :ets.info(@classes, :size)
  end

  @doc "The most recent capsules (raw occurrences), newest first."
  @spec recent(pos_integer()) :: [Capsule.t()]
  def recent(limit \\ 20) do
    Store.ensure(__MODULE__)
    observe_all()

    @recent
    |> :ets.tab2list()
    |> Enum.sort_by(fn {seq, _c} -> -seq end)
    |> Enum.take(limit)
    |> Enum.map(fn {_seq, c} -> c end)
  end

  @doc """
  Subscribe `pid` (defaults to the caller) to defect emits.

  Returns `{:ok, ref}` — the caller can keep the ref for its own bookkeeping,
  but does not need it to unsubscribe (unsubscription is by pid).
  Idempotent: subscribing an already-subscribed pid is a no-op.

  The subscriber is monitored; its exit, or its node disconnecting, prunes it.
  From a connected node, pass the pid to receive on — `:rpc.call(node,
  Mob.Defect.Bus, :subscribe, [self()])`. Without it, `:rpc` subscribes the
  short-lived process it runs the call in, which receives nothing.

  A subscribe counts as observing every capsule emitted before it (see
  "Observation" above).
  """
  @spec subscribe() :: {:ok, reference()}
  @spec subscribe(pid()) :: {:ok, reference()}
  def subscribe(pid \\ self()) do
    {:ok, ref} = Subscribers.subscribe(:defect_bus, pid, nil)
    observe_all()
    {:ok, ref}
  end

  @doc "Unsubscribe `pid` (defaults to `self()`)."
  @spec unsubscribe() :: :ok
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid \\ self()), do: Subscribers.unsubscribe(:defect_bus, pid)

  @doc "The subscribers the write path will fan out to right now."
  @spec subscribers() :: [pid()]
  def subscribers, do: for({pid, _meta} <- Subscribers.list(:defect_bus), do: pid)

  @doc false
  @spec emitted_seq() :: non_neg_integer()
  def emitted_seq, do: :atomics.get(Store.state(__MODULE__).seq, @recent_seq)

  @doc false
  @spec observed_seq() :: non_neg_integer()
  def observed_seq, do: :atomics.get(Store.state(__MODULE__).observed, 1)

  @doc false
  @spec reset() :: :ok
  def reset do
    for {t, _opts} <- tables() do
      if :ets.whereis(t) != :undefined, do: :ets.delete_all_objects(t)
    end

    state = Store.state(__MODULE__)
    :atomics.put(state.seq, @recent_seq, 0)
    :atomics.put(state.seq, @class_evictions, 0)
    :atomics.put(state.observed, 1, 0)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Observation
  # ---------------------------------------------------------------------------

  defp observe_all do
    state = Store.state(__MODULE__)
    observe(state, :atomics.get(state.seq, @recent_seq))
  end

  # The watermark only rises, and the journal is told where it stands.
  defp observe(state, through) do
    Mob.PostMortem.Journal.observed(raise_watermark(state.observed, through))
  end

  defp raise_watermark(observed, through) do
    current = :atomics.get(observed, 1)

    cond do
      through <= current -> current
      :atomics.compare_exchange(observed, 1, current, through) == :ok -> through
      true -> raise_watermark(observed, through)
    end
  end

  # ---------------------------------------------------------------------------
  # Write path
  # ---------------------------------------------------------------------------

  defp record_class(state, %Capsule{} = c) do
    now_ms = System.system_time(:millisecond)

    # Tuple layout: {fingerprint, base_row, occurrences, last_seen_ms}. The
    # counter increments position 3 atomically; last_seen writes position 4
    # atomically; the base_row at position 2 is written once (via the default
    # tuple below on first insert) and never touched again. `classes/1`
    # overlays live position 3 and position 4 onto the immutable base_row on
    # read — no read-modify-write on the write path, so concurrent writers
    # cannot clobber each other into a stale derived cache.
    default = {c.fingerprint, first_seen_row(c, now_ms), 0, now_ms}
    occurrences = :ets.update_counter(@classes, c.fingerprint, {3, 1}, default)
    :ets.update_element(@classes, c.fingerprint, {4, now_ms})

    # Only a new class can take the table past the bound, so the scan for the
    # oldest runs once per new class beyond it, never per occurrence.
    if occurrences == 1, do: enforce_class_limit(state, c.fingerprint)

    :ok
  end

  # Concurrent new classes can each see the table over the bound and pick the
  # same oldest rows. Evicting by compare-and-delete on the exact
  # `{fingerprint, last_seen}` means only one of them removes each row and only
  # a removal is counted. Each writer re-reads the size before every delete and
  # stops once the table is at the bound, so the table is never left above it
  # and at most one extra row per racing writer goes: two writers that both saw
  # it one over can each remove a row. A class that was seen again in the
  # meantime no longer matches and is not evicted, and the class just inserted
  # is the newest, so it is never chosen.
  #
  # One pass reads only `{last_seen, fingerprint}` pairs (not the rows and
  # their capsules) and walks the oldest `excess` of them. The excess is
  # normally one, but after a hot push onto a `mob` that had no bound it can be
  # thousands, and picking one victim per full scan made that first emit
  # quadratic: 6.4 s for 6,000 classes on a laptop, inside a screen process.
  # Deleting a precomputed `excess` without the size re-check was no better:
  # 16 writers racing onto such a table cut it to as few as one class.
  defp enforce_class_limit(state, keep_fingerprint) do
    excess = :ets.info(@classes, :size) - @keep_classes

    if excess > 0 do
      keep_fingerprint
      |> oldest_classes(excess)
      |> Enum.reduce_while(:ok, fn {seen, fingerprint}, :ok ->
        if :ets.info(@classes, :size) > @keep_classes do
          if :ets.select_delete(@classes, [{{fingerprint, :_, :_, seen}, [], [true]}]) == 1,
            do: :atomics.add(state.seq, @class_evictions, 1)

          {:cont, :ok}
        else
          {:halt, :ok}
        end
      end)

      # Rows another writer removed, or that were seen again, were skipped;
      # if that left the table over the bound, pick again.
      enforce_class_limit(state, keep_fingerprint)
    end
  end

  defp oldest_classes(keep_fingerprint, count) do
    @classes
    |> :ets.select([
      {{:"$1", :_, :_, :"$2"}, [{:"=/=", :"$1", keep_fingerprint}], [{{:"$2", :"$1"}}]}
    ])
    |> Enum.sort()
    |> Enum.take(count)
  end

  # base_row's `occurrences` and `last_seen_ms` fields are placeholders — the
  # authoritative values live at positions 3 and 4 of the tuple and `classes/1`
  # reads them from there. Kept in the map for shape compatibility with a
  # reader that never joined the two.
  defp first_seen_row(%Capsule{} = c, now_ms) do
    %{
      fingerprint: c.fingerprint,
      kind: c.kind,
      owner: c.owner,
      severity: c.severity,
      first_capsule: c,
      first_seen_ms: now_ms,
      last_seen_ms: now_ms,
      occurrences: 1
    }
  end

  defp record_recent(state, %Capsule{} = c) do
    seq = :atomics.add_get(state.seq, @recent_seq, 1)
    :ets.insert(@recent, {seq, c})

    if :ets.info(@recent, :size) > @keep_recent do
      cutoff = seq - @keep_recent + 1
      :ets.select_delete(@recent, [{{:"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
    end

    seq
  end

  # A capsule delivered to at least one subscriber has been observed; one that
  # reached nobody costs nothing extra here.
  defp fanout(state, seq, %Capsule{} = c) do
    delivered = Enum.count(Subscribers.list(:defect_bus), fn {pid, _meta} -> deliver(pid, c) end)
    if delivered > 0, do: observe(state, seq)
    :ok
  end

  defp deliver(pid, %Capsule{} = c) do
    # send/2 does not raise on a dead pid, so a subscriber that exited
    # between publish-of-the-cached-list and this line does not affect
    # this or any other subscriber. Its monitor prunes the dead pid from
    # the cached list on its own schedule.
    #
    # A **remote** subscriber pid is a different matter: dist encoding of
    # the term happens in *this* process's context, and if a caller ever
    # plumbs a resource that cannot be encoded (a NIF resource, a closure
    # over one) into the capsule, `send/2` raises here and takes down the
    # emitter. That would be a defect reporter that crashes on the defect
    # it is reporting — the exact anti-pattern the framework promises to
    # avoid, per `capsule.ex`'s "bounded shapes" section.
    #
    # Isolate each pid so one bad recipient does not stop delivery to the
    # rest, and log at :error so a broken payload surfaces rather than
    # disappearing silently. The framework's own emit paths ship shapes
    # that encode; a defect here means an app-owned caller passed
    # something it should not have.
    send(pid, {:mob_defect, c})
    true
  catch
    kind, reason ->
      Logger.error(
        "[Mob.Defect.Bus] fanout to #{inspect(pid)} raised: " <>
          "#{inspect(kind)} #{inspect(reason)}. Capsule dropped for this subscriber."
      )

      false
  end
end
