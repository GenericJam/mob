defmodule Mob.PostMortem.IOS do
  @moduledoc """
  MetricKit-backed post-mortem ingest for iOS.

  ## Status: scaffolded, not implemented

  `sweep/0` returns `[]` today. The native pipe — an `MXMetricManager`
  delegate that receives `MXCrashDiagnosticPayload`,
  `MXHangDiagnosticPayload`, `MXCPUExceptionDiagnosticPayload`,
  `MXDiskWriteExceptionDiagnosticPayload`, `MXAppLaunchDiagnosticPayload`
  and `MXCallStackTree` values — is a follow-up ticket with its own
  device-verification loop. This module exists as the symbol
  `Mob.PostMortem.sweep/0` calls into so the coordinator does not have
  to grow a per-platform branch when the native side lands.

  ## The intended contract, for when it does land

  * Called on any node, but does its work only when `:mob_nif.platform/0`
    returns `:ios` and MetricKit reports at least one delivered payload.
  * Each MetricKit payload becomes one `Mob.Defect.Capsule` on the bus,
    with `owner: :mob` or `owner: {:plugin, ...}` depending on the
    payload's process attribution.
  * Payload delivery is asynchronous in iOS (up to 24 hours after the
    incident); MetricKit itself deduplicates by day, and the capsule
    fingerprint takes over from there. This module never polls; it
    receives via the delegate and pushes into the bus.
  * Redaction: the schema promises `redaction: :applied`. MetricKit's
    call-stack payloads carry mangled symbol names, which are the safe
    identifiers we keep; the file path portions and any embedded user
    data are stripped in the native layer before the capsule is built.
  """

  require Logger

  alias Mob.Defect.Capsule

  @doc """
  Sweep any MetricKit payloads the OS has delivered since the last call.

  Returns the list of capsules emitted (empty until the native pipe is
  in place; today it is always `[]`).

  Logs at `:info` on first call so an operator running `mix mob.post_mortems.sweep`
  on an iOS host can see the "not yet wired" state rather than getting
  silence and wondering.
  """
  @spec sweep() :: [Capsule.t()]
  def sweep do
    if :persistent_term.get({__MODULE__, :logged_scaffold_notice}, false) do
      :ok
    else
      Logger.info(
        "[Mob.PostMortem.IOS] MetricKit ingest is scaffolded; sweep returns [] until " <>
          "the native MXMetricManager delegate lands (MOB-158 follow-up)."
      )

      :persistent_term.put({__MODULE__, :logged_scaffold_notice}, true)
    end

    []
  end
end
