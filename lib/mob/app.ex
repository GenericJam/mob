defmodule Mob.App do
  @moduledoc """
  Behaviour for Mob application entry point.

  Implement `navigation/1` to declare the app's navigation structure.
  Use the helper functions `stack/2`, `tab_bar/1`, and `drawer/1` to build
  the declaration — these return plain maps, no macros involved.

  Platform-specific navigation is handled by pattern-matching on the `platform`
  argument:

      def navigation(:ios),     do: tab_bar([stack(:home, root: HomeScreen), ...])
      def navigation(:android), do: drawer([stack(:home, root: HomeScreen), ...])
      def navigation(_),        do: stack(:home, root: HomeScreen)

  The registry is populated from these declarations at startup. All `name` atoms
  used in stacks become valid `push_screen` destinations.
  """

  @callback navigation(platform :: atom()) :: map()

  @doc """
  Declare a navigation stack.

  `name` is the atom identifier used with `push_screen/2,3`, `pop_to/2`,
  and `reset_to/2,3`. The `:root` option is the module mounted when the stack
  is first entered.

  Options:
  - `:root` (required) — screen module that is the stack's initial screen
  - `:title` — optional display label shown in tabs or drawer entries
  """
  @spec stack(atom(), keyword()) :: map()
  def stack(name, opts) when is_atom(name) and is_list(opts) do
    %{
      type: :stack,
      name: name,
      root: Keyword.fetch!(opts, :root),
      title: Keyword.get(opts, :title)
    }
  end

  @doc """
  Declare a tab bar containing multiple named stacks.

  Each branch must be a `stack/2` map. Renders as a bottom NavigationBar on
  Android and a UITabBarController on iOS.
  """
  @spec tab_bar([map()]) :: map()
  def tab_bar(branches) when is_list(branches) do
    %{type: :tab_bar, branches: branches}
  end

  @doc """
  Declare a side drawer containing multiple named stacks.

  Renders as a ModalNavigationDrawer on Android. iOS uses a custom slide-in
  panel (native UIKit drawer support deferred).
  """
  @spec drawer([map()]) :: map()
  def drawer(branches) when is_list(branches) do
    %{type: :drawer, branches: branches}
  end
end
