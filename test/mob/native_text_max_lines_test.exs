# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeTextMaxLinesTest do
  use ExUnit.Case, async: true

  @ios Path.expand("../../ios", __DIR__)

  test "iOS parses max_lines at the native boundary" do
    header = File.read!(Path.join(@ios, "MobNode.h"))
    implementation = File.read!(Path.join(@ios, "MobNode.m"))
    nif = File.read!(Path.join(@ios, "mob_nif.m"))

    assert header =~ "NSInteger maxLines"
    assert implementation =~ "_maxLines = 0"
    assert nif =~ ~s|@"max_lines"|
    assert nif =~ "pv[MOB_PROP_max_lines]"
    # NSNumber-guarded rather than a bare `if (maxLines)`: a JSON null arrives
    # as NSNull, which is non-nil and does not respond to integerValue.
    assert nif =~ "if ([maxLines isKindOfClass:[NSNumber class]])"
    assert nif =~ "node.maxLines = [maxLines integerValue]"
  end

  test "iOS caps a label's lines only when max_lines is set" do
    source = File.read!(Path.join(@ios, "MobRootView.swift"))

    # Applied through ifLet so an unset node (0) takes no modifier at all and
    # keeps SwiftUI's default unlimited wrap, rather than .lineLimit(0).
    assert source =~ ".ifLet(node.maxLines > 0 ? node.maxLines : nil) { view, lines in"
    assert source =~ "view.lineLimit(lines).truncationMode(.tail)"
  end
end
