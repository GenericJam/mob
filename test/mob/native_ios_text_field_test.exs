# These source-contract tests guard iOS text-field behavior that host-side
# Elixir cannot execute (MOB-237). Simulator evidence is in the PR.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeIOSTextFieldTest do
  use ExUnit.Case, async: true

  alias Mob.Test.NativeSource

  @ios Path.expand("../../ios", __DIR__)
  @nif Path.join(@ios, "mob_nif.m") |> File.read!()
  @root_swift Path.join(@ios, "MobRootView.swift") |> File.read!() |> NativeSource.code_only()
  @input_swift Path.join(@ios, "MobInputEvents.swift") |> File.read!() |> NativeSource.code_only()

  defp text_field,
    do:
      NativeSource.region(
        @root_swift,
        "private struct MobTextField: View {",
        "private struct MobToggle"
      )

  defp uikit_field,
    do:
      NativeSource.region(
        @input_swift,
        "struct MobComposingTextField: UIViewRepresentable {",
        "private static func insertedText"
      )

  defp node_builder do
    @nif
    |> NativeSource.region(
      "static MobNode *mob_node_from_dict(NSDictionary *dict) {",
      "static ERL_NIF_TERM nif_exit_app"
    )
    |> NativeSource.code_only(:objc)
  end

  test "the native boundary parses the text-field props Android honours" do
    slots =
      @nif
      |> NativeSource.region(
        "static NSDictionary<NSString *, NSNumber *> *mob_prop_slots(void) {",
        "static MobNode *mob_node_from_dict(NSDictionary *dict) {"
      )
      |> NativeSource.code_only(:objc)

    for prop <- ~w(caret caret_color enabled lines max_length) do
      assert slots =~ ~s|[MOB_PROP_#{prop}] = @"#{prop}"|
    end

    builder = node_builder()
    assert builder =~ "node.caretColor = color_from_argb("
    assert builder =~ ~s|node.caretAtEnd = [caret isEqualToString:@"end"]|
    assert builder =~ "node.maxLength = [maxLength integerValue]"
    assert builder =~ "node.textFieldLines = [lines integerValue]"
    assert builder =~ ~r/!\[enabled boolValue\]\) \{\s*node\.disabled = YES;/
  end

  test "`enabled: false` disables text fields only" do
    [before, field_block] =
      String.split(node_builder(), "id enabled = pv[MOB_PROP_enabled]", parts: 2)

    assert before =~ ~r/if \(node\.nodeType == MobNodeTypeTextField\) \{\s*\z/
    assert field_block =~ ~r/\A;\s*if \(\[enabled isKindOfClass/
  end

  test "the SwiftUI field draws the node's chrome instead of the system's" do
    field = text_field()
    refute field =~ ".roundedBorder"
    assert field =~ ".textFieldStyle(.plain)"
    assert field =~ ".font(node.resolvedFont)"
    assert field =~ ".kerning(node.letterSpacing)"
    assert field =~ ".foregroundStyle(textColor)"
    assert field =~ ".tint(caretColor)"
    assert field =~ ".multilineTextAlignment(node.textAlignEnum)"
    assert field =~ ".disabled(node.disabled)"
    assert field =~ "(node.caretColor ?? node.textColor)"

    assert field =~
             ~r/RoundedRectangle\(cornerRadius: node\.cornerRadius\)\s*\.fill\(node\.backgroundColor/

    assert field =~ ~r/\.stroke\(node\.borderColor.*lineWidth: node\.borderWidth\)/s
    assert field =~ "prompt.foregroundColor(Color(color))"
    assert field =~ ".lineLimit(node.textFieldLines, reservesSpace: true)"
  end

  test "SwiftUI max_length rejects only a lengthening user edit, silently" do
    field = text_field()
    # Gated on focus, not on `newValue != initialText`: a user edit that
    # happens to equal the BEAM's over-limit value must still be rejected.
    assert field =~ "if node.maxLength > 0, focused,"
    assert field =~ "newValue.utf16.count > node.maxLength"
    assert field =~ "newValue.utf16.count > oldValue.utf16.count"

    assert field =~
             ~r/newValue\.utf16\.count > oldValue\.utf16\.count \{\s*text = oldValue\s*return/
  end

  test "caret: end routes to the UIKit field, which pins the caret" do
    # Single-line max_length too: a SwiftUI rollback can leave the rejected
    # character on screen (seen on the simulator: max 5 accepted "123458").
    assert text_field() =~
             "if node.onCompose != nil || node.caretAtEnd || (node.maxLength > 0 && node.textFieldLines <= 1) {"

    uikit = uikit_field()
    assert uikit =~ "guard parent.node.caretAtEnd, textField.markedTextRange == nil"
    assert uikit =~ "textField.selectedTextRange = textField.textRange(from: end, to: end)"
    # Select-all survives, so select-all + delete and clear_text still clear.
    assert uikit =~ "if atEnd || wholeText { return }"
    assert uikit =~ ~r/func textFieldDidChangeSelection.*pinCaret\(in: textField\)/s
    assert uikit =~ ~r/func textFieldDidBeginEditing.*pinCaret\(in: textField\)/s
  end

  test "the UIKit field takes the same style props and max_length" do
    uikit = uikit_field()
    assert uikit =~ "field.borderStyle = .none"
    refute uikit =~ ".roundedRect"
    assert uikit =~ "let font = node.resolvedUIFont"
    assert uikit =~ "if field.font != font { field.font = font }"
    # Never restyle under an IME composition.
    assert uikit =~
             ~r/guard field\.markedTextRange == nil else \{ return \}\s*let font = node\.resolvedUIFont/

    assert uikit =~ "color.withAlphaComponent(color.cgColor.alpha * 0.38)"
    assert uikit =~ "field.defaultTextAttributes[.kern] = node.letterSpacing"

    assert uikit =~
             "field.textAlignment = node.uiTextAlignment(field.effectiveUserInterfaceLayoutDirection)"

    assert uikit =~ "field.tintColor = node.caretColor ?? node.textColor"
    assert uikit =~ "field.isEnabled = !node.disabled"
    assert uikit =~ "[.foregroundColor: placeholderColor, .font: font, .kern: node.letterSpacing]"
    assert uikit =~ "return newLength <= limit || newLength <= current.length"
    # A number pad has no return key; without the accessory Done a pinned
    # OTP or capped numeric field could never be dismissed.
    assert uikit =~ "field.inputAccessoryView = toolbar"
    assert uikit =~ ~r/@objc func done\(\) \{\s*field\?\.resignFirstResponder\(\)/
  end

  test "the UIKit field keeps the keyboard across keystrokes" do
    # A @FocusState bound to no `.focused` view is reset on the next update,
    # which resigned the UIKit field after every keystroke.
    field = text_field()
    assert field =~ "@State private var uikitFocused = false"

    assert field =~
             ~r/isFocused: uikitFocused,\s*onFocusChange: \{ focused in uikitFocused = focused \}/

    assert field =~ "private var focused: Bool { isFocused || uikitFocused }"
    assert field =~ ".onChange(of: focused) {"
    assert field =~ "if !focused && text != newValue {"
  end

  test "UIKit text matches SwiftUI: custom font weight by family, right is trailing" do
    helpers =
      NativeSource.region(@input_swift, "extension MobNode {", "struct MobComposingTextField")

    # A descriptor keeping the face's .name ignores the weight trait.
    assert helpers =~ ".family: custom.familyName"
    refute helpers =~ "custom.fontDescriptor.addingAttributes"
    # Without font_weight a named face (font: "Inter-Bold") is used as-is.
    assert helpers =~ ~r/if fontWeight == "regular" \{\s*base = custom/
    # The SwiftUI path too: `.weight(.regular)` turned AvenirNext-Bold regular.
    assert @root_swift =~ ~s|if fontWeight != "regular" { font = font.weight(weight) }|
    assert helpers =~ ~s|case "right":  return direction == .rightToLeft ? .left : .right|
  end
end
