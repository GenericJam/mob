# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeTextMaxLinesTest do
  use ExUnit.Case, async: true

  alias Mob.Test.NativeSource

  @ios Path.expand("../../ios", __DIR__)
  @header Path.join(@ios, "MobNode.h") |> File.read!() |> NativeSource.code_only(:objc)
  @implementation Path.join(@ios, "MobNode.m") |> File.read!() |> NativeSource.code_only(:objc)
  @nif Path.join(@ios, "mob_nif.m") |> File.read!()
  @swift Path.join(@ios, "MobRootView.swift") |> File.read!()

  test "iOS parses max_lines at the native boundary" do
    prop_enum =
      NativeSource.region(
        @nif,
        "typedef NS_ENUM(NSUInteger, MobPropKey) {",
        "static NSDictionary<NSString *, NSNumber *> *mob_prop_slots(void) {"
      )
      |> NativeSource.code_only(:objc)

    prop_slots =
      NativeSource.region(
        @nif,
        "static NSDictionary<NSString *, NSNumber *> *mob_prop_slots(void) {",
        "static MobNode *mob_node_from_dict(NSDictionary *dict) {"
      )
      |> NativeSource.code_only(:objc)

    node_builder =
      NativeSource.region(
        @nif,
        "static MobNode *mob_node_from_dict(NSDictionary *dict) {",
        "static ERL_NIF_TERM nif_exit_app"
      )
      |> NativeSource.code_only(:objc)

    assert @header =~ "NSInteger maxLines"
    assert @implementation =~ "_maxLines = 0"
    assert prop_enum =~ "MOB_PROP_max_lines"
    assert prop_slots =~ ~s|[MOB_PROP_max_lines] = @"max_lines"|
    assert node_builder =~ "id maxLines = pv[MOB_PROP_max_lines]"
    assert node_builder =~ "if ([maxLines isKindOfClass:[NSNumber class]])"
    assert node_builder =~ "node.maxLines = [maxLines integerValue]"
  end

  test "iOS caps a label's lines only when max_lines is set" do
    label =
      @swift
      |> NativeSource.region("case .label:", "case .icon:")
      |> NativeSource.code_only()

    assert label =~ ".ifLet(node.maxLines > 0 ? node.maxLines : nil) { view, lines in"
    assert label =~ "view.lineLimit(lines).truncationMode(.tail)"
  end
end
