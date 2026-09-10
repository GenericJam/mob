defmodule Mob.Invariant.Violation do
  @moduledoc """
  One confirmed invariant breach.

  `details` carries **no application state** — pids, module names and counts
  only. A violation is written to ETS and is a defect-report input, and the sink
  policy in `decisions/2026-09-04-defect-reports-are-a-shipped-feature.md`
  excludes assigns by default. The same rule `Mob.Agent.Receipt` follows, for
  the same reason: MOB-147 found a `SecureField` value crossing screens, so
  anything that serialises framework state has to assume secrets are in it.
  """

  @type t :: %__MODULE__{
          invariant: atom(),
          severity: Mob.Invariant.severity(),
          at: Mob.Invariant.point(),
          details: map(),
          screen: module() | nil,
          monotonic_us: integer()
        }

  defstruct [:invariant, :severity, :at, :details, :screen, :monotonic_us]

  @doc "A one-line summary for a triage log."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = v) do
    "[#{v.severity}] #{v.invariant} at #{v.at}" <>
      if(v.screen, do: " in #{inspect(v.screen)}", else: "") <>
      " — #{inspect(v.details, limit: 8)}"
  end
end
