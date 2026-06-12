defmodule Mob.Composite do
  @moduledoc """
  Pure-Elixir composite components: the third expansion pass.

  A composite is a TAG that expands to a built-in widget tree — no native
  code. UI-kit authors register an expander per tag atom and users write
  `<MishkaCombobox … />` in `~MOB`; this pass replaces the node with the
  expander's output before `Mob.List.expand` / `Mob.Component.expand` run
  (so a composite may itself emit `<List>` or `Mob.UI.native_view`).

  ## Registering

  Via a plugin manifest (the `expand:` ui_components form, MOB_PLUGINS.md):

      ui_components: [
        %{tag: "MishkaCombobox", atom: :mishka_combobox,
          expand: {Mishka.Combobox, :expand}}
      ]

  …registered automatically at boot. Or at runtime (plain Hex UI kits with
  no manifest — call from the host's `on_start/0`):

      Mob.Composite.register(:mishka_combobox, {Mishka.Combobox, :expand})

  ## The expander contract

      def expand(props, children, ctx)

  `props` are the node's props with EVENT TARGETS AUTO-INJECTED: any `on_*`
  prop written as a bare atom or string (`on_select="combo_select"`) arrives
  as `{screen_pid, :combo_select}` — no `self()` threading. `children` are
  the (already composite-expanded) child nodes; `ctx` is
  `%{screen: pid, platform: platform}`. Return a node map or a list of nodes
  (the `~MOB` sigil output). Output is re-expanded to a fixpoint (composites
  can build on composites) with a depth guard of #{20}.

  Composites are stateless by design — state lives in the screen (or in a
  `Mob.Component` if a part of the tree needs its own process). Hot-pushable:
  pure Elixir, same rule as any screen module.
  """

  require Logger

  @pt_key {__MODULE__, :expanders}
  @max_depth 20

  @doc """
  Registers an expander for a composite tag atom. Overwrites any existing
  registration for `atom`.
  """
  @spec register(atom(), {module(), atom()}) :: :ok
  def register(atom, {mod, fun}) when is_atom(atom) and is_atom(mod) and is_atom(fun) do
    :persistent_term.put(@pt_key, Map.put(expanders(), atom, {mod, fun}))
    :ok
  end

  @doc "The registered expanders (`%{atom => {module, function}}`)."
  @spec expanders() :: %{atom() => {module(), atom()}}
  def expanders, do: :persistent_term.get(@pt_key, %{})

  @doc false
  # Test seam: drop all registrations.
  @spec reset() :: :ok
  def reset do
    :persistent_term.put(@pt_key, %{})
    :ok
  end

  @doc """
  The expansion pass. Walks the tree; nodes whose `:type` has a registered
  expander are replaced by the expander output (recursively, to a fixpoint).
  A crashing expander logs and renders nothing (an empty Column) rather than
  taking the screen down.
  """
  @spec expand(map() | [map()], pid()) :: map() | [map()]
  def expand(tree, screen_pid) do
    do_expand(tree, screen_pid, expanders(), 0)
  end

  defp do_expand(nodes, pid, exp, depth) when is_list(nodes) do
    nodes
    |> Enum.map(&do_expand(&1, pid, exp, depth))
    |> List.flatten()
  end

  defp do_expand(%{type: type} = node, pid, exp, depth) do
    case Map.fetch(exp, type) do
      {:ok, {mod, fun}} when depth < @max_depth ->
        node
        |> run_expander(mod, fun, pid)
        |> do_expand(pid, exp, depth + 1)

      {:ok, _} ->
        Logger.error(
          "[mob_composite] #{inspect(type)} exceeded the expansion depth guard " <>
            "(#{@max_depth}) — circular composite? Rendering nothing for this node."
        )

        empty_node()

      :error ->
        children = node |> Map.get(:children, []) |> do_expand(pid, exp, depth)
        Map.put(node, :children, children)
    end
  end

  defp do_expand(other, _pid, _exp, _depth), do: other

  defp run_expander(node, mod, fun, pid) do
    props = node |> Map.get(:props, %{}) |> inject_event_targets(pid)
    children = Map.get(node, :children, [])

    try do
      apply(mod, fun, [props, children, %{screen: pid}])
    rescue
      e ->
        Logger.error(
          "[mob_composite] #{inspect(mod)}.#{fun}/3 for #{inspect(node.type)} crashed: " <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        empty_node()
    end
  end

  # `on_*` props written as a bare atom or string become `{screen_pid, tag}` —
  # the event-target shape every built-in widget expects — so composite users
  # (and composite authors passing them through) never thread `self()`.
  # Already-shaped `{pid, tag}` values pass through untouched.
  @doc false
  @spec inject_event_targets(map(), pid()) :: map()
  def inject_event_targets(props, pid) when is_map(props) do
    Map.new(props, fn
      {key, value} = pair ->
        if event_key?(key) do
          case value do
            v when is_atom(v) and not is_nil(v) and not is_boolean(v) -> {key, {pid, v}}
            v when is_binary(v) -> {key, {pid, String.to_atom(v)}}
            _ -> pair
          end
        else
          pair
        end
    end)
  end

  defp event_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.starts_with?("on_")

  defp event_key?(_), do: false

  defp empty_node, do: %{type: :column, props: %{}, children: []}
end
