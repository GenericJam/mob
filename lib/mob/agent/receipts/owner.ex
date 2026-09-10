defmodule Mob.Agent.Receipts.Owner do
  @moduledoc """
  Owns the receipts ETS table, and does nothing else.

  An ETS table dies with the process that created it. The first version created
  it lazily from `record/1`, which runs inside `Mob.Screen.Server.handle_call` —
  so the owner was whichever screen happened to dispatch the first event of the
  app's life, and every held receipt was destroyed when that screen was popped.
  Not at 256, at zero, with `dropped/0` still reporting 0 — exactly the
  "no receipt for that id" ambiguity `Mob.Agent.Receipts` says it eliminates.

  Worse in the case that matters most: if the screen owning the table is the one
  whose handler raises, the crash receipt written on the way out is destroyed
  microseconds later by the same crash.

  Started with `GenServer.start/3` rather than `start_link/3`, and never linked:
  a diagnostic must not take a screen down with it, and must not die when one
  dies. `mob` has no supervision tree of its own — it is a library inside
  someone else's app — so `Mob.Agent.Receipts.start/0` starts this on demand and
  tolerates `{:error, {:already_started, _}}`, the same shape
  `Mob.Test.ProcessHelpers.ensure_component_registry/0` uses for the same reason.
  """

  use GenServer

  @table :mob_agent_receipts
  @state :mob_agent_receipts_state

  @doc false
  @spec start() :: {:ok, pid()}
  def start do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Re-run initialisation: re-resolve the telemetry module and recreate the table
  if it is missing.

  For tests that change `:telemetry_module`, and as self-healing if anything
  deletes the table out from under the owner. Not on any hot path.
  """
  @spec reload() :: :ok
  def reload do
    {:ok, pid} = start()
    GenServer.call(pid, :reload)
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    setup()
    {:reply, :ok, state}
  end

  @impl GenServer
  def init(_opts) do
    setup()
    {:ok, %{}}
  end

  defp setup do
    # State before the table, and the table is the flag: the reverse order
    # leaves a window in which another process sees the table, skips
    # initialisation, and reads a `:persistent_term` key that does not exist —
    # which raises on the event path, inside the very `catch` clause recording a
    # crash. A state entry with no table is harmless; a table with no state is
    # not.
    :persistent_term.put(@state, %{
      seq: :atomics.new(2, signed: false),
      telemetry?: telemetry_available?()
    })

    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, {:write_concurrency, true}])
    end

    :ok
  end

  # Resolved once, here, and never again. `Code.ensure_loaded?/1` for an ABSENT
  # module is not cached: it is a `gen_server` call into `:code_server` plus a
  # scan of the code path, measured at ~6-12us against ~0.03us for a loaded one.
  # `mob` has no `:telemetry` dependency, so absent is the default case, and
  # calling it per action would put every event in every app through one global
  # mailbox — which is what `Mob.Agent.Receipts` documents itself as avoiding.
  defp telemetry_available? do
    mod = Application.get_env(:mob, :telemetry_module, :telemetry)
    Code.ensure_loaded?(mod) and function_exported?(mod, :execute, 3)
  end
end
