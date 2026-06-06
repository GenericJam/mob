defmodule Mob.PluginsTest do
  use ExUnit.Case, async: false

  @sample %{
    screens: [%{plugin: :p, module: P.Home, default_route: "/p"}],
    lifecycle: [%{plugin: :p, on_start: {P, :start, []}}],
    settings: [%{plugin: :p, schema: [%{key: :x, type: :boolean, default: true}]}],
    notification_handlers: [%{plugin: :p, match: %{type: "t"}, handler: {P, :h, 1}}]
  }

  describe "read_path/1" do
    test "reads + evaluates a manifest .exs file" do
      path = write_manifest(inspect(@sample))
      assert Mob.Plugins.read_path(path) == @sample
    end

    test "returns the empty set when the file is absent" do
      assert Mob.Plugins.read_path("/no/such/mob_plugins.exs") ==
               %{screens: [], lifecycle: [], settings: [], notification_handlers: []}
    end

    test "returns the empty set (never crashes) on a malformed file" do
      path = write_manifest("%{screens: [,,]}")
      assert Mob.Plugins.read_path(path).screens == []
    end

    test "fills in missing sections from the empty set" do
      path = write_manifest(inspect(%{screens: [%{plugin: :p, module: P, default_route: "/p"}]}))
      manifest = Mob.Plugins.read_path(path)
      assert manifest.lifecycle == []
      assert manifest.notification_handlers == []
    end
  end

  describe "install/1 + accessors" do
    test "caches a manifest and exposes each section" do
      Mob.Plugins.install(@sample)

      assert Mob.Plugins.screens() == @sample.screens
      assert Mob.Plugins.lifecycle() == @sample.lifecycle
      assert Mob.Plugins.settings() == @sample.settings
      assert Mob.Plugins.notification_handlers() == @sample.notification_handlers
    end

    test "merges partial manifests against the empty set" do
      Mob.Plugins.install(%{screens: [%{plugin: :q, module: Q, default_route: "/q"}]})
      assert [%{plugin: :q}] = Mob.Plugins.screens()
      assert Mob.Plugins.notification_handlers() == []
    end
  end

  describe "register_screens/0" do
    setup do
      # Nav.Registry seeds from an App module's navigation/1; a bare stub is enough.
      start_supervised!({Mob.Nav.Registry, __MODULE__.StubApp})
      :ok
    end

    defmodule StubApp do
      def navigation(_), do: %{type: :stack, name: :root, root: Root}
    end

    test "registers each plugin screen under its route, resolvable via the registry" do
      Mob.Plugins.install(%{
        screens: [
          %{plugin: :kv, module: Kv.ListScreen, default_route: "/kv/list"},
          %{plugin: :kv, module: Kv.DetailScreen, default_route: "/kv/detail"}
        ]
      })

      assert :ok = Mob.Plugins.register_screens()
      assert Mob.Nav.Registry.lookup(:"/kv/list") == {:ok, Kv.ListScreen}
      assert Mob.Nav.Registry.lookup(:"/kv/detail") == {:ok, Kv.DetailScreen}
    end

    test "boot/1 with nil host app is a no-op" do
      assert :ok = Mob.Plugins.boot(nil)
    end

    test "skips a screen entry whose module is nil (would resolve to nil at nav)" do
      Mob.Plugins.install(%{screens: [%{plugin: :p, module: nil, default_route: "/p"}]})
      assert :ok = Mob.Plugins.register_screens()
      assert Mob.Nav.Registry.lookup(:"/p") == {:error, :not_found}
    end

    test "skips a screen entry with a nil or empty default_route" do
      Mob.Plugins.install(%{
        screens: [
          %{plugin: :p, module: P.Home, default_route: nil},
          %{plugin: :q, module: Q.Home, default_route: ""}
        ]
      })

      assert :ok = Mob.Plugins.register_screens()
    end
  end

  describe "resolve_image/1" do
    test "maps a plugin:// reference to its bundle path" do
      assert Mob.Plugins.resolve_image("plugin://kv/icon.png") ==
               {:ok, "assets/plugin/kv/icon.png"}
    end

    test "passes through a non-plugin URL" do
      assert Mob.Plugins.resolve_image("https://x/y.png") == :passthrough
      assert Mob.Plugins.resolve_image("local.png") == :passthrough
    end

    test "errors on a malformed plugin:// reference" do
      assert Mob.Plugins.resolve_image("plugin://kv") == :error
      assert Mob.Plugins.resolve_image("plugin:///icon.png") == :error
    end
  end

  defp write_manifest(contents) do
    dir = Path.join(System.tmp_dir!(), "mob_plugins_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "mob_plugins.exs")
    File.write!(path, contents)
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end
end
