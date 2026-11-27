# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeThemeBackgroundTest do
  use ExUnit.Case, async: true

  import Mob.Test.NativeSource

  @ios Path.expand("../../ios", __DIR__)

  # MOB-567. Verified on the iOS simulator (dark default theme on a light-mode
  # phone, an adaptive theme flipped live); these pin the mechanism.
  test "the iOS root paints the theme's background behind every screen" do
    body =
      Path.join(@ios, "MobRootView.swift")
      |> File.read!()
      |> code_only()
      |> region("public struct MobRootView: View {", ".environment(\\.mobAvailableSheetHeight")

    assert body =~
             ~r/\.background \{\s*if let background = model\.themeBackground \{\s*Color\(background\)\.ignoresSafeArea\(\)/

    model = File.read!(Path.join(@ios, "MobViewModel.swift")) |> code_only()
    assert model =~ "@Published public var themeBackground: UIColor?"
    assert model =~ "@objc public func applyThemeBackground(_ color: UIColor?)"
  end

  test "nif_set_theme hands the theme's background to every window's model" do
    nif = Path.join(@ios, "mob_nif.m") |> File.read!() |> code_only(:objc)

    set_theme =
      region(
        nif,
        "static ERL_NIF_TERM nif_set_theme(",
        "NSArray<NSString *> *mob_font_fallback(void)"
      )

    assert set_theme =~ ~s|json[@"background"]|
    assert set_theme =~ "dispatch_async(dispatch_get_main_queue(), ^{"
    assert set_theme =~ "g_theme_background = themeBackground;"
    assert set_theme =~ "[NSMutableArray arrayWithObject:MobViewModel.shared]"
    assert set_theme =~ "for (MobSceneEntry *entry in g_scene_entries)"
    assert set_theme =~ "[model applyThemeBackground:themeBackground];"

    # A window that connects after the theme was set takes it from the global.
    attach =
      region(
        nif,
        "NSObject *mob_scene_attach(UIWindowScene *scene) {",
        "mob_scene_finish_removal("
      )

    assert attach =~ "[entry.model applyThemeBackground:g_theme_background];"
  end
end
