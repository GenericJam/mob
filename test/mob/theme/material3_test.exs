defmodule Mob.Theme.Material3Test do
  use ExUnit.Case, async: true

  alias Mob.Theme.Material3

  describe "theme/0" do
    test "returns a compiled Mob.Theme struct" do
      assert %Mob.Theme{} = Material3.theme()
    end

    test "primary is M3 baseline purple (#6750A4)" do
      assert Material3.theme().primary == 0xFF6750A4
    end

    test "on_primary is white for contrast on the baseline primary" do
      assert Material3.theme().on_primary == 0xFFFFFFFF
    end

    test "background is M3 surface (#FEF7FF, warm neutral)" do
      assert Material3.theme().background == 0xFFFEF7FF
    end

    test "surface_raised is one tier above surface (M3 surface-container-high)" do
      theme = Material3.theme()
      # surface = #F3EDF7 (container), surface_raised = #ECE6F0 (container-high)
      assert theme.surface == 0xFFF3EDF7
      assert theme.surface_raised == 0xFFECE6F0
      assert theme.surface_raised != theme.surface
    end

    test "radius scale maps onto M3 shape tokens" do
      theme = Material3.theme()
      assert theme.radius_sm == 4
      assert theme.radius_md == 12
      assert theme.radius_lg == 16
      assert theme.radius_pill == 9999
    end

    test "error tokens use M3 baseline error color (#B3261E)" do
      theme = Material3.theme()
      assert theme.error == 0xFFB3261E
      assert theme.on_error == 0xFFFFFFFF
    end
  end

  describe "elevation_color/1" do
    test "level 0 equals the base surface (no tonal overlay)" do
      assert Material3.elevation_color(0) == Material3.theme().background
    end

    test "elevation increases tonal saturation through levels 1-5" do
      colors = Enum.map(0..5, &Material3.elevation_color/1)
      assert length(Enum.uniq(colors)) == 6, "each elevation level should be a distinct color"
    end

    test "raises on out-of-range elevation level" do
      assert_raise FunctionClauseError, fn -> Material3.elevation_color(-1) end
      assert_raise FunctionClauseError, fn -> Material3.elevation_color(6) end
    end
  end

  describe "type_role/1" do
    test "returns size + line_height + weight for known roles" do
      assert %{size: 57, line_height: 64, weight: 400} = Material3.type_role(:display_large)
      assert %{size: 16, line_height: 24, weight: 400} = Material3.type_role(:body_large)
      assert %{size: 14, line_height: 20, weight: 500} = Material3.type_role(:label_large)
    end

    test "covers all 15 M3 type roles" do
      roles = [
        :display_large,
        :display_medium,
        :display_small,
        :headline_large,
        :headline_medium,
        :headline_small,
        :title_large,
        :title_medium,
        :title_small,
        :body_large,
        :body_medium,
        :body_small,
        :label_large,
        :label_medium,
        :label_small
      ]

      assert length(roles) == 15

      for role <- roles do
        assert %{size: _, line_height: _, weight: _} = Material3.type_role(role)
      end
    end

    test "raises on unknown role" do
      assert_raise FunctionClauseError, fn -> Material3.type_role(:caption) end
    end
  end

  describe "shape/1" do
    test "returns M3 shape-scale corner radii in dp" do
      assert Material3.shape(:extra_small) == 4
      assert Material3.shape(:small) == 8
      assert Material3.shape(:medium) == 12
      assert Material3.shape(:large) == 16
      assert Material3.shape(:extra_large) == 28
      assert Material3.shape(:full) == 9999
    end
  end

  describe "integration with Mob.Theme" do
    test "can be set as the active theme via Mob.Theme.set/1" do
      Mob.Theme.set(Material3)
      active = Application.get_env(:mob, :theme)
      assert active.primary == 0xFF6750A4
      # Reset so we don't leak global state to other tests
      Application.delete_env(:mob, :theme)
    end

    test "supports per-field overrides via {Material3, overrides} tuple" do
      Mob.Theme.set({Material3, primary: 0xFFE91E63})
      active = Application.get_env(:mob, :theme)
      assert active.primary == 0xFFE91E63
      # M3's other tokens stay intact through the override
      assert active.background == 0xFFFEF7FF
      Application.delete_env(:mob, :theme)
    end
  end
end
