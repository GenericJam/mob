defmodule Mob.Plugins do
  @moduledoc """
  On-device access to the activated plugins' tier-3/4 contributions.

  Tiers 3 (multi-screen) and 4 (sub-app) are pure-Elixir and runtime-wired: the
  host needs to know, while running, which screens / lifecycle hooks / settings /
  notification handlers the activated plugins declared. mob_dev bakes that into
  the host's `priv/generated/mob_plugins.exs` at build time (see
  `mix mob.regen_plugin_manifest`); this module reads it once at boot and feeds
  the data to the core wiring (`Mob.App` registers the screens, the lifecycle
  dispatcher calls the hooks, `Mob.Notify` consults the handlers, and the
  settings store namespaces by plugin).

  When no tier-3/4 plugin is active (or the manifest hasn't been regenerated) the
  file is absent and every accessor returns the empty set — tiers 0-2 are
  unaffected.
  """

  require Logger

  @empty %{screens: [], lifecycle: [], settings: [], notification_handlers: []}
  @pt_key {__MODULE__, :manifest}
  @pt_asset_root {__MODULE__, :asset_root}
  @rel_path ["generated", "mob_plugins.exs"]

  @doc """
  Reads the host app's generated manifest and caches it in `:persistent_term`.

  `otp_app` is the host application name (e.g. `:mob_plugin_demo`); the file is
  resolved under its `priv/`. Called once from `Mob.App.start/0`. Returns the
  loaded manifest (also retrievable later via `manifest/0`).
  """
  @spec load(atom()) :: map()
  def load(otp_app) when is_atom(otp_app) do
    manifest = read(otp_app)
    install(manifest)
    cache_asset_root(otp_app)
    manifest
  end

  # The host bundle dir plugin images are copied to at build (native_build's
  # apply_plugin_images!), cached so resolve_image/1 can return absolute paths
  # the native Image loader can read.
  defp cache_asset_root(otp_app) do
    root =
      case :code.priv_dir(otp_app) do
        {:error, _} -> ""
        dir -> Path.join(to_string(dir), "generated/plugin_assets")
      end

    :persistent_term.put(@pt_asset_root, root)
  end

  @doc """
  Boot-time entry point: load the host's manifest and register the activated
  plugins' screens so they're navigable. Called from `Mob.App.start/0`.

  `nil` (no resolvable host app — e.g. on host BEAM / tests) is a no-op. Safe
  to call when no tier-3/4 plugin is active: the manifest is empty and nothing
  is registered.
  """
  @spec boot(atom() | nil) :: :ok
  def boot(nil), do: :ok

  def boot(otp_app) when is_atom(otp_app) do
    load(otp_app)
    register_screens()
    :ok
  end

  @doc """
  Registers each manifest screen into `Mob.Nav.Registry` under an atom derived
  from its `default_route`, so the host (or the plugin's own screens) can
  navigate to it by route. The module is also directly navigable. The host
  still chooses *where* to surface a plugin screen in its `navigation/1`
  structure — registration only makes the destination resolvable.
  """
  @spec register_screens() :: :ok
  def register_screens do
    for %{module: mod, default_route: route} <- screens(),
        is_atom(mod),
        not is_nil(mod),
        is_binary(route),
        route != "" do
      Mob.Nav.Registry.register(String.to_atom(route), mod)
    end

    :ok
  end

  @doc """
  Starts the tier-4 plugin supervisor (runs each plugin's `lifecycle.on_start`,
  starts its `supervised` children, and the lifecycle event dispatcher). Called
  from `Mob.App.start/0` after the host's own `on_start/0`. No-op when no plugin
  declares a `:lifecycle`.
  """
  @spec start_lifecycle() :: :ok
  def start_lifecycle do
    if lifecycle() == [] do
      :ok
    else
      case Mob.Plugins.Supervisor.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end

  # ── Settings (tier 4) ─────────────────────────────────────────────────────

  @doc """
  Reads a plugin setting, falling back to the schema default when unset.

  Backed by `Mob.State` (the persistent K/V store) under a per-plugin namespaced
  key. Returns `nil` for an unknown plugin/key.
  """
  @spec get_setting(atom(), atom()) :: term()
  def get_setting(plugin, key) when is_atom(plugin) and is_atom(key) do
    case setting_spec(plugin, key) do
      {:ok, %{default: default}} -> Mob.State.get(setting_key(plugin, key), default)
      # A schema entry without a :default is malformed; fall back to nil rather
      # than crashing the reader (the manifest is build-time generated, but a
      # hand-edited or partial entry must not take down a settings read).
      {:ok, _entry} ->
        Logger.warning(
          "[Mob.Plugins] settings schema for #{inspect(plugin)}.#{key} has no :default; reading nil"
        )

        Mob.State.get(setting_key(plugin, key), nil)

      :error ->
        nil
    end
  end

  @doc """
  Writes a plugin setting after validating its value against the schema `type`.

  Returns `:ok`, `{:error, {:invalid_type, type}}`, or `{:error, :unknown_setting}`.
  """
  @spec put_setting(atom(), atom(), term()) :: :ok | {:error, term()}
  def put_setting(plugin, key, value) when is_atom(plugin) and is_atom(key) do
    case setting_spec(plugin, key) do
      {:ok, %{type: type}} ->
        if valid_setting?(type, value) do
          Mob.State.put(setting_key(plugin, key), value)
          :ok
        else
          {:error, {:invalid_type, type}}
        end

      # A schema entry without a :type can't be validated; treat as malformed
      # rather than crashing the writer.
      {:ok, _entry} ->
        Logger.warning(
          "[Mob.Plugins] settings schema for #{inspect(plugin)}.#{key} has no :type; rejecting write"
        )

        {:error, :unknown_setting}

      :error ->
        {:error, :unknown_setting}
    end
  end

  @doc """
  Resolves the screen a host pushes to let users edit a plugin's settings.

  A tier-4 plugin owns its settings UX; the host only needs the entry point, so
  it calls this to get the module to `push_screen/2`. Returns `:error` when the
  plugin declared no `editor_screen`.
  """
  @spec settings_editor(atom()) :: {:ok, module()} | :error
  def settings_editor(plugin) when is_atom(plugin) do
    case Enum.find(settings(), &(&1.plugin == plugin)) do
      %{editor_screen: mod} when is_atom(mod) -> {:ok, mod}
      _ -> :error
    end
  end

  defp setting_key(plugin, key), do: {:plugin_setting, plugin, key}

  defp setting_spec(plugin, key) do
    with %{schema: schema} when is_list(schema) <- Enum.find(settings(), &(&1.plugin == plugin)),
         %{} = entry <- Enum.find(schema, &(is_map(&1) and Map.get(&1, :key) == key)) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  defp valid_setting?(:boolean, v), do: is_boolean(v)
  defp valid_setting?(:string, v), do: is_binary(v)
  defp valid_setting?(:integer, v), do: is_integer(v)
  defp valid_setting?(_other, _v), do: false

  # ── Notifications (tier 4) ────────────────────────────────────────────────

  @doc """
  Routes a notification payload to the first matching plugin handler.

  Walks `notification_handlers/0` in order; the first handler whose `:match`
  (a map prefix-matched against the payload, or a `{M,F,arity}` predicate) wins,
  and its `{M,F,arity}` handler is invoked with the payload. Returns `:handled`
  or `:unhandled` (the host's own `handle_info` takes the unhandled case).

  This is the pure routing core; the central notification delivery that feeds it
  is wired natively (Phase 3).
  """
  @spec dispatch_notification(map()) :: :handled | :unhandled
  def dispatch_notification(payload) when is_map(payload) do
    Enum.find_value(notification_handlers(), :unhandled, fn handler ->
      if notification_match?(handler[:match], payload) do
        {m, f, _arity} = handler.handler
        apply(m, f, [payload])
        :handled
      end
    end)
  end

  defp notification_match?(match, payload) when is_map(match) do
    Enum.all?(match, fn {k, v} -> Map.get(payload, k) == v end)
  end

  defp notification_match?({m, f, _arity}, payload), do: apply(m, f, [payload]) == true
  defp notification_match?(_other, _payload), do: false

  @doc "Caches an already-built manifest (used by `load/1` and tests)."
  @spec install(map()) :: :ok
  def install(manifest) when is_map(manifest) do
    :persistent_term.put(@pt_key, Map.merge(@empty, manifest))
  end

  @doc "The cached manifest, or the empty set if nothing has been loaded."
  @spec manifest() :: map()
  def manifest, do: :persistent_term.get(@pt_key, @empty)

  @doc "Activated plugins' screen declarations (`%{plugin, module, default_route}`)."
  @spec screens() :: [map()]
  def screens, do: manifest().screens

  @doc "Activated plugins' lifecycle declarations."
  @spec lifecycle() :: [map()]
  def lifecycle, do: manifest().lifecycle

  @doc "Activated plugins' settings declarations."
  @spec settings() :: [map()]
  def settings, do: manifest().settings

  @doc "Activated plugins' notification handlers, in dispatch order."
  @spec notification_handlers() :: [map()]
  def notification_handlers, do: manifest().notification_handlers

  @doc """
  Resolves a `plugin://<plugin>/<file>` image reference to its on-device bundle
  path (`assets/plugin/<plugin>/<file>`), the convention `native_build` copies
  plugin images to. The renderer calls this when an image `src` uses the
  `plugin://` scheme; a non-plugin URL returns `:passthrough` so normal image
  handling continues. Returns `:error` for a malformed `plugin://` reference.
  """
  @spec resolve_image(String.t()) :: {:ok, String.t()} | :passthrough | :error
  def resolve_image("plugin://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [plugin, file] when plugin != "" and file != "" ->
        root = :persistent_term.get(@pt_asset_root, "")
        {:ok, Path.join([root, "assets", "plugin", plugin, file])}

      _ ->
        :error
    end
  end

  def resolve_image(_other), do: :passthrough

  @doc """
  Reads + evaluates the manifest for `otp_app` without caching. Returns the
  empty set when the priv dir or file is absent, or the file is malformed (a
  missing manifest must never crash boot).
  """
  @spec read(atom()) :: map()
  def read(otp_app) when is_atom(otp_app) do
    case :code.priv_dir(otp_app) do
      {:error, _} -> @empty
      dir -> read_path(Path.join([to_string(dir) | @rel_path]))
    end
  end

  @doc "Reads + evaluates a manifest from an explicit path (empty set on any failure)."
  @spec read_path(Path.t()) :: map()
  def read_path(path) do
    if File.exists?(path) do
      {evaluated, _bindings} = Code.eval_file(path)
      if is_map(evaluated), do: Map.merge(@empty, evaluated), else: @empty
    else
      @empty
    end
  rescue
    _ -> @empty
  end
end
