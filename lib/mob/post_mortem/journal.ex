defmodule Mob.PostMortem.Journal do
  # Constants first so the moduledoc can interpolate them.
  @file_name "mob_post_mortem_journal.etf"
  @keep 32
  @pending {__MODULE__, :pending}

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
  every sweep, including the first sweep of the next boot. An entry leaves the
  journal once it has been observed on the bus: its capsule was delivered to a
  subscriber, or a reader asked the bus (`Mob.Defect.Bus.recent/1`,
  `classes/1` or `subscribe/1`) after it was emitted. Within one boot,
  `Mob.PostMortem.Registry.emit_once/2` keeps a re-sweep from emitting an entry
  twice.

  BEAM crash dumps are not journaled: the dump itself stays on disk and is
  swept again every boot.

  ## Bounded and never fatal

  The journal holds at most #{@keep} entries. Past that the oldest are dropped
  and counted (`read/1`'s `dropped`), and a warning is logged; a sweep still
  emits everything it drained. A journal that cannot be decoded is treated as
  empty, logged, and overwritten by the same sweep, so the warning appears
  once. Writes go to a temporary file that is synced and renamed over the
  journal. Nothing here raises into a sweep or a bus reader.
  """

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
  through `Registry.emit_once/2` and `emit`.

  `path` is resolved lazily, so a data directory that cannot be resolved costs
  the journal, not the sweep. Returns the capsules emitted.
  """
  @spec sweep((-> Path.t()), atom(), [{String.t(), map()}], (map() -> Capsule.t())) ::
          [Capsule.t()]
  def sweep(path, source, fresh, emit)
      when is_function(path, 0) and is_atom(source) and is_list(fresh) and
             is_function(emit, 1) do
    case resolve(path) do
      {:ok, path} ->
        to_emit = locked(fn -> journal(path, source, fresh) end)
        {capsules, emitted} = emit_all(to_emit, emit)
        track(path, emitted)
        capsules

      :error ->
        fresh |> emit_all(emit) |> elem(0)
    end
  end

  @doc """
  Clear every journaled entry emitted at or before bus sequence `through`.

  `Mob.Defect.Bus` calls this when it has been observed through `through`.
  Unless this boot emitted journaled entries that are still unobserved, it is
  one `:persistent_term` read. Never raises.
  """
  @spec observed(non_neg_integer()) :: :ok
  def observed(through) when is_integer(through) do
    case :persistent_term.get(@pending, nil) do
      nil -> :ok
      pending -> if any_observed?(pending, through), do: locked(fn -> clear(through) end)
    end

    :ok
  catch
    # Called from the bus's emit fanout and readers: a journal failure must not
    # become theirs.
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    kind, reason ->
      Logger.warning(
        "[Mob.PostMortem.Journal] clearing observed entries failed: " <>
          "#{inspect(kind)} #{inspect(reason, limit: 8)}"
      )

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
  def reset do
    :persistent_term.erase(@pending)
    :ok
  end

  # ── Sweep ────────────────────────────────────────────────────────────────

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

  defp journal(path, source, fresh) do
    record(path, source, fresh)
  catch
    # The journal is a second copy; failing to keep it must not cost the
    # sweep the first.
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    kind, reason ->
      Logger.warning(
        "[Mob.PostMortem.Journal] journaling failed (#{inspect(kind)} " <>
          "#{inspect(reason, limit: 8)}); drained entries are emitted but not kept"
      )

      fresh
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

  # The bus sequence is read after each emit, so it is at or past the
  # capsule's own: an observation that covers it covers the capsule.
  defp emit_all(to_emit, emit) do
    emitted =
      for {id, entry} <- to_emit, capsule <- Registry.emit_once(id, fn -> emit.(entry) end) do
        {capsule, {id, Bus.emitted_seq()}}
      end

    Enum.unzip(emitted)
  end

  # Register the emitted ids as pending, then check the bus once: a capsule
  # delivered to a subscriber during its own emit was observed before it was
  # pending here, and the bus's watermark is the only record of that.
  defp track(_path, []), do: :ok

  defp track(path, emitted) do
    locked(fn ->
      pending = :persistent_term.get(@pending, %{})
      ids = Map.merge(Map.get(pending, path, %{}), Map.new(emitted))
      :persistent_term.put(@pending, Map.put(pending, path, ids))
    end)

    observed(Bus.observed_seq())
  end

  # ── Clearing ─────────────────────────────────────────────────────────────

  defp any_observed?(pending, through) do
    Enum.any?(pending, fn {_path, ids} -> Enum.any?(ids, fn {_id, seq} -> seq <= through end) end)
  end

  defp clear(through) do
    pending = :persistent_term.get(@pending, %{})

    remaining =
      for {path, ids} <- pending, reduce: %{} do
        acc ->
          {done, left} = Map.split_with(ids, fn {_id, seq} -> seq <= through end)
          if done != %{}, do: forget(path, done)
          if left == %{}, do: acc, else: Map.put(acc, path, left)
      end

    cond do
      remaining == pending -> :ok
      remaining == %{} -> :persistent_term.erase(@pending)
      true -> :persistent_term.put(@pending, remaining)
    end
  end

  defp forget(path, done) do
    {entries, dropped, status} = load(path)
    kept = Enum.reject(entries, fn {_source, id, _entry} -> Map.has_key?(done, id) end)
    if kept != entries or status == :corrupt, do: store(path, kept, dropped)
  end

  # ── File ─────────────────────────────────────────────────────────────────

  # Every read-modify-write of the file and the pending map runs under one
  # node-local lock: two sweeps, or a sweep and a bus reader, would otherwise
  # each write back what they read and lose the other's entries.
  defp locked(fun), do: :global.trans({__MODULE__, self()}, fun, [node()])

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
