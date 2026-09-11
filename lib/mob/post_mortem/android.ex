defmodule Mob.PostMortem.Android do
  @moduledoc """
  `ApplicationExitInfo`-backed post-mortem ingest for Android.

  ## Status: scaffolded, not implemented

  `sweep/0` returns `[]` today. The native pipe — an
  `ActivityManager.getHistoricalProcessExitReasons` call on next boot,
  filtered against a persistent marker so each reason is emitted exactly
  once — is a follow-up ticket with its own device-verification loop.
  This module exists as the symbol `Mob.PostMortem.sweep/0` calls into
  so the coordinator does not have to grow a per-platform branch when
  the native side lands.

  ## The intended contract, for when it does land

  * Called on any node, but does its work only when `:mob_nif.platform/0`
    returns `:android` and the OS is API 30+ (Android 11+, where
    `ApplicationExitInfo` exists).
  * Each historical exit reason becomes one `Mob.Defect.Capsule` on the
    bus, with `kind: :anr` / `:oom` / `:user_kill` / `:native_crash`
    picked from the reason code, and `owner: :mob`.
  * Deduplication is on `pid + timestamp` per reason, recorded in
    per-app storage so a subsequent boot never re-emits an old exit
    even if the OS still lists it.
  * Redaction: an ANR's trace file contents can carry app strings.
    Trace inclusion is bounded (the same 4KB cap the capsule already
    enforces) and clipped in the native layer before the capsule is
    built. The persistent marker records only the reason id, never
    the trace text.
  """

  require Logger

  alias Mob.Defect.Capsule

  @doc """
  Sweep any ApplicationExitInfo entries the OS has recorded since the
  last call.

  Returns the list of capsules emitted (empty until the native pipe is
  in place; today it is always `[]`).

  Logs at `:info` on first call so an operator running
  `mix mob.post_mortems.sweep` on an Android-target host can see the
  "not yet wired" state rather than getting silence and wondering.
  """
  @spec sweep() :: [Capsule.t()]
  def sweep do
    if :persistent_term.get({__MODULE__, :logged_scaffold_notice}, false) do
      :ok
    else
      Logger.info(
        "[Mob.PostMortem.Android] ApplicationExitInfo ingest is scaffolded; sweep " <>
          "returns [] until the native getHistoricalProcessExitReasons pipe lands " <>
          "(MOB-158 follow-up)."
      )

      :persistent_term.put({__MODULE__, :logged_scaffold_notice}, true)
    end

    []
  end
end
