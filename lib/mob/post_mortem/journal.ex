defmodule Mob.PostMortem.Journal do
  # Constants first so the moduledoc can interpolate them.
  @file_name "mob_post_mortem_journal.etf"
  @keep 32
  @pending {__MODULE__, :pending}
  @call_timeout 5_000
  # `Bus.recent/1` is a reader, often an agent's first call: a journal owner
  # stuck in a hung fsync must not hold it for the full call timeout. Missing
  # an observation only means the entry is emitted again next boot.
  @observe_timeout 500

  @moduledoc """
  Keeps what a destructive post-mortem drain returned until someone has
  observed it.

  Android's `ApplicationExitInfo` drain (`Mob.PostMortem.Android`) advances an
  on-disk marker when it returns an exit, and iOS MetricKit
  (`Mob.PostMortem.IOS`) hands a payload over once. Either way the only copy
  left is the capsule on this boot's in-memory `Mob.Defect.Bus`. If the boot
  dies before anyone looks — `mix mob.connect` restarts the app, for one — the
  exit is gone from every surface.

  So each sweep writes what it drained to `#{@file_name}` in `Mob.data_dir/0`
  **before** emitting it, and re-emits every entry still in the journal on
  every sweep, including the first sweep of the next boot. Within one boot,
  `Mob.PostMortem.Registry.emit_once/2` keeps a re-sweep from emitting an entry
  twice.

  ## Observed

  An entry leaves the journal once its own capsule has been seen:

    * the emit handed it to at least one `Mob.Defect.Bus` subscriber, or
    * `Mob.Defect.Bus.recent/1` returned it.

  Nothing else counts. `classes/1` shows a class row, not the occurrence, and
  subscribing, or a later capsule reaching a subscriber, says nothing about a
  capsule emitted before. A `recent/1` that runs between a sweep's emit and its
  bookkeeping is missed, and the entry is emitted again by the next boot: the
  journal errs toward a duplicate, never toward a loss.

  ## Bounded and never fatal

  The journal holds at most #{@keep} entries. Past that the oldest are dropped
  and counted (`read/1`'s `dropped`), and a warning is logged; a sweep still
  emits everything it drained. A journal that cannot be decoded is treated as
  empty, logged, and overwritten by the same sweep, so the warning appears
  once. Writes go to a temporary file that is synced and renamed over the
  journal.

  Every read-modify-write of the file runs in one node-local process,
  registered as `#{inspect(__MODULE__)}`, started on first use and unlinked.
  It also holds which of this boot's capsules are still waiting to be
  observed; a `:persistent_term` flag, set only while that set is non-empty,
  is all `Mob.Defect.Bus.recent/1` reads before deciding to call it. It is
  called only by sweeps, and by `recent/1` while entries are waiting; never by
  an emit. The file is the record, so the process dying loses no evidence: a
  caller it was serving logs and carries on (a sweep still emits), the next
  caller starts a new one, and entries whose observation it can no longer
  match are emitted again by the next boot. Nothing here raises into a sweep
  or a bus reader.
  """

  use GenServer

  require Logger

  alias Mob.Defect.Bus
  alias Mob.Defect.Capsule
  alias Mob.PostMortem.Registry

  @magic :mob_post_mortem_journal
  @version 1

  @typedoc "A drained entry: its source, its artifact id, and the map the NIF returned."
  @type entry :: {source :: atom(), id :: String.t(), map()}

  @doc "The journal's path on this device: `#{@file_name}` in `Mob.data_dir/0`."
  @spec default_path() :: Path.t()
  def default_path, do: Path.join(Mob.data_dir(), @file_name)

  @doc """
  Journal `fresh` (`{id, entry}` pairs drained from `source`), then emit every
  entry of `source` still in the journal followed by the fresh ones, each
  through `Registry.emit_once/2` as the capsule `build` makes of it.

  An emitted capsule that reached a subscriber is cleared at once; the rest
  wait for `observed/1`. `path` is resolved lazily, so a data directory that
  cannot be resolved costs the journal, not the sweep. Returns the capsules
  emitted.
  """
  @spec sweep((-> Path.t()), atom(), [{String.t(), map()}], (map() -> Capsule.t())) ::
          [Capsule.t()]
  def sweep(path, source, fresh, build)
      when is_function(path, 0) and is_atom(source) and is_list(fresh) and
             is_function(build, 1) do
    case resolve(path) do
      {:ok, path} ->
        emitted = call({:record, path, source, fresh}, fresh) |> emit_all(build)
        {seen, unseen} = Enum.split_with(emitted, fn {_id, _c, delivered} -> delivered > 0 end)
        seen = for {id, _c, _delivered} <- seen, do: id
        waiting = for {id, c, _delivered} <- unseen, do: {c.id, id}
        if seen != [] or waiting != [], do: call({:settle, path, seen, waiting}, :ok)
        for {_id, c, _delivered} <- emitted, do: c

      :error ->
        for {_id, c, _delivered} <- emit_all(fresh, build), do: c
    end
  end

  @doc """
  Clear the journaled entries whose capsules are among `capsules`.

  `Mob.Defect.Bus.recent/1` calls this with what it returns. Unless this boot
  emitted journaled entries nobody has observed yet, it is one
  `:persistent_term` read. Never raises.
  """
  @spec observed([Capsule.t()]) :: :ok
  def observed(capsules) when is_list(capsules) do
    if :persistent_term.get(@pending, false) do
      case for %Capsule{id: id} <- capsules, do: id do
        [] -> :ok
        ids -> call({:observed, ids}, :ok, @observe_timeout)
      end
    end

    :ok
  end

  @doc """
  What the journal at `path` (default: `default_path/0`) holds: the entries
  still waiting to be observed, oldest first, and how many were ever dropped
  past the #{@keep}-entry bound.
  """
  @spec read() :: %{entries: [entry()], dropped: non_neg_integer()}
  @spec read(Path.t()) :: %{entries: [entry()], dropped: non_neg_integer()}
  def read(path \\ default_path()) do
    {entries, dropped, _status} = load(path)
    %{entries: entries, dropped: dropped}
  end

  @doc false
  @spec reset() :: :ok
  def reset, do: call(:reset, :ok)

  # ── Caller side ──────────────────────────────────────────────────────────

  defp resolve(path) do
    {:ok, path.()}
  catch
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    kind, reason ->
      Logger.warning(
        "[Mob.PostMortem.Journal] no journal path (#{inspect(kind)} " <>
          "#{inspect(reason, limit: 8)}); drained entries are emitted but not kept"
      )

      :error
  end

  defp emit_all(to_emit, build) do
    for {id, entry} <- to_emit,
        {capsule, delivered} <-
          Registry.emit_once(id, fn -> entry |> build.() |> Bus.emit_delivered() end),
        do: {id, capsule, delivered}
  end

  defp call(msg, fallback, timeout \\ @call_timeout) do
    GenServer.call(server(), msg, timeout)
  catch
    # The owner died mid-call, timed out, or would not start. The journal is a
    # second copy; losing it for one call must not cost the caller the first.
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    kind, reason ->
      Logger.warning(
        "[Mob.PostMortem.Journal] #{request_name(msg)} failed (#{inspect(kind)} " <>
          "#{inspect(reason, limit: 8)}); the journal was not updated"
      )

      fallback
  end

  defp request_name(msg) when is_tuple(msg), do: elem(msg, 0)
  defp request_name(msg), do: msg

  defp server do
    with nil <- Process.whereis(__MODULE__) do
      case GenServer.start(__MODULE__, nil, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end
  end

  # ── Owner ────────────────────────────────────────────────────────────────

  # State: this boot's emitted, unobserved capsules, `capsule_id => {path, id}`.
  @impl GenServer
  def init(nil) do
    flag(%{})
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:record, path, source, fresh}, _from, waiting),
    do: {:reply, record(path, source, fresh), waiting}

  def handle_call({:settle, path, seen, unseen}, _from, waiting) do
    if seen != [], do: forget(path, MapSet.new(seen))
    waiting = Enum.into(unseen, waiting, fn {capsule_id, id} -> {capsule_id, {path, id}} end)
    flag(waiting)
    {:reply, :ok, waiting}
  end

  def handle_call({:observed, capsule_ids}, _from, waiting) do
    {done, left} = Map.split(waiting, capsule_ids)

    done
    |> Enum.group_by(fn {_cid, {path, _id}} -> path end, fn {_cid, {_path, id}} -> id end)
    |> Enum.each(fn {path, ids} -> forget(path, MapSet.new(ids)) end)

    flag(left)
    {:reply, :ok, left}
  end

  def handle_call(:reset, _from, _waiting) do
    flag(%{})
    {:reply, :ok, %{}}
  end

  # Updating a `:persistent_term` costs a scan of every process, so the flag
  # changes only when the waiting set turns empty or non-empty, not per sweep.
  defp flag(waiting) do
    pending = waiting != %{}

    case {pending, :persistent_term.get(@pending, false)} do
      {same, same} -> :ok
      {true, false} -> :persistent_term.put(@pending, true)
      {false, true} -> :persistent_term.erase(@pending)
    end
  end

  # Everything `source` has journaled, then the fresh entries it has not. The
  # bound applies to what is kept, not to what is emitted: a fresh entry the
  # bound drops was still drained, and this sweep is its only chance.
  defp record(path, source, fresh) do
    {entries, dropped, status} = load(path)
    known = MapSet.new(entries, fn {_source, id, _entry} -> id end)

    new =
      fresh
      |> Enum.uniq_by(fn {id, _entry} -> id end)
      |> Enum.reject(fn {id, _entry} -> MapSet.member?(known, id) end)

    all = entries ++ Enum.map(new, fn {id, entry} -> {source, id, entry} end)
    excess = max(length(all) - @keep, 0)

    if excess > 0 do
      Logger.warning(
        "[Mob.PostMortem.Journal] #{excess} unobserved post-mortem entries dropped " <>
          "past the #{@keep}-entry bound"
      )
    end

    if excess > 0 or new != [] or status == :corrupt,
      do: store(path, Enum.drop(all, excess), dropped + excess)

    for {^source, id, entry} <- all, do: {id, entry}
  end

  defp forget(path, ids) do
    {entries, dropped, status} = load(path)
    kept = Enum.reject(entries, fn {_source, id, _entry} -> MapSet.member?(ids, id) end)
    if kept != entries or status == :corrupt, do: store(path, kept, dropped)
  end

  # ── File ─────────────────────────────────────────────────────────────────

  defp load(path) do
    case File.read(path) do
      {:ok, bin} -> decode(path, bin)
      {:error, :enoent} -> {[], 0, :ok}
      {:error, reason} -> corrupt(path, reason)
    end
  end

  defp decode(path, bin) do
    case :erlang.binary_to_term(bin, [:safe]) do
      {@magic, @version, dropped, entries} = term when is_integer(dropped) and dropped >= 0 ->
        if is_list(entries) and Enum.all?(entries, &entry?/1),
          do: {entries, dropped, :ok},
          else: corrupt(path, {:bad_term, term})

      other ->
        corrupt(path, {:bad_term, other})
    end
  rescue
    ArgumentError -> corrupt(path, :undecodable)
  end

  defp entry?({source, id, entry}), do: is_atom(source) and is_binary(id) and is_map(entry)
  defp entry?(_), do: false

  defp corrupt(path, reason) do
    Logger.warning(
      "[Mob.PostMortem.Journal] unreadable journal #{path} (#{inspect(reason, limit: 4)}); " <>
        "treating it as empty and rewriting it"
    )

    {[], 0, :corrupt}
  end

  defp store(path, entries, dropped) do
    tmp = path <> ".tmp"
    bin = :erlang.term_to_binary({@magic, @version, dropped, entries})

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- :file.open(tmp, [:write, :binary, :raw]),
         :ok <- write_synced(io, bin),
         :ok <- :file.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "[Mob.PostMortem.Journal] could not write #{path}: #{inspect(reason)}; " <>
            "entries drained this boot are emitted but not kept"
        )
    end
  end

  defp write_synced(io, bin) do
    with :ok <- :file.write(io, bin), do: :file.sync(io)
  after
    :file.close(io)
  end
end
