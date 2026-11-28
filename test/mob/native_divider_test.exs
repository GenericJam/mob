# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeDividerTest do
  use ExUnit.Case, async: true

  alias Mob.Test.NativeSource

  @root Path.expand("../..", __DIR__)

  defp divider_case do
    @root
    |> Path.join("ios/MobRootView.swift")
    |> File.read!()
    |> NativeSource.code_only()
    |> NativeSource.region("case .divider:", "case .spacer:")
  end

  # MOB-568. SwiftUI's Divider() takes the axis of its stack, so inside an
  # HStack (a Row) it drew a vertical hairline that `.frame(height:)` then
  # clamped to a 1x1 tick: MishkaSeparator's labelled rules vanished. Android's
  # HorizontalDivider is horizontal in any container.
  test "iOS divider is a horizontal rule in any container" do
    region = divider_case()

    refute region =~ "Divider()"
    assert region =~ "Rectangle()"
    assert region =~ "Color(UIColor.separator)"

    fill = NativeSource.index_of(region, ".fill(node.color.map { Color($0) }")
    height = NativeSource.index_of(region, ".frame(height: node.thickness)")
    width = NativeSource.index_of(region, ".frame(maxWidth: .infinity)")
    padding = NativeSource.index_of(region, ".padding(node.paddingEdgeInsets)")

    # thickness is the rule's own height, the width fills, and padding sits
    # outside both, as in Compose's modifier order.
    assert fill < height
    assert height < width
    assert width < padding
  end
end
