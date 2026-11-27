# Source-contract tests for the simulator branch of long_press_xy, which
# host-side Elixir cannot execute (MOB-572). Simulator evidence is in the PR.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeIOSLongPressXYTest do
  use ExUnit.Case, async: true

  alias Mob.Test.NativeSource

  @nif Path.expand("../../ios/mob_nif.m", __DIR__)
       |> File.read!()
       |> NativeSource.code_only(:objc)

  defp simulator_branch do
    @nif
    |> NativeSource.region(
      "static ERL_NIF_TERM nif_long_press_xy(ErlNifEnv *env",
      "__block UIWindow *targetWindow = nil;"
    )
  end

  test "a Mob node's on_long_press is found by its tracked frame and called" do
    body = simulator_branch()
    assert body =~ "MobViewModel.shared.displayedRoot"
    assert body =~ "mob_long_press_target_in(root, pt, onPresented, NO, frames, &target, &area)"
    assert body =~ "target.onLongPress();"

    helper =
      NativeSource.region(
        @nif,
        "static void mob_long_press_target_in(",
        "static BOOL mob_open_panels_in("
      )

    assert helper =~
             ~r/node\.onLongPress && node\.nativeViewId && sheet == wantSheet &&\s*mob_node_type_long_presses\(node\.nodeType\)/

    assert helper =~ "CGRectContainsPoint(r, pt) && area <= *bestArea"
  end

  test "a hit view outside the root controller's view searches the sheets" do
    body = simulator_branch()
    assert body =~ "UIView *rootView = hitWindow.rootViewController.view;"
    assert body =~ "BOOL onPresented = rootView && ![hitView isDescendantOfView:rootView];"
  end

  test "with an anchored dismiss scrim open, only the open panels are searched" do
    body = simulator_branch()

    assert body =~
             ~r/if \(!onPresented && mob_open_panels_in\(root, panels\)\) \{\s*for \(MobNode \*panel in panels\)\s*mob_long_press_target_in\(panel, pt, NO, NO, frames, &target, &area\);\s*\} else \{\s*mob_long_press_target_in\(root, pt, onPresented, NO, frames, &target, &area\);/

    panels = NativeSource.region(@nif, "static BOOL mob_open_panels_in(", "#endif")
    assert panels =~ "if (node.nodeType == MobNodeTypeSheet)\n        return NO;"

    assert panels =~
             "node.nodeType == MobNodeTypeAnchored && node.children.count > 1"

    assert panels =~ "[panels addObject:node.children[1]];"
    assert panels =~ "scrim = node.onTap != nil;"
    assert panels =~ "scrim = mob_open_panels_in(child, panels) || scrim;"
  end

  test "a point in another scene's window is not matched against the shared tree" do
    body = simulator_branch()
    assert body =~ "NSString *sceneId = MobViewModel.shared.sceneId;"

    assert body =~
             "if (!sceneId || ![hitWindow.windowScene.session.persistentIdentifier isEqualToString:sceneId])\n          return NO;"

    assert NativeSource.index_of(body, "MobViewModel.shared.sceneId") <
             NativeSource.index_of(body, "MobViewModel.shared.displayedRoot")
  end

  test "only node types that get mobGestures are long-press targets" do
    types =
      NativeSource.region(@nif, "static BOOL mob_node_type_long_presses(", "static void")

    for t <- ~w(Column Row Wrap Box Label Icon Anchored),
        do: assert(types =~ "case MobNodeType#{t}:")

    for t <- ~w(Button TextField Slider Toggle Image Scroll),
        do: refute(types =~ "MobNodeType#{t}")
  end

  test "the result reports an observed event, and nothing taps instead" do
    body = simulator_branch()

    assert NativeSource.index_of(body, "const uint64_t seq_before = mob_ui_event_seq();") <
             NativeSource.index_of(body, "target.onLongPress();")

    assert body =~ "mob_await_ui_event(seq_before, MOB_TAP_SETTLE_MS)"
    assert body =~ ~s|enif_make_atom(env, "no_effect")|
    refute body =~ "accessibilityActivate"
  end
end
