defmodule Mob.Scenes do
  @moduledoc """
  Which window scenes exist, and which `Mob.Router` shows each (MOB-245).

  iPadOS can show several windows of one app, each a `UIWindowScene`. All of
  them run in the one BEAM; each gets its own router, navigation and screen
  processes. This process keeps the map and owns the lifecycle:

    * **The primary router** is the one the app starts with
      `Mob.Screen.start_root/2`. It registers here (`register_primary/4`),
      handing over its root module and params, the template every further
      window starts from. It holds `:mob_screen` and is never bound to a scene
      id: it renders to native's *default* scene, the way a single-window app
      always has.
    * **Native reports scenes** as `{:mob_scene, :connected, id, default?}` and
      `{:mob_scene, :disconnected, id}`. Native can't message the BEAM before it
      is up, so this process also asks `mob_nif:scenes/0` when it starts.
    * **A connecting scene** that a router already shows is told its window is
      back. Native's default scene goes to the unbound primary. Otherwise a
      router whose scene has gone adopts it, and failing that a new router is
      started for it, bound to its id, from the primary's root module and
      params.
    * **A disconnecting scene** has its router stopped, unless it is the last
      router: that one is kept, so the window comes back as it was. When the
      primary's window goes and others remain, `:mob_screen` moves to the
      oldest remaining router.
    * **Window events** native can attribute to a scene — the back gesture,
      size class changes, alert results — arrive as `{:mob_scene_event, id,
      message}` while more than one scene is attached, and are forwarded to
      that scene's router.

  Scene ids are `UISceneSession.persistentIdentifier` strings, `nil` on
  platforms without scenes. `Mob.Test.screens/1` reads `screens/0`. See
  `decisions/2026-10-02-one-router-per-window-scene.md`.
  """

  use GenServer

  require Logger

  @stop_timeout_ms 5_000
  @max_restarts 3
  @restart_window_ms 10_000

  defstruct nif: :mob_nif,
            template: nil,
            primary: nil,
            routers: %{},
            scenes: [],
            default: nil,
            restarts: %{}

  @typedoc "A window scene id (`UISceneSession.persistentIdentifier`), `nil` where there is none."
  @type scene_id :: String.t() | nil

  # ── API ───────────────────────────────────────────────────────────────────

  @doc false
  # Unlinked, like Mob.Sender.ensure_started/0: the caller is the primary
  # router, and a router crash must not take the scene registry with it.
  @spec ensure_started(keyword()) :: :ok
  def ensure_started(opts \\ []) do
    if Process.whereis(__MODULE__) do
      :ok
    else
      case GenServer.start(__MODULE__, opts, name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  @doc false
  # Called by the primary router from its init, so it must not block on it.
  @spec register_primary(pid(), module(), map(), module() | atom()) :: :ok
  def register_primary(router, module, params, nif) do
    GenServer.cast(__MODULE__, {:register_primary, router, module, params, nif})
  end

  @doc """
  Every live router as `{scene_id, router_pid}`: the primary first, then one
  per further window scene in the order the scenes connected.
  """
  @spec list() :: [{scene_id(), pid()}]
  def list do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :list), else: []
  end

  @doc "The router showing window scene `scene`, or `nil`."
  @spec router(scene_id()) :: pid() | nil
  def router(scene) do
    Enum.find_value(list(), fn {id, pid} -> if id == scene, do: pid end)
  end

  @doc """
  What every window shows: `{scene_id, screen_module, screen_pid}` per live
  router, in `list/0` order. A router whose screen is mid-restart is left out.
  """
  @spec screens() :: [{scene_id(), module(), pid()}]
  def screens do
    # The routers are asked from the caller, not from this process, so a
    # router busy in a slow navigation delays only this answer.
    Enum.flat_map(list(), fn {scene, router} ->
      try do
        [{scene, Mob.Router.get_current_module(router), Mob.Router.get_screen_pid(router)}]
      catch
        :exit, _reason -> []
      end
    end)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Further windows' routers are linked to this process, so they come down
    # with it; trapping keeps one of their exits from taking it down.
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{nif: Keyword.get(opts, :nif, :mob_nif)}, {:continue, :pull}}
  end

  @impl GenServer
  # The scenes native attached before this process existed — on a normal
  # launch, at least the first window. Pushed connects that race this are
  # idempotent.
  def handle_continue(:pull, state), do: {:noreply, pull(state)}

  @impl GenServer
  def handle_call(:list, _from, state), do: {:reply, ordered(state), state}

  @impl GenServer
  def handle_cast({:register_primary, router, module, params, nif}, state) do
    state = %{state | nif: nif, template: {module, params}, primary: router}
    # One app has one root router; an earlier unbound one (a root screen the
    # app started again) is no longer a window's router.
    state = state |> forget_unbound() |> track(router, %{scene: nil, bound: false})
    # A primary registering after native's scenes arrived (the usual boot
    # order) claims the default one; any others get a router of their own.
    {:noreply, state |> pull() |> start_missing()}
  end

  @impl GenServer
  def handle_info({:mob_scene, :connected, scene, default?}, state) when is_binary(scene) do
    {:noreply, connected(state, scene, default? == true)}
  end

  def handle_info({:mob_scene, :disconnected, scene}, state) when is_binary(scene) do
    {:noreply, disconnected(state, scene)}
  end

  def handle_info({:mob_scene_event, scene, message}, state) do
    case router_for(state, scene) || Process.whereis(:mob_screen) do
      nil -> :ok
      router -> send(router, message)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, router, reason}, state) do
    {:noreply, router_down(state, router, reason)}
  end

  # Linked further-window routers. Their monitor's :DOWN does the work.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  # ── Scene lifecycle ───────────────────────────────────────────────────────

  defp pull(state) do
    Enum.reduce(native_scenes(state.nif), state, fn {scene, default?}, acc ->
      connected(acc, scene, default?)
    end)
  end

  # Anything but a list of scenes is "none": a stub without scenes/0, a native
  # library that predates it (a hot-pushed mob on an app whose native layer was
  # not rebuilt), or Android, which has no scenes.
  defp native_scenes(nif) do
    case nif.scenes() do
      list when is_list(list) ->
        for {scene, default?} <- list, is_binary(scene), do: {scene, default? == true}

      _other ->
        []
    end
  catch
    :error, reason when reason in [:undef, :not_loaded] -> []
  end

  defp connected(state, scene, default?) do
    state = if default?, do: %{state | default: scene}, else: state
    already? = scene in state.scenes
    state = if already?, do: state, else: %{state | scenes: state.scenes ++ [scene]}

    cond do
      router = bound_router(state, scene) ->
        # The window came back (or this is a repeat): screens re-read insets.
        if already?, do: state, else: tell_window_connected(state, router)

      default? and unbound_primary?(state) ->
        tell_window_connected(state, state.primary)

      orphan = orphan(state) ->
        bind(state, orphan, scene)

      state.template != nil ->
        start_router(state, scene)

      true ->
        # The primary has not registered yet; it claims scenes when it does.
        state
    end
  end

  defp tell_window_connected(state, router) do
    send(router, {:mob_window, :connected})
    state
  end

  defp disconnected(state, scene) do
    state = %{state | scenes: List.delete(state.scenes, scene)}

    case router_for(state, scene) do
      nil ->
        state

      router when map_size(state.routers) > 1 ->
        stop_router(state, router, scene)

      _last_router ->
        # Kept, bound and alive: a reconnect of the same id shows the same
        # screens, and a new id adopts this router (orphan/1).
        state
    end
  end

  defp stop_router(state, router, scene) do
    {info, routers} = Map.pop(state.routers, router)
    Process.demonitor(info.monitor, [:flush])
    state = %{state | routers: routers}
    primary? = router == state.primary

    stop_process(router)
    if info.bound, do: Mob.Sender.deactivate_scene(scene)

    state = if primary?, do: %{state | primary: nil}, else: state
    state = if state.default == scene, do: %{state | default: nil}, else: state
    if primary?, do: promote(state), else: state
  end

  defp stop_process(router) do
    Process.unlink(router)
    GenServer.stop(router, :normal, @stop_timeout_ms)
  catch
    # Already gone, or wedged past the timeout: either way it must not stay
    # around showing a window that no longer exists.
    :exit, _reason -> Process.exit(router, :kill)
  end

  # `:mob_screen` must name a live router while any exists: native's
  # single-scene paths, notifications and Mob.Test all address it.
  defp promote(state) do
    case ordered(state) do
      [{_scene, router} | _] ->
        try do
          Process.register(router, :mob_screen)
        rescue
          # Something else registered it, or the router just died (its :DOWN
          # is queued and promotes again).
          ArgumentError -> :ok
        end

        %{state | primary: router}

      [] ->
        state
    end
  end

  defp router_down(state, router, reason) do
    case Map.pop(state.routers, router) do
      {nil, _routers} ->
        state

      {info, routers} ->
        state = %{state | routers: routers}

        cond do
          router != state.primary ->
            restart_bound(state, info, reason)

          # A single-window app's root router died: whatever happened before
          # scenes existed happens now. Nothing here to fall back to.
          map_size(routers) == 0 ->
            %{state | primary: nil}

          # Other windows remain: the default one gets a router of its own
          # (bound to its id) and `:mob_screen` moves on.
          true ->
            state = start_missing(%{state | primary: nil})
            if Process.whereis(:mob_screen), do: state, else: promote(state)
        end
    end
  end

  # A further window's router died while its scene is still attached: the
  # window would sit on its last frame for good. Started again from the root
  # template, within a ceiling so a router that dies on start is not looped.
  defp restart_bound(state, %{bound: true, scene: scene}, reason) do
    if scene in state.scenes do
      {allowed?, state} = record_restart(state, scene)

      if allowed? do
        Logger.error(
          "[mob] the router of window scene #{inspect(scene)} exited and is being restarted: " <>
            Mob.CrashReport.format(reason)
        )

        start_router(state, scene)
      else
        Logger.error(
          "[mob] the router of window scene #{inspect(scene)} exited #{@max_restarts + 1} " <>
            "times in #{@restart_window_ms}ms; that window keeps its last frame"
        )

        state
      end
    else
      state
    end
  end

  defp restart_bound(state, _info, _reason), do: state

  defp record_restart(state, scene) do
    now = System.monotonic_time(:millisecond)
    recent = state.restarts |> Map.get(scene, []) |> Enum.filter(&(now - &1 < @restart_window_ms))
    state = %{state | restarts: Map.put(state.restarts, scene, [now | recent])}
    {length(recent) < @max_restarts, state}
  end

  defp start_router(%{template: {module, params}} = state, scene) do
    case Mob.Router.start_scene(module, params, scene: scene, nif: state.nif) do
      {:ok, router} -> track(state, router, %{scene: scene, bound: true})
      {:error, _reason} -> state
    end
  end

  # Every attached scene with no router yet, once the template is known.
  defp start_missing(%{template: nil} = state), do: state

  defp start_missing(state) do
    Enum.reduce(state.scenes, state, fn scene, acc ->
      cond do
        router_for(acc, scene) -> acc
        orphan = orphan(acc) -> bind(acc, orphan, scene)
        true -> start_router(acc, scene)
      end
    end)
  end

  defp bind(state, router, scene) do
    send(router, {:mob_scene_bind, scene})
    track(state, router, %{scene: scene, bound: true})
  end

  # ── Bookkeeping ───────────────────────────────────────────────────────────

  defp track(state, router, info) do
    monitor =
      case Map.get(state.routers, router) do
        %{monitor: ref} -> ref
        nil -> Process.monitor(router)
      end

    %{state | routers: Map.put(state.routers, router, Map.put(info, :monitor, monitor))}
  end

  defp unbound_primary?(%{primary: primary, routers: routers}) do
    match?(%{bound: false}, Map.get(routers, primary))
  end

  defp bound_router(state, scene) do
    Enum.find_value(state.routers, fn
      {router, %{bound: true, scene: ^scene}} -> router
      _other -> nil
    end)
  end

  # The router showing `scene`: the one bound to it, else the unbound primary
  # when `scene` is native's default scene.
  defp router_for(state, scene) do
    cond do
      router = bound_router(state, scene) -> router
      scene != nil and scene == state.default and unbound_primary?(state) -> state.primary
      true -> nil
    end
  end

  # A bound router whose scene is no longer attached: kept because it was the
  # last (disconnected/2), free to show whatever connects next.
  defp orphan(state) do
    Enum.find_value(state.routers, fn
      {router, %{bound: true, scene: scene}} -> if scene not in state.scenes, do: router
      _unbound -> nil
    end)
  end

  defp scene_of(state, %{bound: false}), do: state.default
  defp scene_of(_state, %{scene: scene}), do: scene

  defp forget_unbound(state) do
    {unbound, bound} = Enum.split_with(state.routers, fn {_router, info} -> not info.bound end)
    Enum.each(unbound, fn {_router, info} -> Process.demonitor(info.monitor, [:flush]) end)
    %{state | routers: Map.new(bound)}
  end

  # Alive-filtered: a router that just died may still be in the map with its
  # :DOWN queued behind the caller's request.
  defp ordered(state) do
    position = fn scene ->
      Enum.find_index(state.scenes, &(&1 == scene)) || length(state.scenes)
    end

    state.routers
    |> Enum.filter(fn {router, _info} -> Process.alive?(router) end)
    |> Enum.map(fn {router, info} -> {scene_of(state, info), router} end)
    |> Enum.sort_by(fn {scene, router} -> {router != state.primary, position.(scene)} end)
  end
end
