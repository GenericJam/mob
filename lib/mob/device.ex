defmodule Mob.Device do
  @moduledoc """
  Cross-platform device events and queries.

  `Mob.Device` is the single subscription point for OS-level events that exist
  on both iOS and Android. The native side (iOS `NotificationCenter`,
  Android `ProcessLifecycleObserver`) registers observers once at startup and
  emits each event as a tagged tuple to a registered dispatcher pid; this
  GenServer fans the events out to subscribers by category.

  ## Subscribe

      Mob.Device.subscribe()             # default categories
      Mob.Device.subscribe(:all)         # everything
      Mob.Device.subscribe([:app, :power])

  Subscribers receive `{:mob_device, atom}` or `{:mob_device, atom, payload}`
  in their mailbox. Default categories are `:app`, `:display`, `:audio`, `:memory`.

  ## Categories and events

  - `:app` — `:will_resign_active`, `:did_become_active`, `:did_enter_background`,
    `:will_enter_foreground`, `:will_terminate`
  - `:display` — `:screen_off`, `:screen_on`,
    `{:orientation_changed, :portrait | :portrait_upside_down | :landscape_left | :landscape_right}`
  - `:audio` — `:audio_interrupted`, `:audio_resumed`, `:audio_route_changed`
  - `:appearance` — `{:color_scheme_changed, :light | :dark}`
  - `:power` — `{:battery_state_changed, :unplugged | :charging | :full | :unknown}`,
    `{:battery_level_changed, integer}`, `{:low_power_mode_changed, boolean}`
  - `:thermal` — `{:thermal_state_changed, :nominal | :fair | :serious | :critical}`
  - `:memory` — `:memory_warning`

  Platform-specific events with no cross-platform counterpart go through
  `Mob.Device.IOS` / `Mob.Device.Android` instead.

  ## Queries

      Mob.Device.battery_level()      # 0..100 | -1 if unknown
      Mob.Device.battery_state()      # :unplugged | :charging | :full | :unknown
      Mob.Device.thermal_state()      # :nominal | :fair | :serious | :critical
      Mob.Device.low_power_mode?()    # boolean
      Mob.Device.foreground?()        # boolean
      Mob.Device.os_version()         # binary
      Mob.Device.model()              # binary
      Mob.Device.orientation()        # :portrait | :landscape_left | ...

  ## Orientation

  `orientation/0` reports the current interface orientation; subscribe to
  `:display` to get `{:mob_device, :orientation_changed, orientation}` when the
  device rotates.

      Mob.Device.orientation()                 # :portrait
      Mob.Device.lock_orientation(:landscape)  # force landscape (either side)
      Mob.Device.unlock_orientation()          # follow the sensor again

  Locking forces the orientation regardless of the OS auto-rotate-lock setting
  (Android `setRequestedOrientation`; iOS supported-orientations + a geometry
  request). It is global to the app — a screen that wants to be landscape-only
  should `lock_orientation/1` on enter and `unlock_orientation/0` on leave.
  """

  use GenServer

  @categories [:app, :display, :audio, :appearance, :power, :thermal, :memory]
  @default_categories [:app, :display, :audio, :appearance, :memory]

  @app_events [
    :will_resign_active,
    :did_become_active,
    :did_enter_background,
    :will_enter_foreground,
    :will_terminate
  ]
  @display_events [:screen_off, :screen_on, :orientation_changed]
  @audio_events [:audio_interrupted, :audio_resumed, :audio_route_changed]
  @appearance_events [:color_scheme_changed]
  @power_events [:battery_state_changed, :battery_level_changed, :low_power_mode_changed]
  @thermal_events [:thermal_state_changed]
  @memory_events [:memory_warning]

  @type category :: :app | :display | :audio | :appearance | :power | :thermal | :memory
  @type event :: atom()

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Start the dispatcher. Called from `Mob.Application` (or the app supervision
  tree). After start, the registered NIF dispatcher pid is this GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe the calling process to device events.

  Accepts a single category atom, a list of categories, or `:all`.
  Default is `#{inspect(@default_categories)}`.

      Mob.Device.subscribe()
      Mob.Device.subscribe(:thermal)
      Mob.Device.subscribe([:app, :power, :thermal])
      Mob.Device.subscribe(:all)
  """
  @spec subscribe(category() | [category()] | :all) :: :ok
  def subscribe(categories \\ @default_categories) do
    GenServer.call(__MODULE__, {:subscribe, self(), normalize_categories(categories)})
  end

  @doc "Unsubscribe the calling process from all categories."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  end

  @doc "Returns the configured list of valid categories."
  @spec categories() :: [category()]
  def categories, do: @categories

  # ── Queries (delegate to NIF) ─────────────────────────────────────────────

  @doc "Current battery level (0..100), or -1 if unknown."
  @spec battery_level() :: integer()
  def battery_level do
    {_state, pct} = :mob_nif.device_battery_state()
    pct
  end

  @doc "Current battery state — `:unplugged | :charging | :full | :unknown`."
  @spec battery_state() :: :unplugged | :charging | :full | :unknown
  def battery_state do
    {state, _pct} = :mob_nif.device_battery_state()
    state
  end

  @doc "Current thermal state — `:nominal | :fair | :serious | :critical`."
  @spec thermal_state() :: :nominal | :fair | :serious | :critical
  def thermal_state, do: :mob_nif.device_thermal_state()

  @doc "True if Low Power Mode (iOS) / Power Save Mode (Android) is on."
  @spec low_power_mode?() :: boolean()
  def low_power_mode?, do: :mob_nif.device_low_power_mode() == true

  @doc "True if the app is currently in the foreground."
  @spec foreground?() :: boolean()
  def foreground?, do: :mob_nif.device_foreground() == true

  @doc "OS version string (e.g. \"17.4\")."
  @spec os_version() :: String.t()
  def os_version, do: to_string(:mob_nif.device_os_version())

  @doc "Device model (e.g. \"iPhone\", \"Pixel 8\")."
  @spec model() :: String.t()
  def model, do: to_string(:mob_nif.device_model())

  @typedoc "A concrete interface orientation."
  @type orientation ::
          :portrait | :portrait_upside_down | :landscape_left | :landscape_right | :unknown

  @typedoc """
  A lock request. `:landscape` / `:portrait` allow either side of that axis;
  the four concrete values pin a single orientation.
  """
  @type lock ::
          :portrait
          | :portrait_upside_down
          | :landscape
          | :landscape_left
          | :landscape_right

  @valid_locks [:portrait, :portrait_upside_down, :landscape, :landscape_left, :landscape_right]

  @doc """
  Current interface orientation — `:portrait | :portrait_upside_down |
  :landscape_left | :landscape_right`, or `:unknown` if it can't be determined.
  """
  @spec orientation() :: orientation()
  def orientation, do: :mob_nif.device_orientation()

  @doc """
  Lock the app to `orientation`, overriding the OS auto-rotate setting.

  Accepts `:portrait`, `:portrait_upside_down`, `:landscape` (either side),
  `:landscape_left`, or `:landscape_right`. Returns `{:error, :invalid}` for
  anything else. Global to the app; pair with `unlock_orientation/0`.
  """
  @spec lock_orientation(lock()) :: :ok | {:error, :invalid}
  def lock_orientation(orientation) when orientation in @valid_locks do
    :mob_nif.device_lock_orientation(orientation)
    :ok
  end

  def lock_orientation(_), do: {:error, :invalid}

  @doc "Release an orientation lock; the app follows the sensor again."
  @spec unlock_orientation() :: :ok
  def unlock_orientation do
    :mob_nif.device_lock_orientation(:unspecified)
    :ok
  end

  @doc false
  # Pure predicate behind lock_orientation/1's guard — exposed for tests.
  @spec valid_lock?(atom()) :: boolean()
  def valid_lock?(orientation), do: orientation in @valid_locks

  @doc """
  Hands a URL to the OS to open in the default browser/handler.

  Fire-and-forget. Returns `:ok` immediately; failures (malformed URL, no
  registered handler) are logged but not raised.
  """
  @spec open_url(String.t()) :: :ok
  def open_url(url) when is_binary(url) do
    :mob_nif.open_url(url)
    :ok
  end

  @doc """
  Opens an OS settings screen for this app.

  `target` is one of:

    * `:app` — the app's details / permissions page (both platforms). The
      go-to when a runtime permission was *permanently* denied and the user
      must re-enable it by hand.
    * `:notifications` — the app's notification settings (Android). iOS has no
      granular deep-link, so it opens the app page.
    * `:exact_alarm` — the "Alarms & reminders" special-access screen
      (Android 12+). iOS opens the app page.

  iOS exposes only the single app settings page, so `target` is honored on
  Android and falls back to the app page on iOS. Fire-and-forget: a valid target
  returns `:ok` immediately (an unavailable screen is a no-op, not a raise); an
  unknown target returns `{:error, :invalid}` without touching the NIF.
  """
  @spec open_settings(:app | :notifications | :exact_alarm) :: :ok | {:error, :invalid}
  def open_settings(target \\ :app)

  def open_settings(target) when target in [:app, :notifications, :exact_alarm] do
    :mob_nif.open_settings(Atom.to_string(target))
    :ok
  end

  def open_settings(_target), do: {:error, :invalid}

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Register this process as the NIF dispatcher. The native side will
    # enif_send all events here; we fan out to subscribers below.
    case maybe_set_dispatcher() do
      :ok ->
        :ok

      {:error, :nif_not_loaded} ->
        # Expected when running on the host (tests, IEx without device).
        # `maybe_set_dispatcher/0` only ever returns `:ok` or this
        # specific `:nif_not_loaded` shape — broader `{:error, reason}`
        # catch-all was unreachable and the 1.20 type checker flagged it.
        :ok
    end

    {:ok, %{subscribers: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:subscribe, pid, cats}, _from, state) do
    state = put_subscriber(state, pid, cats)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    state = drop_subscriber(state, pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:__test_subscribers__, _from, state) do
    {:reply, state.subscribers, state}
  end

  @impl true
  def handle_info({:mob_device, event}, state) do
    fan_out(state, event, nil)
    {:noreply, state}
  end

  def handle_info({:mob_device, event, payload}, state) do
    fan_out(state, event, payload)
    {:noreply, state}
  end

  # Platform-specific events go straight to the platform module's dispatcher.
  def handle_info({:mob_device_ios, _, _} = msg, state) do
    forward_to(Mob.Device.IOS, msg)
    {:noreply, state}
  end

  def handle_info({:mob_device_ios, _} = msg, state) do
    forward_to(Mob.Device.IOS, msg)
    {:noreply, state}
  end

  def handle_info({:mob_device_android, _, _} = msg, state) do
    forward_to(Mob.Device.Android, msg)
    {:noreply, state}
  end

  def handle_info({:mob_device_android, _} = msg, state) do
    forward_to(Mob.Device.Android, msg)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp maybe_set_dispatcher do
    try do
      :mob_nif.device_set_dispatcher(self())
      :ok
    rescue
      # Tolerate the two failure modes that mean "the NIF isn't here":
      # UndefinedFunctionError when the stub itself is unloadable, and
      # ErlangError when the stub is loaded but device_set_dispatcher
      # raises (e.g. because :erlang.load_nif/2 hasn't run yet on a
      # host-mode build). Anything else really is a bug worth crashing on.
      _ in [UndefinedFunctionError, ErlangError] -> {:error, :nif_not_loaded}
    end
  end

  defp normalize_categories(:all), do: @categories
  defp normalize_categories(cat) when is_atom(cat), do: [cat]
  defp normalize_categories(cats) when is_list(cats), do: Enum.uniq(cats)

  defp put_subscriber(state, pid, cats) do
    monitors =
      case Map.get(state.monitors, pid) do
        nil -> Map.put(state.monitors, pid, Process.monitor(pid))
        _ref -> state.monitors
      end

    cats = MapSet.new(cats)
    subscribers = Map.put(state.subscribers, pid, cats)
    %{state | subscribers: subscribers, monitors: monitors}
  end

  defp drop_subscriber(state, pid) do
    case Map.pop(state.monitors, pid) do
      {nil, monitors} ->
        %{state | monitors: monitors}

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: Map.delete(state.subscribers, pid), monitors: monitors}
    end
  end

  defp fan_out(state, event, payload) do
    cat = category_for(event)

    msg =
      case payload do
        nil -> {:mob_device, event}
        p -> {:mob_device, event, p}
      end

    Enum.each(state.subscribers, fn {pid, cats} ->
      if MapSet.member?(cats, cat), do: send(pid, msg)
    end)
  end

  defp forward_to(mod, msg) do
    case Process.whereis(mod) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end

  @doc false
  @spec category_for(atom()) :: category() | :other
  def category_for(event) do
    cond do
      event in @app_events -> :app
      event in @display_events -> :display
      event in @audio_events -> :audio
      event in @appearance_events -> :appearance
      event in @power_events -> :power
      event in @thermal_events -> :thermal
      event in @memory_events -> :memory
      true -> :unknown
    end
  end
end
