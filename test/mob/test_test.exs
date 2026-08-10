defmodule Mob.TestTest do
  use ExUnit.Case, async: true

  # Tests for the pure helpers in `Mob.Test` — flatten_tree, find logic, normalize.
  # The RPC-based functions are exercised on-device by integration tests
  # (see test/onboarding/) and aren't covered here.

  alias Mob.Test, as: M

  defp sample_tree do
    %{
      type: :root,
      label: nil,
      value: nil,
      frame: {0.0, 0.0, 393.0, 852.0},
      bg_color: nil,
      text_color: nil,
      children: [
        %{
          type: :window,
          label: nil,
          value: nil,
          frame: {0.0, 0.0, 393.0, 852.0},
          bg_color: 0xFF000000,
          text_color: nil,
          children: [
            %{
              type: :scroll,
              label: nil,
              value: nil,
              frame: {0.0, 62.0, 393.0, 756.0},
              bg_color: nil,
              text_color: nil,
              children: [
                %{
                  type: :button,
                  label: "Roll Dice",
                  value: nil,
                  frame: {24.0, 416.0, 327.0, 53.5},
                  bg_color: 0xFF2196F3,
                  text_color: 0xFFFFFFFF,
                  children: []
                },
                %{
                  type: :text,
                  label: "Hello",
                  value: nil,
                  frame: {24.0, 480.0, 100.0, 24.0},
                  bg_color: nil,
                  text_color: 0xDE000000,
                  children: []
                },
                %{
                  type: :button,
                  label: "Roll again",
                  value: nil,
                  frame: {24.0, 520.0, 327.0, 53.5},
                  bg_color: 0xFF2196F3,
                  text_color: 0xFFFFFFFF,
                  children: []
                }
              ]
            }
          ]
        }
      ]
    }
  end

  describe "flatten_tree/1" do
    test "produces one entry per node with monotonically deeper paths" do
      flat = M.flatten_tree(sample_tree())

      paths = Enum.map(flat, fn {p, _} -> p end)

      assert paths == [
               [],
               [0],
               [0, 0],
               [0, 0, 0],
               [0, 0, 1],
               [0, 0, 2]
             ]
    end

    test "drops :children from each entry but keeps everything else" do
      flat = M.flatten_tree(sample_tree())
      {_path, root} = hd(flat)

      assert Map.has_key?(root, :type)
      assert Map.has_key?(root, :frame)
      refute Map.has_key?(root, :children)
    end

    test "leaves with no children still emit one entry" do
      tree = %{
        type: :button,
        label: "Solo",
        value: nil,
        frame: {0.0, 0.0, 1.0, 1.0},
        bg_color: nil,
        text_color: nil,
        children: []
      }

      assert [{[], node}] = M.flatten_tree(tree)
      assert node.label == "Solo"
    end

    test "keeps painted colours on every flattened entry" do
      colours =
        sample_tree()
        |> M.flatten_tree()
        |> Enum.map(fn {_p, n} -> {n.bg_color, n.text_color} end)

      # A styling regression that dropped every Box background would turn each
      # of these into {nil, nil} — that is the whole point of surfacing them.
      assert {0xFF2196F3, 0xFFFFFFFF} in colours
      assert {nil, 0xDE000000} in colours
      assert Enum.count(colours, fn {bg, _} -> bg == 0xFF2196F3 end) == 2
    end
  end

  describe "find_view (search semantics)" do
    # find_view/2 takes a node arg and does RPC. The pure substring filter is
    # what we test here — we apply it directly to a flattened tree.

    test "matches by label, returns path-tagged entries" do
      matches =
        sample_tree()
        |> M.flatten_tree()
        |> Enum.filter(fn {_path, n} ->
          String.contains?(to_string(n[:label] || ""), "Roll")
        end)

      labels = Enum.map(matches, fn {_p, n} -> n.label end)
      assert "Roll Dice" in labels
      assert "Roll again" in labels
      assert length(matches) == 2
    end

    test "matches against value as well as label" do
      tree = %{
        type: :root,
        label: nil,
        value: nil,
        frame: {0.0, 0.0, 1.0, 1.0},
        bg_color: nil,
        text_color: nil,
        children: [
          %{
            type: :text_field,
            label: "Name",
            value: "Roll-something",
            frame: {0.0, 0.0, 1.0, 1.0},
            bg_color: nil,
            text_color: nil,
            children: []
          }
        ]
      }

      matches =
        tree
        |> M.flatten_tree()
        |> Enum.filter(fn {_p, n} ->
          String.contains?(to_string(n[:label] || ""), "Roll") or
            String.contains?(to_string(n[:value] || ""), "Roll")
        end)

      assert length(matches) == 1
    end
  end

  describe "normalize_view_tree/1 (Android JSON path)" do
    defp android_json do
      """
      {"type":"root","label":null,"value":null,"frame":[0,0,393,852],
       "bg_color":null,"text_color":null,
       "children":[{"type":"button","label":"Save","value":null,
                    "frame":[24,720,327,48],
                    "bg_color":4280391411,"text_color":4294967295,
                    "children":[]}]}
      """
    end

    test "converts string keys, string type and list frame to the iOS shape" do
      root = android_json() |> :json.decode() |> M.normalize_view_tree()

      assert root.type == :root
      assert root.frame == {0.0, 0.0, 393.0, 852.0}

      [button] = root.children
      assert button.type == :button
      assert button.label == "Save"
      assert button.frame == {24.0, 720.0, 327.0, 48.0}
    end

    test "carries colours through as 0xAARRGGBB integers, matching iOS" do
      [button] =
        android_json() |> :json.decode() |> M.normalize_view_tree() |> Map.fetch!(:children)

      # JSON has no hex literal, so the bridge sends the same integer decimal.
      assert button.bg_color == 0xFF2196F3
      assert button.text_color == 0xFFFFFFFF
    end

    test "JSON null becomes nil, not :json.decode's :null atom" do
      root = android_json() |> :json.decode() |> M.normalize_view_tree()

      # A node that paints nothing still carries the keys, so consumers can read
      # node.bg_color on any node and compare against nil.
      assert Map.has_key?(root, :bg_color)
      assert root.bg_color == nil
      assert root.text_color == nil
      assert root.label == nil
      assert root.value == nil
    end

    test "passes non-node terms (e.g. an error tuple) through untouched" do
      assert M.normalize_view_tree({:error, :not_loaded}) == {:error, :not_loaded}
    end
  end

  # ── screenshot + scroll pure helpers ──────────────────────────────────────

  describe "normalize_screenshot_opts/1" do
    test "defaults to png, quality 90, scale 1.0" do
      assert %{format: :png, quality: 90, scale: 1.0} = M.normalize_screenshot_opts([])
    end

    test "passes jpeg through and clamps quality to 0..100" do
      assert %{format: :jpeg, quality: 60} =
               M.normalize_screenshot_opts(format: :jpeg, quality: 60)

      assert %{quality: 100} = M.normalize_screenshot_opts(quality: 250)
      assert %{quality: 0} = M.normalize_screenshot_opts(quality: -5)
    end

    test "floatifies an integer scale" do
      assert %{scale: 2.0} = M.normalize_screenshot_opts(scale: 2)
    end

    test "raises on an unsupported format" do
      assert_raise ArgumentError, ~r/:png or :jpeg/, fn ->
        M.normalize_screenshot_opts(format: :gif)
      end
    end
  end

  describe "resolve_scroll_target/2" do
    defp pixel_info do
      %{
        offset: {0.0, 200.0},
        content: {393.0, 2400.0},
        viewport: {393.0, 756.0},
        max_offset: {0.0, 1644.0},
        kind: :pixel
      }
    end

    test ":top and :bottom resolve to the extremes" do
      assert M.resolve_scroll_target(:top, pixel_info()) == {0.0, 0.0}
      assert M.resolve_scroll_target(:bottom, pixel_info()) == {0.0, 1644.0}
    end

    test "{:page, n} steps n viewport-heights from the top, keeping x" do
      # 1 page = one viewport height (756)
      assert M.resolve_scroll_target({:page, 1}, pixel_info()) == {0.0, 756.0}
      # 3 pages would be 2268 but clamps to max_offset y (1644)
      assert M.resolve_scroll_target({:page, 3}, pixel_info()) == {0.0, 1644.0}
    end

    test "absolute {x, y} is clamped to the extent" do
      assert M.resolve_scroll_target({0.0, 500.0}, pixel_info()) == {0.0, 500.0}
      assert M.resolve_scroll_target({0.0, 9999.0}, pixel_info()) == {0.0, 1644.0}
      assert M.resolve_scroll_target({0.0, -10.0}, pixel_info()) == {0.0, 0.0}
    end

    test "works in item units for an :index list (page = visible item count)" do
      index_info = %{
        offset: {0.0, 0.0},
        content: {0.0, 100.0},
        viewport: {0.0, 8.0},
        max_offset: {0.0, 92.0},
        kind: :index
      }

      # one page = 8 items
      assert M.resolve_scroll_target({:page, 1}, index_info) == {0.0, 8.0}
      assert M.resolve_scroll_target(:bottom, index_info) == {0.0, 92.0}
    end
  end

  describe "tour_offsets/2" do
    test "pages from 0 to max_offset by viewport height, pinning a final bottom page" do
      offsets = M.tour_offsets(pixel_info(), [])
      ys = Enum.map(offsets, fn {_x, y} -> y end)

      assert List.first(ys) == 0.0
      assert List.last(ys) == 1644.0
      # 1644 / 756 -> ceil 3 steps: 0, 756, 1512, 1644
      assert ys == [0.0, 756.0, 1512.0, 1644.0]
    end

    test "overlap shrinks the step" do
      ys = M.tour_offsets(pixel_info(), overlap: 0.5) |> Enum.map(fn {_x, y} -> y end)
      # step = 756 * 0.5 = 378
      assert Enum.at(ys, 1) == 378.0
      assert List.last(ys) == 1644.0
    end

    test "keeps the current x offset across pages" do
      info = %{pixel_info() | offset: {40.0, 0.0}}
      assert Enum.all?(M.tour_offsets(info, []), fn {x, _y} -> x == 40.0 end)
    end

    test "a non-scrollable view yields a single page at the top" do
      info = %{pixel_info() | max_offset: {0.0, 0.0}}
      assert M.tour_offsets(info, []) == [{0.0, 0.0}]
    end
  end
end
