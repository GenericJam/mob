defmodule Mob.Theme.AdaptiveWatcher do
  @moduledoc """
  GenServer that re-resolves the active theme when the OS appearance flips.

  Started automatically by `use Mob.App`. Subscribes to `Mob.Device`
  `:appearance` and, on `:color_scheme_changed`, calls `Mob.Theme.set/1`
  again with the theme the app registered as its "follow OS" theme (via
  `register_adaptive/1`), but only while the active theme was set from that
  module. Any other active theme stays put.

  ## Which `Mob.Theme.set/1` calls follow the OS

  With `MyApp.Theme.Adaptive` registered:

  - `Mob.Theme.set(MyApp.Theme.Adaptive)` follows the OS.
  - `Mob.Theme.set({MyApp.Theme.Adaptive, primary: :rose_500})` follows the
    OS and keeps the overrides on every flip.
  - A struct (`Mob.Theme.set(MyApp.Theme.Adaptive.theme())`), a keyword
    list, or any other module is a fixed theme: the flip leaves it alone.

  ## Why a GenServer

  `Mob.Theme.set/1` snapshots the theme into Application env at call
  time; subsequent renders read from that env. To track an OS toggle
  while the app is foregrounded, *something* has to listen for the
  `:appearance` event and call `set/1` again. A singleton process
  fits — apps don't need per-screen handlers, and the framework owns
  the wiring end-to-end.

  ## Default registration

  `Mob.Theme.Adaptive` is registered by default, so
  `Mob.Theme.set(Mob.Theme.Adaptive)` (or `use Mob.App, theme:
  Mob.Theme.Adaptive`) follows the OS with no further setup. To use a
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
  `:color_scheme_changed` event arrives while the active theme was set
  from `module` (or `{module, overrides}`), the watcher calls
  `Mob.Theme.set/1` with it again to re-resolve.
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
    # Re-resolve only when the active theme was set from the adaptive module.
    # Re-setting anything else would clobber the app's explicit choice.
    # Judged by what was passed to set/1, not by comparing current() with
    # adaptive.theme(): by the time this event arrives the OS has already
    # flipped, so theme/0 returns the NEW scheme's theme and never equals the
    # still-old active one.
    case Mob.Theme.source() do
      adaptive when adaptive == state.adaptive -> Mob.Theme.set(adaptive)
      {adaptive, _overrides} = source when adaptive == state.adaptive -> Mob.Theme.set(source)
      _fixed -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
