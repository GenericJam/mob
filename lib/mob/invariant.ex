defmodule Mob.Invariant do
  @moduledoc """
  Checks the framework can make about itself, and the rule that stops them
  becoming noise.

  An application cannot assert that a component's owning screen is still alive,
  or that no dead screen is sitting in the navigation stack — it does not have
  the handles. The framework does, each check is a few microseconds, and each
  one guards a class of bug that recent releases kept re-fixing.

  ## A violation must survive to the next sample

  This is the whole design, not a refinement. Every check here reads *live*
  state from processes that are concurrently changing: a screen mid-teardown has
  a dead pid and components that have not yet been reaped, and a check sampling
  that instant sees a violation that resolves itself shortly afterwards.
  Reporting it produces a defect nobody can reproduce, which is worse than
  reporting nothing — it teaches the reader to ignore the channel.

  So the first sighting of a violation is held as a **candidate**, and it is
  recorded only when two things are true: the *same* violation is still there at
  the next sampling of that point, **and** the candidate is at least 50ms old.

  Both halves are needed, and the second was not obvious. Sampling points are
  event-driven — the router stops screens in a tight loop, so during a
  multi-screen reset "the next sample" can arrive in under a millisecond, and a
  component still being reaped is seen twice. Surviving one teardown is
  therefore *not* proof of anything; surviving 50ms is, because a real leak
  persists indefinitely and does not notice the wait. With deferral alone,
  healthy teardowns still produced about one confirmed violation in sixty.

  The floor is `:mob, :invariant_min_candidate_age_us` for a device whose
  teardown outlasts the default.

  The first version of this re-ran the check immediately instead, back to back
  in the same process. That was measured and it filtered nothing: the gap
  between the two calls is about a microsecond and the transients it was meant
  to catch last tens to hundreds, so it suppressed ~0% of them while reporting
  a confirmed `:critical` on healthy teardowns. Two evaluations a microsecond
  apart cannot disagree, which made the rule an assertion about nothing.

  Sameness is by fingerprint over the violation's details, so a *different*
  transient at the next sample does not confirm the first one.

  That makes the checks themselves a contract: a check must be *deterministic
  over stable state*, and its details must identify the violation rather than
  describe the moment. One that samples something genuinely time-varying — a
  timestamp, a queue length — cannot be expressed here, and should not be.

  ## It ships in release builds

  Per `decisions/2026-09-04-defect-reports-are-a-shipped-feature.md`, the
  interesting failures happen where no agent is watching. That makes the cost
  real rather than theoretical, so it is budgeted rather than discovered on
  someone's three-year-old Android: see `cost_us/2`, and the numbers in
  `decisions/2026-09-10-an-invariant-must-survive-to-the-next-sample.md`.

  ## Registering

      Mob.Invariant.register(:my_check,
        at: :on_screen_stop,
        severity: :critical,
        check: fn context -> ... end
      )

  A check returns `:ok`, `{:violation, details}`, or `{:violations, [details]}`
  where each `details` is a map carrying **no application state** — the same rule
  receipts follow. Pids, module names and counts are fine; assigns are not.

  **Report independent problems separately.** A check that finds three leaked
  components should return three violations, not one carrying a list. Each
  matures on its own; rolled into one, the details change whenever any of them
  does, the fingerprint changes with it, and nothing ever confirms.
  """

  alias Mob.Invariant.Violation

  @type point :: :after_committed_frame | :on_screen_stop | :periodic
  @type severity :: :critical | :warning
  @type context :: map()
  @type result :: :ok | {:violation, map()} | {:violations, [map()]}

  @table :mob_invariants
  @violations :mob_invariant_violations
  @candidates :mob_invariant_candidates
  @keep 128

  # A candidate must also be this old before it can be confirmed. Sampling
  # points are event-driven, so "the next sample" can arrive almost immediately
  # — during a multi-screen teardown the router stops screens in a tight loop,
  # and a component still being reaped can be seen twice in under a millisecond.
  # A real leak persists indefinitely and does not notice the wait; a reap in
  # progress does. Measured: without this, healthy teardowns still produced
  # about one confirmed violation in sixty.
  @default_min_candidate_age_us 50_000

  @doc false
  @spec start() :: :ok
  def start do
    if :ets.whereis(@table) == :undefined, do: Mob.Invariant.Owner.start()
    :ok
  end

  @doc """
  Register a check.

  Re-registering the same name replaces the previous definition, so a hot code
  push does not accumulate duplicates.
  """
  @spec register(atom(), keyword()) :: :ok
  def register(name, opts) when is_atom(name) do
    start()

    :ets.insert(
      @table,
      {name,
       %{
         name: name,
         at: Keyword.fetch!(opts, :at),
         severity: Keyword.get(opts, :severity, :warning),
         check: Keyword.fetch!(opts, :check)
       }}
    )

    :ok
  end

  @doc "Forget a check."
  @spec unregister(atom()) :: :ok
  def unregister(name) do
    start()
    :ets.delete(@table, name)
    # Its candidates too — nothing will ever sample this name again, so they
    # would sit in the table for the life of the owner.
    :ets.match_delete(@candidates, {{name, :_}, :_})
    :ok
  end

  @doc "Every check registered for `point`."
  @spec registered(point()) :: [map()]
  def registered(point) do
    start()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, spec} -> spec end)
    |> Enum.filter(&(&1.at == point))
  end

  @doc """
  Run every check registered for `point` against `context`.

  Returns the violations confirmed by this run: ones also seen at the previous
  sampling of `point` **and** whose candidacy is at least
  `:mob, :invariant_min_candidate_age_us` old (50ms by default). A violation
  seen for the first time, or too recently, is held as a candidate and returns
  nothing. Never
  raises: a check that blows up is itself reported as a violation of
  `:invariant_check_failed` rather than being allowed to take down the process
  that was kind enough to sample.
  """
  @spec run(point(), context()) :: [Violation.t()]
  def run(point, context \\ %{}) do
    point
    |> registered()
    |> Enum.flat_map(&evaluate(&1, context))
    |> Enum.map(&record/1)
  end

  @doc """
  The violations held, newest first.
  """
  @spec violations(pos_integer()) :: [Violation.t()]
  def violations(limit \\ 20) do
    start()

    @violations
    |> :ets.tab2list()
    |> Enum.sort_by(fn {seq, _v} -> -seq end)
    |> Enum.take(limit)
    |> Enum.map(fn {_seq, v} -> v end)
  end

  @doc "How many violations are held."
  @spec violation_count() :: non_neg_integer()
  def violation_count do
    start()
    :ets.info(@violations, :size)
  end

  @doc """
  Microseconds to run every check registered for `point` once, measured now.

  For budgeting on the device that matters rather than on a laptop. Runs the
  checks for real, so it observes whatever the app is currently doing.

  This is one pass of each check. A sampling point also does candidate
  bookkeeping and, on confirmation, a record — so a real sample costs somewhat
  more than this reports. The table in the decision record is measured through
  `run/2` and is the number to budget against.
  """
  @spec cost_us(point(), context()) :: non_neg_integer()
  def cost_us(point, context \\ %{}) do
    {us, _} = :timer.tc(fn -> point |> registered() |> Enum.each(&safe_check(&1, context)) end)
    us
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    # Objects first, THEN reload — the reverse order wiped the built-ins that
    # `Owner.setup/0` had just installed, leaving the framework's shipped
    # diagnostics permanently off for the life of the owner.
    for t <- [@table, @violations, @candidates] do
      if :ets.whereis(t) != :undefined, do: :ets.delete_all_objects(t)
    end

    Mob.Invariant.Owner.reload()
    :atomics.put(seq(), 1, 0)
    :ok
  end

  # Confirmation is deferred to the next sampling of this point — see the
  # moduledoc. Candidacy is per *violation*, not per check, and that granularity
  # is load-bearing: keyed by check name alone, any check whose details change
  # between samples could never confirm, because each sample replaced the
  # candidate and restarted its clock. A leak that grows — which is exactly what
  # a broken reaping path produces, one more orphan per navigation — was seen on
  # 59 of 60 samples and reported zero times.
  defp evaluate(spec, context) do
    case safe_check(spec, context) do
      :ok ->
        :ets.match_delete(@candidates, {{spec.name, :_}, :_})
        []

      {:violations, all_details} ->
        now = System.monotonic_time(:microsecond)
        by_fingerprint = Map.new(all_details, &{:erlang.phash2({spec.name, &1}), &1})

        # A candidate whose violation is no longer present has resolved. Dropping
        # it is what stops an appear/disappear/reappear sequence confirming
        # something that was never continuously there.
        prune_candidates(spec.name, Map.keys(by_fingerprint))

        Enum.flat_map(by_fingerprint, fn {fingerprint, details} ->
          mature(spec, fingerprint, details, context, now)
        end)
    end
  end

  defp mature(spec, fingerprint, details, context, now) do
    key = {spec.name, fingerprint}

    case :ets.lookup(@candidates, key) do
      [{^key, first_seen}] ->
        if now - first_seen >= min_candidate_age_us() and claim(key, first_seen) do
          [violation(spec, details, context)]
        else
          []
        end

      [] ->
        :ets.insert_new(@candidates, {key, now})
        []
    end
  end

  # Compare-and-delete on the exact `{key, first_seen}` pair. Only one sampler
  # can remove that row, so concurrent samplers cannot both report the same
  # candidate — and, crucially, **nothing ever writes a first_seen back**.
  #
  # The previous version used `:ets.take/2` and re-inserted the row when it was
  # too young. That looks atomic and is not: with three samplers in flight, one
  # takes the row, a second sees absence and inserts a fresh `now`, a third takes
  # *that* and writes it back — so the candidate's age kept resetting and a
  # permanently-present violation was never confirmed at all. Measured through
  # `run/2`: 1 sampler 39 confirmations, 2 samplers 34, **4 samplers zero**.
  #
  # This is not a theoretical race. `Mob.Router` `start_link`s its screens, so a
  # router exit runs `terminate/2` — and this sampling point — in every live
  # screen at once.
  defp claim(key, first_seen) do
    :ets.select_delete(@candidates, [{{key, first_seen}, [], [true]}]) == 1
  end

  # `:set` tables cannot match on a partially bound key, so this scans the whole
  # candidates table rather than just this check's rows. The live set is bounded
  # by the number of violations a check reports (capped at 8 for the built-ins),
  # so that is a handful of rows — but it is why `unregister/1` above has to
  # clear its own candidates rather than leaving them to be pruned.
  defp prune_candidates(name, keep) do
    keep = MapSet.new(keep)

    @candidates
    |> :ets.match_object({{name, :_}, :_})
    |> Enum.each(fn {{_name, fingerprint} = key, _first_seen} ->
      if not MapSet.member?(keep, fingerprint), do: :ets.delete(@candidates, key)
    end)
  end

  # Normalised to a list so `evaluate/2` has one shape to reason about. A check
  # that can report several independent violations — one per leaked component,
  # say — must return them separately, or they share a fingerprint and mature
  # as a single lump that changes every time one of them does.
  defp safe_check(spec, context) do
    case spec.check.(context) do
      :ok -> :ok
      {:violation, details} when is_map(details) -> {:violations, [details]}
      {:violations, []} -> :ok
      {:violations, list} when is_list(list) -> {:violations, list}
    end
  rescue
    e -> {:violations, [%{invariant_check_failed: spec.name, exception: e.__struct__}]}
  catch
    kind, _ -> {:violations, [%{invariant_check_failed: spec.name, exit: kind}]}
  end

  defp violation(spec, details, context) do
    %Violation{
      invariant: spec.name,
      severity: spec.severity,
      at: spec.at,
      details: details,
      screen: Map.get(context, :screen_module),
      monotonic_us: System.monotonic_time(:microsecond)
    }
  end

  defp record(%Violation{} = violation) do
    start()
    seq = :atomics.add_get(seq(), 1, 1)
    :ets.insert(@violations, {seq, violation})

    if :ets.info(@violations, :size) > @keep do
      :ets.select_delete(@violations, [{{:"$1", :_}, [{:<, :"$1", seq - @keep + 1}], [true]}])
    end

    # A confirmed violation is a defect by definition — the maturation logic
    # above is precisely the "this is real, not a transient" gate. Emit as a
    # capsule so subscribers on the bus (a dev sink, an app's own reporter)
    # see it. See `Mob.Defect.emit_invariant_violation/1`.
    Mob.Defect.emit_invariant_violation(violation)

    violation
  end

  defp seq, do: :persistent_term.get(:mob_invariant_state).seq

  # Configurable so a test can sample twice without waiting, and so an app on a
  # slow device can raise it if teardown there outlasts the default.
  defp min_candidate_age_us,
    do: Application.get_env(:mob, :invariant_min_candidate_age_us, @default_min_candidate_age_us)
end
