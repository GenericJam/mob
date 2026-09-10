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
  recorded only if the *same* violation is still there at the next sampling of
  that point. Something that has survived a whole screen teardown, or a whole
  periodic tick, is not a scheduling artefact.

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

  A check returns `:ok`, or `{:violation, details}` where `details` is a map
  carrying **no application state** — the same rule receipts follow. Pids,
  module names and counts are fine; assigns are not.
  """

  alias Mob.Invariant.Violation

  @type point :: :after_committed_frame | :on_screen_stop | :periodic
  @type severity :: :critical | :warning
  @type context :: map()
  @type result :: :ok | {:violation, map()}

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

  Returns the violations confirmed by this run — that is, ones also seen at the
  previous sampling of `point`. A violation seen for the first time is held as a
  candidate and returns nothing. Never
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
  # moduledoc. Re-running the check here instead would compare two observations
  # a microsecond apart, which is far shorter than the transients being
  # filtered.
  defp evaluate(spec, context) do
    case safe_check(spec, context) do
      :ok ->
        # No violation now, so any candidate for this check was transient.
        :ets.delete(@candidates, spec.name)
        []

      {:violation, details} ->
        fingerprint = :erlang.phash2({spec.name, details})

        now = System.monotonic_time(:microsecond)

        case :ets.lookup(@candidates, spec.name) do
          [{_name, ^fingerprint, first_seen}] ->
            if now - first_seen >= min_candidate_age_us() do
              :ets.delete(@candidates, spec.name)
              [violation(spec, details, context)]
            else
              # Same violation, but not yet old enough to be distinguished from
              # work in progress. The original first-seen is kept so a later
              # sample can confirm it.
              []
            end

          _ ->
            # First sighting, or a *different* violation than last time — which
            # is a new candidate rather than a confirmation of the old one.
            :ets.insert(@candidates, {spec.name, fingerprint, now})
            []
        end
    end
  end

  defp safe_check(spec, context) do
    case spec.check.(context) do
      :ok -> :ok
      {:violation, details} when is_map(details) -> {:violation, details}
    end
  rescue
    e -> {:violation, %{invariant_check_failed: spec.name, exception: e.__struct__}}
  catch
    kind, _ -> {:violation, %{invariant_check_failed: spec.name, exit: kind}}
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

    violation
  end

  defp seq, do: :persistent_term.get(:mob_invariant_state).seq

  # Configurable so a test can sample twice without waiting, and so an app on a
  # slow device can raise it if teardown there outlasts the default.
  defp min_candidate_age_us,
    do: Application.get_env(:mob, :invariant_min_candidate_age_us, @default_min_candidate_age_us)
end
