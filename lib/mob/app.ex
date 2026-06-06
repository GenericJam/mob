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
        # iOS-only: BEAM's default :native hostname lookup spawns the
        # `inet_gethost` port program via execve, which the iOS app
        # sandbox refuses. Any subsequent code path that resolves a
        # hostname — Node.connect, :erpc.call, gen_tcp.connect with a
        # binary host, Logger forwarding to a named node — crashes the
        # calling process with badarg before this is fixed. Switch to
        # file-only lookup and seed `localhost` so distribution and
        # local TCP work out of the box. Apps that need real outbound
        # DNS layer Mob.DNS.configure_pure_beam/1 on top in on_start/0.
        Mob.App.configure_ios_inet_db()

        Mob.NativeLogger.install()

        # Compile theme from options passed to `use Mob.App, theme: [...]`
        # and store it so Mob.Renderer picks it up on every render.
        # Always called — even with [] this seeds the default theme explicitly.
        Mob.Theme.set(unquote(theme_opts))

        case Mob.Nav.Registry.start_link(__MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        # Load the activated plugins' tier-3/4 runtime manifest and register
        # their screens into the nav registry (no-op when none are active).
        Mob.Plugins.boot(Application.get_application(__MODULE__))

        case Mob.State.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        case Mob.ComponentRegistry.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        # Mob.Device dispatcher + platform fan-out modules. Order matters:
        # the IOS / Android modules must exist before Mob.Device starts,
        # because Mob.Device forwards platform-tagged messages to them.
        case Mob.Device.IOS.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        case Mob.Device.Android.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        case Mob.Device.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        # Adaptive-theme watcher: subscribes to Mob.Device :appearance and
        # re-resolves Mob.Theme on OS color-scheme flips. Started after
        # Mob.Device so the subscribe call has a target.
        case Mob.Theme.AdaptiveWatcher.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        result = __MODULE__.on_start()

        # Start the tier-4 plugins' lifecycle (on_start MFAs, supervised
        # children, fore/background dispatcher) after the host's own on_start.
        # No-op when no plugin declares a :lifecycle.
        Mob.Plugins.start_lifecycle()

        result
      end

      def on_start, do: :ok

      defoverridable on_start: 0
    end
  end

  @doc """
  Apply the iOS-only `:inet_db` workaround so distribution, RPC, and
  TCP-by-hostname don't crash on the first lookup.

  iOS sandboxes any app that isn't Apple's own and refuses `execve` of
  binaries the app didn't get a special pass for. BEAM's default
  `:native` hostname-resolution path spawns the `inet_gethost` port
  program — exactly the kind of `execve` iOS rejects — so the very
  first `:inet.getaddr/2` call (transitively reached by `Node.connect`,
  `:erpc.call`, `gen_tcp.connect/3` with a binary host, etc.) crashes
  the calling process with `:badarg`. The simulator hits the same
  failure for a related but distinct reason: `inet_gethost` doesn't
  live at the path BEAM expects under the mob iOS sim OTP layout.
  Either way, the fix is the same.

  Switching the lookup chain to `[:file]` keeps everything in BEAM's
  in-process name table — no port program, no fork, no `execve`. We
  also seed `localhost` so apps using `@localhost` node names (or any
  `gen_tcp` call that resolves `"localhost"`) work without further
  setup.

  Called automatically by the macro-generated `start/0` before
  anything else, so app `on_start/0` code never has to think about it.
  Apps that need outbound DNS (Req / Finch / Mint to arbitrary hosts)
  can layer `Mob.DNS.configure_pure_beam/1` on top — it upgrades the
  chain to `[:file, :dns]` and seeds fallback nameservers, while the
  file-table entries we add here keep winning.

  Other platforms (`:android`, `:host`) are unaffected — BEAM's native
  resolver works there. Safe to call on host BEAM where the NIF isn't
  loaded; rescues the `UndefinedFunctionError` / `ErlangError` and
  returns `:ok`.
  """
  @spec configure_ios_inet_db() :: :ok
  def configure_ios_inet_db do
    case safe_platform() do
      :ios ->
        :inet_db.set_lookup([:file])
        :inet_db.add_host({127, 0, 0, 1}, [~c"localhost"])
        :ok

      _ ->
        :ok
    end
  end

  defp safe_platform do
    :mob_nif.platform()
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> :host
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
