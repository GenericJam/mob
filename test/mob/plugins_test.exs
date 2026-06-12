defmodule Mob.PluginsTest do
  use ExUnit.Case, async: false

  @sample %{
    screens: [%{plugin: :p, module: P.Home, default_route: "/p"}],
    lifecycle: [%{plugin: :p, on_start: {P, :start, []}}],
    settings: [%{plugin: :p, schema: [%{key: :x, type: :boolean, default: true}]}],
    notification_handlers: [%{plugin: :p, match: %{type: "t"}, handler: {P, :h, 1}}],
    nifs: [:p_nif],
    composites: [],
    styles: [%{name: :mob_theme_x, theme: ThemeX}],
    default_style: nil
  }

  describe "read_path/1" do
    test "reads + evaluates a manifest .exs file" do
      path = write_manifest(inspect(@sample))
      assert Mob.Plugins.read_path(path) == @sample
    end

    test "returns the empty set when the file is absent" do
      assert Mob.Plugins.read_path("/no/such/mob_plugins.exs") ==
               %{
                 screens: [],
                 lifecycle: [],
                 settings: [],
                 notification_handlers: [],
                 nifs: [],
                 composites: [],
                 styles: [],
                 default_style: nil
               }
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
      assert Mob.Plugins.nifs() == @sample.nifs
    end

    test "merges partial manifests against the empty set" do
      Mob.Plugins.install(%{screens: [%{plugin: :q, module: Q, default_route: "/q"}]})
      assert [%{plugin: :q}] = Mob.Plugins.screens()
      assert Mob.Plugins.notification_handlers() == []
      assert Mob.Plugins.nifs() == []
    end
  end

  describe "ensure_nif_modules_loaded/0" do
    test "calls Code.ensure_loaded on each declared NIF module" do
      # A loadable module (already on disk) + a bogus one mirroring a host build
      # where a plugin NIF's native lib isn't linked (load tolerated, not fatal).
      Mob.Plugins.install(%{nifs: [Mob.Socket, :no_such_nif_module_zzz]})

      results = Mob.Plugins.ensure_nif_modules_loaded()

      assert {Mob.Socket, {:module, Mob.Socket}} in results
      assert {:no_such_nif_module_zzz, {:error, :nofile}} in results
    end

    test "is a no-op when no plugin declares a NIF" do
      Mob.Plugins.install(%{})
      assert Mob.Plugins.nifs() == []
      assert Mob.Plugins.ensure_nif_modules_loaded() == []
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

    test "an entry's :params map becomes route-bound params on the registered route" do
      Mob.Plugins.install(%{
        screens: [
          %{plugin: :ash, module: P.Shared, default_route: "/ash/a", params: %{resource: A}},
          %{plugin: :ash, module: P.Shared, default_route: "/ash/b", params: %{resource: B}}
        ]
      })

      assert :ok = Mob.Plugins.register_screens()
      assert Mob.Nav.Registry.lookup_route(:"/ash/a") == {:ok, P.Shared, %{resource: A}}
      assert Mob.Nav.Registry.lookup_route(:"/ash/b") == {:ok, P.Shared, %{resource: B}}
      # lookup/1 stays params-blind (back-compat)
      assert Mob.Nav.Registry.lookup(:"/ash/a") == {:ok, P.Shared}
    end

    test "a malformed :params (non-map) registers with empty route params" do
      Mob.Plugins.install(%{
        screens: [%{plugin: :p, module: P.Home, default_route: "/p2", params: :oops}]
      })

      assert :ok = Mob.Plugins.register_screens()
      assert Mob.Nav.Registry.lookup_route(:"/p2") == {:ok, P.Home, %{}}
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

  defmodule FixtureTheme do
    @moduledoc false
    def theme, do: Mob.Theme.build(primary: :lime_400, background: 0xFF111209)
  end

  describe "apply_default_style/0" do
    test "applies the default style's theme module at boot" do
      Mob.Plugins.install(%{
        styles: [%{name: :fixture_style, theme: FixtureTheme}],
        default_style: :fixture_style
      })

      before = Mob.Theme.current()
      on_exit(fn -> Mob.Theme.set(before) end)

      assert :ok = Mob.Plugins.apply_default_style()
      assert Mob.Theme.current() == FixtureTheme.theme()
    end

    test "no default style is a no-op" do
      Mob.Plugins.install(%{styles: [], default_style: nil})
      assert :ok = Mob.Plugins.apply_default_style()
    end

    test "a broken theme module logs instead of failing boot" do
      Mob.Plugins.install(%{
        styles: [%{name: :bad, theme: NoSuch.Theme}],
        default_style: :bad
      })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Mob.Plugins.apply_default_style()
        end)

      assert log =~ "failed to apply"
    end
  end

  describe "resolve_image/1" do
    setup do
      on_exit(fn -> Mob.Plugins.install_asset_root("") end)
    end

    test "maps a plugin:// reference to an absolute path under the cached asset root" do
      Mob.Plugins.install_asset_root("/bundle/priv/generated/plugin_assets")

      assert Mob.Plugins.resolve_image("plugin://kv/icon.png") ==
               {:ok, "/bundle/priv/generated/plugin_assets/assets/plugin/kv/icon.png"}
    end

    test "errors (never a relative path) when the asset root has not been cached" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Mob.Plugins.resolve_image("plugin://kv/icon.png") == :error
        end)

      assert log =~ "asset root"
    end

    test "passes through a non-plugin URL" do
      assert Mob.Plugins.resolve_image("https://x/y.png") == :passthrough
      assert Mob.Plugins.resolve_image("local.png") == :passthrough
    end

    test "errors on a malformed plugin:// reference" do
      Mob.Plugins.install_asset_root("/bundle")
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
