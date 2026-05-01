defmodule Mob.ThemeTest do
  use ExUnit.Case, async: true

  alias Mob.Theme

  describe "build/1" do
    test "returns default theme with no overrides" do
      t = Theme.build()
      assert t.primary == :blue_500
      assert t.type_scale == 1.0
      assert t.radius_md == 10
    end

    test "overrides specific fields" do
      t = Theme.build(primary: :emerald_500, type_scale: 1.2)
      assert t.primary == :emerald_500
      assert t.type_scale == 1.2
      # unchanged
      assert t.on_primary == :white
    end

    test "unspecified fields inherit defaults" do
      t = Theme.build(primary: :pink_500)
      assert t.surface == :gray_800
      assert t.space_scale == 1.0
    end

    test "module theme returns a Theme struct" do
      t = Mob.Theme.Obsidian.theme()
      assert %Theme{} = t
      assert t.primary == :violet_600
    end

    test "set/1 accepts a theme module" do
      on_exit(fn -> Application.delete_env(:mob, :theme) end)
      Theme.set(Mob.Theme.Obsidian)
      assert Theme.current().primary == :violet_600
    end

    test "set/1 accepts {module, overrides}" do
      on_exit(fn -> Application.delete_env(:mob, :theme) end)
      Theme.set({Mob.Theme.Obsidian, primary: :rose_500})
      t = Theme.current()
      assert t.primary == :rose_500
      # still Obsidian background
      assert t.background == 0xFF0D0D1A
    end
  end

  describe "spacing_map/1" do
    test "returns base values at scale 1.0" do
      m = Theme.spacing_map(Theme.default())
      assert m.space_xs == 4
      assert m.space_sm == 8
      assert m.space_md == 16
      assert m.space_lg == 24
      assert m.space_xl == 32
    end

    test "scales all values by space_scale" do
      m = Theme.spacing_map(Theme.build(space_scale: 2.0))
      assert m.space_xs == 8
      assert m.space_sm == 16
      assert m.space_md == 32
    end

    test "rounds fractional values" do
      m = Theme.spacing_map(Theme.build(space_scale: 1.1))
      assert m.space_sm == round(8 * 1.1)
      assert m.space_md == round(16 * 1.1)
    end
  end

  describe "radius_map/1" do
    test "returns theme radius values" do
      m = Theme.radius_map(Theme.default())
      assert m.radius_sm == 6
      assert m.radius_md == 10
      assert m.radius_lg == 16
      assert m.radius_pill == 100
    end

    test "reflects custom radius values" do
      m = Theme.radius_map(Theme.build(radius_md: 20, radius_pill: 50))
      assert m.radius_md == 20
      assert m.radius_pill == 50
      # unchanged
      assert m.radius_sm == 6
    end
  end

  describe "color_map/1" do
    test "maps semantic names to their values" do
      m = Theme.color_map(Theme.default())
      assert m.primary == :blue_500
      assert m.on_primary == :white
      assert m.surface == :gray_800
    end

    test "reflects overridden colors" do
      m = Theme.color_map(Theme.build(primary: :emerald_500))
      assert m.primary == :emerald_500
      # unchanged
      assert m.on_primary == :white
    end
  end

  describe "color_scheme/0" do
    test "returns :light on the host BEAM (NIF not loaded)" do
      # On the test host the mob_nif NIF is unavailable; the function should
      # rescue and return :light rather than crashing the caller.
      assert Theme.color_scheme() == :light
    end
  end

  describe "Mob.Theme.Light" do
    test "theme/0 returns a Theme struct with white background" do
      t = Mob.Theme.Light.theme()
      assert %Theme{} = t
      assert t.background == 0xFFFFFFFF
    end

    test "on_background is dark for high contrast" do
      t = Mob.Theme.Light.theme()
      # near-black text on white is high-contrast (WCAG AAA).
      <<_::8, r::8, g::8, b::8>> = <<t.on_background::32>>
      avg = div(r + g + b, 3)
      assert avg < 64, "expected near-black on_background, got rgb avg #{avg}"
    end
  end

  describe "Mob.Theme.Dark" do
    test "theme/0 returns a Theme struct with near-black background" do
      t = Mob.Theme.Dark.theme()
      assert %Theme{} = t
      <<_::8, r::8, g::8, b::8>> = <<t.background::32>>
      avg = div(r + g + b, 3)
      assert avg < 32, "expected near-black background, got rgb avg #{avg}"
    end

    test "background avoids pure black to reduce OLED smear" do
      t = Mob.Theme.Dark.theme()
      <<_::8, r::8, g::8, b::8>> = <<t.background::32>>
      avg = div(r + g + b, 3)
      assert avg > 0, "background should not be pure black"
    end

    test "on_background is light for high contrast" do
      t = Mob.Theme.Dark.theme()
      <<_::8, r::8, g::8, b::8>> = <<t.on_background::32>>
      avg = div(r + g + b, 3)
      assert avg > 200, "expected near-white on_background, got rgb avg #{avg}"
    end
  end

  describe "Mob.Theme.Adaptive" do
    test "theme/0 returns a Theme struct" do
      assert %Theme{} = Mob.Theme.Adaptive.theme()
    end

    test "on the test host (color_scheme/0 → :light) returns the Light theme" do
      # Without a NIF the underlying color_scheme/0 returns :light, so
      # Adaptive must resolve to the Light theme exactly.
      assert Mob.Theme.Adaptive.theme() == Mob.Theme.Light.theme()
    end
  end
end
