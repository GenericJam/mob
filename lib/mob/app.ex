defmodule Mob.App do
  @moduledoc """
  Behaviour for Mob application entry point.

  ## Usage

      defmodule MyApp do
        use Mob.App

        def navigation(_platform) do
          stack(:home, root: MyApp.HomeScreen)
        end

        def on_start do
          Mob.Screen.start_root(MyApp.HomeScreen)
          Mob.Dist.ensure_started(node: :"my_app@127.0.0.1", cookie: :secret)
        end
      end

  `use Mob.App` generates a `start/0` that the BEAM entry point calls. It
  handles all framework initialization (native logger, navigation registry)
  before delegating to `on_start/0`. App code only goes in `on_start/0`.

  ## Navigation

  Implement `navigation/1` to declare the app's navigation structure.
  Use the helper functions `stack/2`, `tab_bar/1`, and `drawer/1`:

      def navigation(:ios),     do: tab_bar([stack(:home, root: HomeScreen), ...])
      def navigation(:android), do: drawer([stack(:home, root: HomeScreen), ...])
      def navigation(_),        do: stack(:home, root: HomeScreen)

  All `name` atoms used in stacks become valid `push_screen` destinations
  without needing to reference modules directly.
  """

  @callback navigation(platform :: atom()) :: map()

  @doc """
  App-specific startup hook. Called by the generated `start/0` after all
  framework initialization is complete.

  Override to start your root screen, configure Erlang distribution,
  set the Logger level, etc. The default implementation is a no-op.
  """
  @callback on_start() :: term()

  @optional_callbacks [on_start: 0]

  defmacro __using__(opts) do
    theme_opts = Keyword.get(opts, :theme, [])

    quote do
      @behaviour Mob.App
      import Mob.App

      @doc """
      Framework entry point — called from the BEAM entry module (e.g.
      `mob_demo.erl`) after OTP applications have started.

      Installs `Mob.NativeLogger` so all Elixir Logger output is routed to
      the platform system log (logcat / NSLog) from this point forward, seeds
      the `Mob.Nav.Registry` from this module's `navigation/1` declarations,
      then calls `on_start/0` for app-specific initialization.

      Do not override — implement `on_start/0` instead.
      """
      def start do
        Mob.NativeLogger.install()

        # Compile theme from options passed to `use Mob.App, theme: [...]`
        # and store it so Mob.Renderer picks it up on every render.
        # Always called — even with [] this seeds the default theme explicitly.
        Mob.Theme.set(unquote(theme_opts))

        case Mob.Nav.Registry.start_link(__MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        case Mob.State.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        case Mob.ComponentRegistry.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        __MODULE__.on_start()
      end

      def on_start, do: :ok

      defoverridable on_start: 0
    end
  end

  # ── Navigation helpers ─────────────────────────────────────────────────────

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
