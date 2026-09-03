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

  test "every childNodes ForEach goes through the identity helper" do
    # Count them rather than spot-check: a new ForEach added later with
    # positional keys is the regression this guards.
    helper_uses =
      @ios |> String.split("ForEach(mobIdentifiedChildren(node.childNodes))") |> length()

    assert helper_uses - 1 == 7, "expected 7 identified child lists, found #{helper_uses - 1}"
  end

  test "the author's :id reaches MobNode for every node type" do
    # It previously reached native only as nativeViewId, and only for
    # native_view nodes, so there was nothing for ForEach to key on.
    assert @header =~ "@property(nonatomic, copy, nullable) NSString *nodeId;"
    assert @nif =~ "id nodeId = pv[MOB_PROP_id];"
    assert @nif =~ "node.nodeId = nodeId;"
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
    assert @ios =~ "let authored = child.nodeId, !authored.isEmpty"
  end
end
