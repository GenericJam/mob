defmodule Mob.TestTest do
  use ExUnit.Case, async: true

  # Tests for the pure helpers in `Mob.Test` — flatten_tree, find logic, normalize.
  # The RPC-based functions are exercised on-device by integration tests
  # (see test/onboarding/) and aren't covered here.

  alias Mob.Test, as: M

  describe "reset_to/4" do
    test "rejects an invalid scope before making an RPC" do
      assert_raise ArgumentError, ~r/Mob.Test.reset_to\/4: invalid scope :tabs/, fn ->
        M.reset_to(:unused_node, :login, %{}, scope: :tabs)
      end
    end
  end

  describe "switch_tab/3" do
    test "rejects transitions that application sockets reject" do
      assert_raise ArgumentError, ~r/Mob.Test.switch_tab\/3: invalid transition :puhs/, fn ->
        M.switch_tab(:unused_node, :settings, transition: :puhs)
      end

      assert_raise ArgumentError, ~r/invalid transition :none/, fn ->
        M.switch_tab(:unused_node, :settings, transition: :none)
      end

      assert_raise ArgumentError, ~r/invalid transition nil/, fn ->
        M.switch_tab(:unused_node, :settings, transition: nil)
      end
    end

    test "rejects invalid mount params before making an RPC" do
      assert_raise ArgumentError, ~r/Mob.Test.switch_tab\/3: invalid mount_params/, fn ->
        M.switch_tab(:unused_node, :settings, mount_params: [user_id: 7])
      end
    end
  end

  defp sample_tree do
    %{
      type: :root,
      class: nil,
      label: nil,
      value: nil,
      frame: {0.0, 0.0, 393.0, 852.0},
      bg_color: nil,
      text_color: nil,
      children: [
        %{
          type: :window,
          class: "UIWindow",
          label: nil,
          value: nil,
          frame: {0.0, 0.0, 393.0, 852.0},
          bg_color: 0xFF000000,
          text_color: nil,
          children: [
            %{
              type: :scroll,
              class: "SwiftUI.ScrollViewHost",
              label: nil,
              value: nil,
              frame: {0.0, 62.0, 393.0, 756.0},
              bg_color: nil,
              text_color: nil,
              children: [
                %{
                  type: :button,
                  class: "SwiftUI.CGDrawingView",
                  label: "Roll Dice",
                  value: nil,
                  frame: {24.0, 416.0, 327.0, 53.5},
                  bg_color: 0xFF2196F3,
                  text_color: 0xFFFFFFFF,
                  children: []
                },
                %{
                  type: :text,
                  class: "SwiftUI.CGDrawingView",
                  label: "Hello",
                  value: nil,
                  frame: {24.0, 480.0, 100.0, 24.0},
                  bg_color: nil,
                  text_color: 0xDE000000,
                  children: []
                },
                %{
                  type: :button,
                  class: "SwiftUI.CGDrawingView",
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
        class: "UIButton",
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
        class: nil,
        label: nil,
        value: nil,
        frame: {0.0, 0.0, 1.0, 1.0},
        bg_color: nil,
        text_color: nil,
        children: [
          %{
            type: :text_field,
            class: "UITextField",
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
      {"type":"root","class":null,"label":null,"value":null,"frame":[0,0,393,852],
       "bg_color":null,"text_color":null,
       "children":[{"type":"button","class":"android.widget.Button",
                    "label":"Save","value":null,
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
      assert button.class == "android.widget.Button"
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
      assert root.class == nil
    end

    test "passes non-node terms (e.g. an error tuple) through untouched" do
      assert M.normalize_view_tree({:error, :not_loaded}) == {:error, :not_loaded}
    end
  end

  describe "color_census/1" do
    test "tallies painted colours by channel, ignoring nils" do
      assert %{background: bg, text: text} = M.color_census(sample_tree())

      assert bg == %{0xFF000000 => 1, 0xFF2196F3 => 2}
      assert text == %{0xFFFFFFFF => 2, 0xDE000000 => 1}
    end

    test "a tree whose backgrounds were all discarded reports none" do
      stripped = strip_backgrounds(sample_tree())

      assert %{background: bg, text: text} = M.color_census(stripped)

      # This is the regression shape the API exists to make visible: a theme
      # that drops every Box background collapses :background to empty while
      # text colours are untouched.
      assert bg == %{}
      assert map_size(text) == 2
    end

    test "two themes that differ produce different background key sets" do
      primary = M.color_census(sample_tree()).background
      raised = M.color_census(recolor(sample_tree(), 0xFF1E1E1E)).background

      refute primary == raised
      assert Map.keys(raised) == [0xFF1E1E1E]
    end

    defp strip_backgrounds(node), do: recolor(node, nil)

    defp recolor(%{children: children} = node, color) do
      %{
        node
        | bg_color: if(node.bg_color, do: color),
          children: Enum.map(children, &recolor(&1, color))
      }
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

  # ── Colour sampling (pure reduction over a raw RGBA buffer) ───────────────────

  describe "reduce_rgba/3" do
    # sample_region/4 hands back the buffer in R,G,B,A order; colours come out
    # 0xAARRGGBB. `px` builds buffer bytes from a 0xAARRGGBB literal so the tests
    # read in the repo's colour form.
    defp px(argb) do
      <<a, r, g, b>> = <<argb::32>>
      <<r, g, b, a>>
    end

    defp fill(argb, count), do: argb |> px() |> :binary.copy(count)

    test "channel order: R,G,B,A bytes in, 0xAARRGGBB out" do
      # Distinct values per channel, so a swapped byte order can't pass.
      assert {:ok, %{average: 0x04010203, dominant: 0x04010203}} =
               M.reduce_rgba(<<1, 2, 3, 4>>, 1, 1)
    end

    test "a single pixel reports itself with full confidence" do
      assert {:ok, sample} = M.reduce_rgba(px(0xFF2196F3), 1, 1)

      assert sample == %{
               average: 0xFF2196F3,
               dominant: 0xFF2196F3,
               dominant_share: 1.0,
               distinct: 1,
               pixels: 1
             }
    end

    test "a flat fill: average and dominant agree, share is 1.0" do
      assert {:ok, sample} = M.reduce_rgba(fill(0xFF2196F3, 8), 4, 2)

      assert sample.average == 0xFF2196F3
      assert sample.dominant == 0xFF2196F3
      assert sample.dominant_share == 1.0
      assert sample.distinct == 1
      assert sample.pixels == 8
    end

    test "text over a fill: dominant keeps the background, average is dragged off it" do
      # 8 px of :primary blue + 2 px of white "text".
      buffer = fill(0xFF2196F3, 8) <> fill(0xFFFFFFFF, 2)

      assert {:ok, sample} = M.reduce_rgba(buffer, 5, 2)

      assert sample.dominant == 0xFF2196F3
      assert sample.dominant_share == 0.8
      assert sample.distinct == 2
      # (8*33 + 2*255)/10 = 77.4, (8*150 + 2*255)/10 = 171.0, (8*243 + 2*255)/10 = 245.4
      assert sample.average == 0xFF4DABF5
      refute sample.average == sample.dominant
    end

    test "average is a per-channel mean rounded to nearest, alpha included" do
      # Same RGB at alpha 0 and 255: alpha averages to round(127.5) = 128 and the
      # colour channels are untouched — no un-premultiplying, no alpha weighting.
      buffer = px(0x00808080) <> px(0xFF808080)

      assert {:ok, sample} = M.reduce_rgba(buffer, 2, 1)
      assert sample.average == 0x80808080
    end

    test "a tie for dominant breaks toward the higher colour value (deterministic)" do
      buffer = px(0x00808080) <> px(0xFF808080)

      assert {:ok, sample} = M.reduce_rgba(buffer, 2, 1)
      assert sample.dominant == 0xFF808080
      assert sample.dominant_share == 0.5
      assert sample.distinct == 2
    end

    test "a gradient reports a low dominant_share — don't trust :dominant there" do
      buffer =
        Enum.map_join(0..9, fn i -> px(0xFF000000 + i) end)

      assert {:ok, sample} = M.reduce_rgba(buffer, 10, 1)

      assert sample.distinct == 10
      assert sample.dominant_share == 0.1
    end

    test "zero-size regions are refused, not reported as black" do
      assert M.reduce_rgba(<<>>, 0, 0) == {:error, :empty_region}
      assert M.reduce_rgba(<<>>, 10, 0) == {:error, :empty_region}
      assert M.reduce_rgba(px(0xFF2196F3), -1, 1) == {:error, :empty_region}
    end

    test "a buffer that doesn't match the reported dimensions yields no colour" do
      # The whole point of this branch: a truncated or mis-sized buffer must not
      # produce a plausible-looking colour from partial data.
      assert M.reduce_rgba(fill(0xFF2196F3, 7), 4, 2) == {:error, :size_mismatch}
      assert M.reduce_rgba(fill(0xFF2196F3, 9), 4, 2) == {:error, :size_mismatch}
      assert M.reduce_rgba(<<1, 2, 3>>, 1, 1) == {:error, :size_mismatch}
    end

    test "the glass-theme regression is visible in the reduction" do
      # The real bug: the iOS renderer discarded every Box background, so a Box
      # with background: :primary rendered identically to one with
      # :surface_raised. Sampling the two regions is what makes that detectable.
      primary = fill(0xFF2196F3, 16)
      surface_raised = fill(0xFF1E1E1E, 16)

      {:ok, a} = M.reduce_rgba(primary, 4, 4)
      {:ok, b} = M.reduce_rgba(surface_raised, 4, 4)
      refute a.dominant == b.dominant

      # Under the bug both Boxes paint the theme's base surface: identical samples.
      {:ok, bug_a} = M.reduce_rgba(surface_raised, 4, 4)
      assert bug_a.dominant == b.dominant
    end
  end

  describe "sample_color/2" do
    test "an unreachable node surfaces the dist failure instead of a colour" do
      assert {:error, {:badrpc, _}} = M.sample_color(:"nonexistent_mob_node@127.0.0.1", "card")

      assert {:error, {:badrpc, _}} =
               M.sample_color(:"nonexistent_mob_node@127.0.0.1", {0.0, 0.0, 10.0, 10.0})
    end
  end
end
