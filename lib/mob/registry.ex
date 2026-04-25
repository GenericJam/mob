defmodule Mob.Registry do
  @moduledoc """
  Maps component names (atoms) to their platform-specific NIF constructors.

  Each entry maps a component name to a per-platform tuple:
  `{nif_module, function_name, extra_args}`.

  ## Example

      Mob.Registry.register(MyReg, :map_view,
        android: {:mob_nif, :create_map_view, []},
        ios:     {:mob_nif, :create_map_view, []}
      )

      {:ok, {mod, fun, args}} = Mob.Registry.lookup(MyReg, :map_view, :android)
      apply(mod, fun, args)

  ## Default registry

  `Mob.Registry` itself is started by the Mob application and pre-populated
  with the built-in component vocabulary. Third-party packages call
  `Mob.Registry.register/3` in their `Application.start/2`.
  """

  use Agent

  # Built-in component mappings — same NIF module for both platforms for now
  @builtins [
    column: [android: {:mob_nif, :create_column, []}, ios: {:mob_nif, :create_column, []}],
    row: [android: {:mob_nif, :create_row, []}, ios: {:mob_nif, :create_row, []}],
    text: [android: {:mob_nif, :create_label, []}, ios: {:mob_nif, :create_label, []}],
    button: [android: {:mob_nif, :create_button, []}, ios: {:mob_nif, :create_button, []}],
    scroll: [android: {:mob_nif, :create_scroll, []}, ios: {:mob_nif, :create_scroll, []}]
  ]

  @doc """
  Start a registry Agent.

  Pass `name: nil` for an anonymous registry (useful in tests).
  Pass `name: Mob.Registry` for the global application registry.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    initial = build_initial()

    if name do
      Agent.start_link(fn -> initial end, name: name)
    else
      Agent.start_link(fn -> initial end)
    end
  end

  @doc """
  Register a component name with platform-specific NIF constructors.

  `mappings` is a keyword list of `platform: {mod, fun, args}` entries.
  Calling register again for an existing name merges/overwrites platforms.
  """
  @spec register(GenServer.server(), atom(), keyword()) :: :ok
  def register(registry \\ __MODULE__, name, mappings) when is_atom(name) and is_list(mappings) do
    Agent.update(registry, fn state ->
      existing = Map.get(state, name, %{})

      updated =
        Enum.reduce(mappings, existing, fn {platform, spec}, acc ->
          Map.put(acc, platform, spec)
        end)

      Map.put(state, name, updated)
    end)
  end

  @doc """
  Look up the NIF spec for a component on a given platform.

  Returns `{:ok, {mod, fun, args}}` or `{:error, :not_found}`.
  """
  @spec lookup(GenServer.server(), atom(), atom()) ::
          {:ok, {module(), atom(), list()}} | {:error, :not_found}
  def lookup(registry \\ __MODULE__, name, platform) when is_atom(name) and is_atom(platform) do
    state = Agent.get(registry, & &1)

    case get_in(state, [name, platform]) do
      nil -> {:error, :not_found}
      spec -> {:ok, spec}
    end
  end

  @doc """
  List all registered component names.
  """
  @spec all(GenServer.server()) :: [atom()]
  def all(registry \\ __MODULE__) do
    Agent.get(registry, &Map.keys/1)
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp build_initial do
    Enum.reduce(@builtins, %{}, fn {name, mappings}, acc ->
      Map.put(acc, name, Map.new(mappings))
    end)
  end
end
