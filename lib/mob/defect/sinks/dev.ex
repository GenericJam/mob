defmodule Mob.Defect.Sinks.Dev do
  @moduledoc """
  A defect sink that formats every emitted capsule as a Logger line.

  Not started by default — per
  `decisions/2026-09-04-defect-reports-are-a-shipped-feature.md`, `mob` is
  never the collector, and a sink that runs unbidden would violate that. An
  app opts in explicitly:

      Mob.Defect.Sinks.Dev.start_link()

  or under its own supervision tree:

      children = [
        # ... app children ...
        Mob.Defect.Sinks.Dev
      ]

  It is `Dev` because Logger output is the medium the connected-agent workflow
  already uses — `mix mob.connect` streams the device's Logger output into
  the agent's IEx session, so a defect logged here reaches the agent for
  free. An app that wants a *production* sink (a remote endpoint, a file, a
  push channel, or nothing) writes their own subscriber; the API is
  `Mob.Defect.Bus.subscribe/0` plus a `handle_info({:mob_defect, capsule}, ...)`.

  ## What it logs

  * `severity: :fatal | :critical` → `Logger.error`
  * `severity: :warning` → `Logger.warning`
  * anything else → `Logger.info`

  The severity mapping is what routes a real bug to the log level a triager
  reads first. `Logger.info` for everything would bury a fatal alongside a
  perf regression; `Logger.error` for everything would train the reader to
  ignore the channel — exactly what the redaction and dedup work goes into
  preventing.
  """

  use GenServer

  require Logger

  alias Mob.Defect.Bus
  alias Mob.Defect.Capsule

  @doc "Start the sink under `name`, defaulting to the module."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(_opts) do
    {:ok, _ref} = Bus.subscribe()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:mob_defect, %Capsule{} = c}, state) do
    log(c)
    {:noreply, state}
  end

  # Anything else is not for us. A defensive catch-all — a subscriber that
  # crashes on an unexpected message would be pruned from the fanout list on
  # the next tick, silently going dark. Log-and-ignore keeps the sink alive.
  @impl GenServer
  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, _state) do
    # `Bus.unsubscribe/1` calls `Bus.Owner.start/0` transparently before its
    # `GenServer.call`, so a dead owner is usually restarted rather than
    # observed. The try/catch here is a narrow guard for the corner where
    # even that restart fails — a supervised BEAM shutdown that has
    # unregistered `:proc_lib`, a spawn refused because the process cap has
    # been hit while draining. In practice this catch fires zero times in
    # normal operation, and the tests do not exercise it (a mock-restart
    # scenario would only test the mock, not the runtime); it stays because
    # the alternative is a spurious `:exit` in a terminate that scares a
    # reader looking at a shutdown log.
    try do
      Bus.unsubscribe()
    catch
      :exit, {:noproc, _} -> :ok
      :exit, :noproc -> :ok
    end

    :ok
  end

  defp log(%Capsule{severity: sev} = c) when sev in [:fatal, :critical],
    do: Logger.error(Capsule.describe(c))

  defp log(%Capsule{severity: :warning} = c),
    do: Logger.warning(Capsule.describe(c))

  defp log(%Capsule{} = c),
    do: Logger.info(Capsule.describe(c))
end
