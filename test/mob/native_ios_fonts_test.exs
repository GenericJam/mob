# These source-contract tests guard iOS font resolution that host-side Elixir
# cannot execute (MOB-566). Simulator evidence is in the PR.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeIOSFontsTest do
  use ExUnit.Case, async: true

  alias Mob.Test.NativeSource

  @ios Path.expand("../../ios", __DIR__)
  @fonts_swift Path.join(@ios, "MobFonts.swift") |> File.read!() |> NativeSource.code_only()
  @root_swift Path.join(@ios, "MobRootView.swift") |> File.read!() |> NativeSource.code_only()
  @input_swift Path.join(@ios, "MobInputEvents.swift") |> File.read!() |> NativeSource.code_only()

  defp resolve_font_face,
    do:
      NativeSource.region(
        @fonts_swift,
        "static func resolveFontFace(",
        "NSLog(\"[mob/font] none of"
      )

  test "the generic family names map to the system font designs" do
    table =
      NativeSource.region(
        @fonts_swift,
        "static let genericDesigns: [String: Font.Design] = [",
        "]"
      )

    pairs =
      ~r/"([a-z-]+)":\s*\.(\w+)/
      |> Regex.scan(table, capture: :all_but_first)
      |> Map.new(fn [name, design] -> {name, design} end)

    assert pairs == %{
             "monospace" => "monospaced",
             "serif" => "serif",
             "sans-serif" => "default",
             "rounded" => "rounded"
           }
  end

  test "a generic name resolves before the UIFont(name:) probe, which never loads one" do
    body = resolve_font_face()

    assert NativeSource.index_of(body, "MobFontFace.genericDesigns[name]") <
             NativeSource.index_of(body, "UIFont(name: name, size: 12) != nil")

    assert body =~ "face = .system(design)"
    assert body =~ "face = .named(name)"
  end

  test "SwiftUI Text draws a generic face as the system font in that design" do
    font =
      NativeSource.region(
        @root_swift,
        "var resolvedFont: Font {",
        "var textAlignEnum: TextAlignment {"
      )

    assert font =~ "MobNode.resolveFontFace(primary: fontFamily)"

    assert font =~
             ~r/case \.system\(let design\)\?:\s*font = \.system\(size: size, design: design\)/

    assert font =~ ~r/case \.named\(let name\)\?:\s*font = Font\.custom\(name, size: size\)/
    # Weight and italic still apply on top of whichever face resolved.
    assert font =~ "font = font.weight(weight)"
    assert font =~ "font = font.italic()"
  end

  test "the UIKit text field draws a generic face in the same design" do
    font =
      NativeSource.region(@input_swift, "var resolvedUIFont: UIFont {", "func uiTextAlignment(")

    assert font =~ "MobNode.resolveFontFace(primary: fontFamily)"
    assert font =~ "if case .system(let design)? = face"
    assert font =~ "UIFont.systemFont(ofSize: size, weight: weight)"
    assert font =~ ".fontDescriptor.withDesign(design.uiKitDesign)"
    assert font =~ ".traitItalic"

    design =
      NativeSource.region(
        @fonts_swift,
        "var uiKitDesign: UIFontDescriptor.SystemDesign {",
        "}\n}"
      )

    assert design =~ ~r/case \.serif:\s*return \.serif/
    assert design =~ ~r/case \.rounded:\s*return \.rounded/
    assert design =~ ~r/case \.monospaced:\s*return \.monospaced/
  end
end
