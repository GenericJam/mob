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

  ## Fanout without a mailbox on the hot path

  Same reasoning as `Mob.Agent.Receipts`: an `emit/1` is on the path of every
  detected defect, and putting a GenServer in front of that path serialises
  every writer through one mailbox. The bus's owner GenServer holds the
  subscriber registry and monitors, and it publishes the *cached* subscriber
  pid list to `:persistent_term` — the write path reads that once and sends to
  each pid directly. A subscriber lifecycle change is a rare event; a defect
  emit is not.

  ## No default sink

  A subscriber is a pid, and no pid is subscribed until an app registers one.
  Per the decision record, mob owns the format and the bus; it never owns a
  destination. The dev sink in `Mob.Defect.Sinks.Dev` is what a connected
  agent runs at its end after `mix mob.connect`.

  ## Subscribers must not crash the emit path

  A subscriber pid is a `send/2` target on the emit path. `send/2` never
  blocks and never raises on a dead pid, so a dead subscriber does not take
  down the emitter — the monitor in the owner catches the DOWN and prunes the
  pid from the cached list. But the *contents* of what a subscriber does with
  the message must not affect the emitter, which is the standard contract of
  message passing and not enforced here.
  """

  require Logger

  alias Mob.Defect.Capsule

  @classes :mob_defect_classes
  @recent :mob_defect_recent
  @subscribers_key :mob_defect_subscribers
  @state :mob_defect_state
  @keep_recent 64

  # ---------------------------------------------------------------------------
  # Startup
  # ---------------------------------------------------------------------------

  @doc false
  @spec start() :: :ok
  def start do
    if :ets.whereis(@classes) == :undefined, do: Mob.Defect.Bus.Owner.start()
    :ok
  end

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
    start()

    record_class(capsule)
    record_recent(capsule)
    fanout(capsule)

    capsule
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
    start()

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
    start()
    :ets.info(@classes, :size)
  end

  @doc "The most recent capsules (raw occurrences), newest first."
  @spec recent(pos_integer()) :: [Capsule.t()]
  def recent(limit \\ 20) do
    start()

    @recent
    |> :ets.tab2list()
    |> Enum.sort_by(fn {seq, _c} -> -seq end)
    |> Enum.take(limit)
    |> Enum.map(fn {_seq, c} -> c end)
  end

  @doc """
  Subscribe the calling process to defect emits.

  Returns `{:ok, ref}` — the caller can keep the ref for its own bookkeeping,
  but does not need it to unsubscribe (unsubscription is by pid).
  Idempotent: subscribing an already-subscribed pid is a no-op.

  The subscriber's process is monitored; a subscriber exit prunes it from
  the cached list.
  """
  @spec subscribe() :: {:ok, reference()}
  @spec subscribe(pid()) :: {:ok, reference()}
  def subscribe(pid \\ self()) do
    start()
    Mob.Defect.Bus.Owner.subscribe(pid)
  end

  @doc "Unsubscribe `pid` (defaults to `self()`)."
  @spec unsubscribe() :: :ok
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid \\ self()) do
    start()
    Mob.Defect.Bus.Owner.unsubscribe(pid)
  end

  @doc "The subscribers the write path will fan out to right now."
  @spec subscribers() :: [pid()]
  def subscribers do
    start()
    :persistent_term.get(@subscribers_key, [])
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    for t <- [@classes, @recent] do
      if :ets.whereis(t) != :undefined, do: :ets.delete_all_objects(t)
    end

    if state = safe_state(), do: :atomics.put(state.seq, 1, 0)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Write path
  # ---------------------------------------------------------------------------

  defp record_class(%Capsule{} = c) do
    now_ms = System.system_time(:millisecond)

    # Tuple layout: {fingerprint, base_row, occurrences, last_seen_ms}. The
    # counter increments position 3 atomically; last_seen writes position 4
    # atomically; the base_row at position 2 is written once (via the default
    # tuple below on first insert) and never touched again. `classes/1`
    # overlays live position 3 and position 4 onto the immutable base_row on
    # read — no read-modify-write on the write path, so concurrent writers
    # cannot clobber each other into a stale derived cache.
    default = {c.fingerprint, first_seen_row(c, now_ms), 0, now_ms}
    _new_occurrences = :ets.update_counter(@classes, c.fingerprint, {3, 1}, default)
    :ets.update_element(@classes, c.fingerprint, {4, now_ms})
    :ok
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

  defp record_recent(%Capsule{} = c) do
    state = state()
    seq = :atomics.add_get(state.seq, 1, 1)
    :ets.insert(@recent, {seq, c})

    if :ets.info(@recent, :size) > @keep_recent do
      cutoff = seq - @keep_recent + 1
      :ets.select_delete(@recent, [{{:"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
    end
  end

  defp fanout(%Capsule{} = c) do
    for pid <- :persistent_term.get(@subscribers_key, []) do
      # send/2 does not raise on a dead pid, so a subscriber that exited
      # between publish-of-the-cached-list and this line does not affect
      # this or any other subscriber. The owner's DOWN monitor prunes the
      # dead pid from the cached list on its own schedule.
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
      try do
        send(pid, {:mob_defect, c})
      catch
        kind, reason ->
          Logger.error(
            "[Mob.Defect.Bus] fanout to #{inspect(pid)} raised: " <>
              "#{inspect(kind)} #{inspect(reason)}. Capsule dropped for this subscriber."
          )
      end
    end

    :ok
  end

  defp state, do: :persistent_term.get(@state)

  defp safe_state do
    :persistent_term.get(@state, nil)
  end
end
