defmodule Mob.Defect do
  @moduledoc """
  Entry points that convert what the framework's detectors produce into
  capsules on the defect bus.

  The framework's detectors have their own shapes — an invariant violation is
  a `Mob.Invariant.Violation`, a divergence is the `{:divergence, %{...}}` a
  comparator returns. Rather than teach each detector to build a capsule,
  those detectors call the appropriate function here and this module supplies
  the fingerprint key, the owner, and the evidence shape.

  Centralising the mapping is what keeps `owner: :mob` from being copied into
  five places, and what makes the fingerprint key for the same kind of defect
  identical across detectors — the whole point of a fingerprint is that a
  divergence detected on iOS from mob_dev and the same divergence detected
  on-device from a fallback path land on the same triage item.

  ## Nothing propagates on the return path

  Every function here returns the capsule it built, but the emit is a
  side-effect on the bus and the caller does not need to do anything with
  the return value. That matches the shape of `Mob.Agent.Receipts.record/1`
  and lets a caller drop the emit onto an existing pipeline without
  restructuring around a result.
  """

  alias Mob.Defect.{Bus, Capsule}

  @doc """
  Emit a defect for a confirmed invariant violation.

  Owner is `:mob` — invariants are checks the framework makes about itself,
  and by construction they cannot fail for the app. `kind: :invariant`.

  The fingerprint key is `%{invariant: name, screen: screen_module}`, so a
  violation of the same invariant on the same screen groups across
  occurrences, and the same invariant on a different screen — a leak class
  that appears in two places — reports separately.
  """
  @spec emit_invariant_violation(Mob.Invariant.Violation.t()) :: Capsule.t()
  def emit_invariant_violation(%Mob.Invariant.Violation{} = v) do
    Capsule.new(
      kind: :invariant,
      owner: :mob,
      severity: v.severity,
      fingerprint_key: %{invariant: v.invariant, screen: v.screen},
      evidence: %{
        invariant: v.invariant,
        screen: v.screen,
        at: v.at,
        details: v.details
      }
    )
    |> Bus.emit()
  end

  @doc """
  Emit a defect for a differential-comparator divergence.

  Owner is `:mob` — the differential comparator asserts one design, both
  platforms, which is a framework-level promise. `kind: :divergence`.

  The fingerprint key includes the fixture (so the same divergence in two
  fixtures reports separately), the `reason` (`:type`, `:label`, `:frame`,
  `:child_count`), and the `path` to the diverging node. The `ios` and
  `android` values are on evidence, not on the fingerprint key — a fixture's
  divergence in kind (say, always `:type` at `[0, 2]`) is the same class
  even if the tree values change slightly across releases.
  """
  @spec emit_divergence(map(), keyword() | map()) :: Capsule.t()
  def emit_divergence(%{path: path, reason: reason, ios: ios, android: android}, opts \\ []) do
    opts = Map.new(opts)
    fixture = Map.get(opts, :fixture)

    Capsule.new(
      kind: :divergence,
      owner: :mob,
      severity: Map.get(opts, :severity, :warning),
      fingerprint_key: %{fixture: fixture, reason: reason, path: path},
      evidence: %{
        fixture: fixture,
        reason: reason,
        path: path,
        ios: ios,
        android: android
      }
    )
    |> Bus.emit()
  end
end
