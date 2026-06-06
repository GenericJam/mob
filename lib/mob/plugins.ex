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

  @empty %{screens: [], lifecycle: [], settings: [], notification_handlers: []}
  @pt_key {__MODULE__, :manifest}
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
    manifest
  end

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
