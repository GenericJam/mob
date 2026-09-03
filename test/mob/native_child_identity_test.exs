defmodule Mob.NativeChildIdentityTest do
  @moduledoc """
  Children are keyed by the author's `:id`, not by position (MOB-127).

  Positional identity means an insert or delete makes every later child a
  different view to the platform, so it is rebuilt and its state discarded
  rather than moved. Source-asserted because there is no host-side way to
  observe SwiftUI's diffing.
  """
  # credo:disable-for-this-file Jump.CredoChecks.VacuousTest
  use ExUnit.Case, async: true

  @ios File.read!(Path.expand("../../ios/MobRootView.swift", __DIR__))
  @nif File.read!(Path.expand("../../ios/mob_nif.m", __DIR__))
  @header File.read!(Path.expand("../../ios/MobNode.h", __DIR__))

  test "no ForEach over childNodes keys by position any more" do
    # The whole issue. Nine sites used `id: \\.offset`; the ones over childNodes
    # are the ones that repeat author content.
    refute @ios =~ "node.childNodes.enumerated()), id: \\.offset"
  end

  test "no ForEach iterates childNodes directly" do
    # Not a hard-coded count. The earlier version asserted "== 7", which failed
    # on any legitimate new container AND passed for the regression it named:
    # `ForEach(node.childNodes) { child in ... }` compiles, because MobNode has
    # a pre-existing Identifiable conformance returning ObjectIdentifier — a
    # brand-new identity every frame, since nodes are re-allocated from JSON on
    # every set_root. That is strictly worse than positional keying, and the
    # count test waved it through.
    unkeyed = ~r/ForEach\(\s*(Array\()?node\.childNodes/ |> Regex.scan(@ios) |> length()
    assert unkeyed == 0, "#{unkeyed} ForEach still iterates childNodes directly"

    identified =
      @ios |> String.split("ForEach(mobIdentifiedChildren(node.childNodes))") |> length()

    assert identified - 1 >= 7, "the identified child lists should still be there"
  end

  test "the author's :id is coerced to a String before it leaves Elixir" do
    # iOS reads :id as an NSString and ignores anything else; Android
    # canonicalises any JSON value. Without this, `id: user.id` with an integer
    # keyed rows on Android and fell back to positional on iOS — silently, for
    # the most natural way to write it.
    renderer = File.read!(Path.expand("../../lib/mob/renderer.ex", __DIR__))
    assert renderer =~ ~s|{:id, value} when is_number(value) ->|
    assert renderer =~ ~s|[{"id", to_string(value)}]|

    # Numbers only. :json.encode already stringifies bare atoms, so widening to
    # is_atom would turn `true` from a JSON boolean both platforms reject into
    # the real id "true", and `nil` into "" — handing ids to unnamed nodes.
    refute renderer =~ ~s|{:id, value} when is_atom(value)|
  end

  test "the identity ForEach keys on is populated for every node type" do
    # nativeViewId is the author's :id despite its name — only nativeViewProps
    # is gated on the node being a native_view. An earlier version of this
    # change added a second, identical property for the same prop.
    refute @header =~ "NSString *nodeId;"
    assert @nif =~ "id nativeViewId = pv[MOB_PROP_id];"
    assert @ios =~ "if let authored = child.nativeViewId, !authored.isEmpty {"
  end

  test "authored ids and positions cannot collide" do
    # Without distinct prefixes an author id of "3" and position 3 are the same
    # key, which silently merges two unrelated rows.
    assert @ios =~ ~s|key = "i\\u{1}" + authored|
    assert @ios =~ ~s|key = "p\\u{1}\\(index)"|
  end

  test "a duplicate id falls back rather than producing two equal keys" do
    # SwiftUI requires ForEach ids to be unique and misbehaves quietly when they
    # are not — a worse bug than the positional one being fixed.
    assert @ios =~ "if !seen.insert(key).inserted"
    assert @ios =~ ~s|key = "d\\u{1}\\(index)\\u{1}" + key|
  end

  test "an empty id is treated as absent" do
    # `id: ""` would otherwise give every unnamed-but-present sibling the same
    # key.
    assert @ios =~ "let authored = child.nativeViewId, !authored.isEmpty"
  end

  test "the tab bar keys on the tab's own id" do
    # This ForEach subscripts node.childNodes, so positional keying discards a
    # whole tab's content subtree when the tab list changes — toggling a
    # conditional "Admin" tab shifts every later tab's state into its
    # neighbour's. It was left positional in the first version of this change on
    # the false premise that it iterated only dictionaries.
    assert @ios =~ "ForEach(mobIdentifiedTabs(tabs))"
    refute @ios =~ "ForEach(Array(tabs.enumerated()), id: \\.offset)"
  end

  test "tab identities follow the same rules as child identities" do
    # Same prefixes and the same duplicate fallback: two unkeyed tabs must not
    # share a key. An earlier attempt gave every unkeyed tab the same constant.
    body =
      @ios
      |> String.split("func mobIdentifiedTabs(")
      |> Enum.at(1)
      |> String.split("\n}\n")
      |> Enum.at(0)

    assert body =~ ~s|key = "i\\u{1}" + authored|
    assert body =~ ~s|key = "p\\u{1}\\(index)"|
    assert body =~ "if !seen.insert(key).inserted"
  end
end
