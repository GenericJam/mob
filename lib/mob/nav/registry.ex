defmodule Mob.Nav.Registry do
  @moduledoc """
  ETS-backed registry mapping screen name atoms to their modules.

  Populated at startup by walking an `Mob.App` module's `navigation/1`
  declarations for both platforms. Hot-code-reload safe — the mapping stores
  module atoms, not captured references.

  `register/2` is available for runtime additions: A/B testing, library screens,
  or dynamic feature flags.
  """

  use GenServer

  @table __MODULE__

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
    case :ets.lookup(@table, name) do
      [{^name, module}] -> {:ok, module}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Register a `name → module` mapping at runtime.

  Overwrites any existing entry for `name`.
  """
  @spec register(atom(), module()) :: :ok
  def register(name, module) when is_atom(name) and is_atom(module) do
    :ets.insert(@table, {name, module})
    :ok
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(app_module) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    populate(app_module)
    {:ok, app_module}
  end

  defp populate(app_module) do
    for platform <- [:android, :ios] do
      nav = app_module.navigation(platform)
      register_nav(nav)
    end

    :ok
  end

  defp register_nav(%{type: :stack, name: name, root: root}) do
    :ets.insert(@table, {name, root})
  end

  defp register_nav(%{type: type, branches: branches})
       when type in [:tab_bar, :drawer] do
    Enum.each(branches, &register_nav/1)
  end

  defp register_nav(_), do: :ok
end
