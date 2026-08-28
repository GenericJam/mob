defmodule Mob.Nav.Registry do
  @moduledoc """
  ETS-backed registry mapping screen name atoms to their modules.

  Populated at startup by walking an `Mob.App` module's `navigation/1`
  declarations for both platforms. Hot-code-reload safe — the mapping stores
  module atoms, not captured references.

  `register/2` is available for runtime additions: A/B testing, library screens,
  or dynamic feature flags.

  ## Two things are recorded, not one

  Walking `navigation/1` produces a flat **route table** (`name -> {module,
  params}`) that backs `push_screen/2,3` and friends, and a per-platform
  **layout** that preserves the declaration tree — which stacks a `tab_bar/1`
  or `drawer/1` contains, and in what order.

  The route table alone records only that a stack name exists. That was the
  whole of what this module kept, which is why `Mob.App.tab_bar/1` could be
  declared but not backed by the runtime: nothing downstream could tell that
  `:home` and `:settings` were sibling stacks rather than two unrelated routes.
  `Mob.Nav.from_layout/2` consumes the layout to build one independent stack per
  branch. See `decisions/2026-08-27-screen-process-architecture.md`.
  """

  use GenServer

  @table __MODULE__
  @layout_table Module.concat(__MODULE__, Layouts)

  @doc """
  Start the registry, seeding it from the given App module.

  Normally started by `Mob.Nav.Registry.start_link/1` in your application
  supervisor. In tests, start it directly.
  """
  @spec start_link(module()) :: GenServer.on_start()
  def start_link(app_module) when is_atom(app_module) do
    GenServer.start_link(__MODULE__, app_module, name: __MODULE__)
  end

  @doc """
  Look up the module registered under `name`.

  Returns `{:ok, module}` or `{:error, :not_found}`.
  """
  @spec lookup(atom()) :: {:ok, module()} | {:error, :not_found}
  def lookup(name) when is_atom(name) do
    case lookup_route(name) do
      {:ok, module, _params} -> {:ok, module}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Look up the module AND route-bound params registered under `name`.

  Route-bound params let N routes share one parameterized screen module (the
  data-driven-plugin pattern — e.g. mob_ash registers `/ash/post/list` as
  `{MobAsh.ListScreen, %{resource: MyApp.Post}}`). Navigation merges them
  UNDER the caller's `push_screen` params, then passes the result to `mount/3`.
  """
  @spec lookup_route(atom()) :: {:ok, module(), map()} | {:error, :not_found}
  def lookup_route(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, module, params}] -> {:ok, module, params}
      # Entries written by pre-params code paths (or hot-loaded old beams).
      [{^name, module}] -> {:ok, module, %{}}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Register a `name → module` mapping at runtime, optionally with route-bound
  `params` delivered to the screen's `mount/3` whenever this route is the
  navigation destination (see `lookup_route/1`).

  Overwrites any existing entry for `name`.
  """
  @spec register(atom(), module(), map()) :: :ok
  def register(name, module, params \\ %{})

  def register(name, module, params)
      when is_atom(name) and is_atom(module) and is_map(params) do
    :ets.insert(@table, {name, module, params})
    :ok
  end

  @doc """
  Return the navigation layout declared for `platform`, or `nil`.

  The layout is the raw map returned by the app's `navigation/1` — a
  `Mob.App.stack/2`, `tab_bar/1`, or `drawer/1` declaration. `nil` when the
  registry has not been started (tests that drive a screen directly) or when
  the app declared nothing for this platform.
  """
  @spec layout(atom()) :: map() | nil
  def layout(platform) when is_atom(platform) do
    case :ets.whereis(@layout_table) do
      :undefined ->
        nil

      _tid ->
        case :ets.lookup(@layout_table, platform) do
          [{^platform, layout}] -> layout
          [] -> nil
        end
    end
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(app_module) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ets.new(@layout_table, [:named_table, :public, read_concurrency: true])
    populate(app_module)
    {:ok, app_module}
  end

  defp populate(app_module) do
    for platform <- [:android, :ios] do
      nav = app_module.navigation(platform)
      :ets.insert(@layout_table, {platform, nav})
      register_nav(nav)
    end

    :ok
  end

  defp register_nav(%{type: :stack, name: name, root: root}) do
    :ets.insert(@table, {name, root, %{}})
  end

  defp register_nav(%{type: type, branches: branches})
       when type in [:tab_bar, :drawer] do
    Enum.each(branches, &register_nav/1)
  end

  defp register_nav(_), do: :ok
end
