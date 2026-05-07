defmodule Mob.Theme.AdaptiveWatcher do
  @moduledoc """
  GenServer that re-resolves the active theme when the OS appearance flips.

  Started automatically by `use Mob.App`. Subscribes to `Mob.Device`
  `:appearance` and, on `:color_scheme_changed`, calls `Mob.Theme.set/1`
  again with whatever theme the app has registered as its "follow OS"
  theme (via `register_adaptive/1`). If no adaptive theme is registered
  the event is ignored — fixed themes stay put.

  ## Why a GenServer

  `Mob.Theme.set/1` snapshots the theme into Application env at call
  time; subsequent renders read from that env. To track an OS toggle
  while the app is foregrounded, *something* has to listen for the
  `:appearance` event and call `set/1` again. A singleton process
  fits — apps don't need per-screen handlers, and the framework owns
  the wiring end-to-end.

  ## Default registration

  When `Mob.Theme.set(Mob.Theme.Adaptive)` is called, the watcher
  picks `Mob.Theme.Adaptive` as the active follow-OS theme. To use a
  custom adaptive theme module instead, call
  `register_adaptive(MyApp.Theme.Adaptive)`.
  """

  use GenServer

  @default_adaptive Mob.Theme.Adaptive

  # ── Public API ───────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register `module` as the app's follow-OS theme. Whenever a
  `:color_scheme_changed` event arrives, the watcher calls
  `Mob.Theme.set(module)` to re-resolve.
  """
  @spec register_adaptive(module()) :: :ok
  def register_adaptive(module) when is_atom(module) do
    GenServer.cast(__MODULE__, {:register, module})
  end

  @doc false
  @spec adaptive_module() :: module()
  def adaptive_module do
    GenServer.call(__MODULE__, :adaptive)
  end

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Subscribe to Mob.Device :appearance so we hear color_scheme_changed
    # events. If Mob.Device isn't running (host BEAM, unit tests), skip
    # cleanly — set/1 still works, we just won't react to events.
    try do
      Mob.Device.subscribe(:appearance)
    catch
      :exit, _ -> :ok
    end

    {:ok, %{adaptive: @default_adaptive}}
  end

  @impl true
  def handle_call(:adaptive, _from, state) do
    {:reply, state.adaptive, state}
  end

  @impl true
  def handle_cast({:register, module}, state) do
    {:noreply, %{state | adaptive: module}}
  end

  @impl true
  def handle_info({:mob_device, :color_scheme_changed, _scheme}, state) do
    # Only re-resolve if the app's currently-active theme came from the
    # adaptive module. Re-setting other themes would clobber a user's
    # explicit choice.
    if active_is_adaptive?(state.adaptive) do
      Mob.Theme.set(state.adaptive)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The active theme matches the adaptive resolution iff calling the
  # adaptive module's theme/0 right now returns the same struct that's
  # currently in Application env. Cheap struct equality check.
  defp active_is_adaptive?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :theme, 0) and
      Mob.Theme.current() == module.theme()
  end
end
