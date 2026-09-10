# This source-contract test guards UIKit behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeAlertWindowTest do
  use ExUnit.Case, async: true

  alias Mob.Test.NativeSource

  @source Path.expand("../../ios/mob_nif.m", __DIR__) |> File.read!()

  @root_vc NativeSource.region(
             @source,
             "static UIViewController *root_vc(void) {",
             "// ── NIF: alert_show/3"
           )
           |> NativeSource.code_only(:objc)
           |> String.replace(~r/\s+/, " ")

  test "iOS alerts choose a usable window from a foreground scene" do
    assert @root_vc =~
             "if (![scene isKindOfClass:[UIWindowScene class]] || " <>
               "scene.activationState != UISceneActivationStateForegroundActive) continue; " <>
               "UIWindowScene *window_scene = (UIWindowScene *)scene; " <>
               "UIViewController *vc = window_scene.keyWindow.rootViewController; " <>
               "if (!vc) { for (UIWindow *window in window_scene.windows) { " <>
               "if (window.rootViewController) { vc = window.rootViewController; break; } } } " <>
               "if (!vc) continue; while (vc.presentedViewController) " <>
               "vc = vc.presentedViewController; return vc;"
  end
end
