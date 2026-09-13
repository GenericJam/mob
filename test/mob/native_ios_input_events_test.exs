# These source-contract tests guard iOS behavior that host-side Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeIOSInputEventsTest do
  use ExUnit.Case, async: true

  import Mob.Test.NativeSource

  @root_swift Path.expand("../../ios/MobRootView.swift", __DIR__) |> File.read!() |> code_only()
  @input_swift Path.expand("../../ios/MobInputEvents.swift", __DIR__)
               |> File.read!()
               |> code_only()
  @objc Path.expand("../../ios/mob_nif.m", __DIR__) |> File.read!() |> code_only(:objc)

  test "every rendered node receives opt-in pinch, rotation, and pointer movement" do
    modifier =
      region(
        @input_swift,
        "struct MobContinuousInputModifier: ViewModifier {",
        "struct MobComposingTextField: UIViewRepresentable {"
      )

    assert modifier =~ "MagnificationGesture()"
    assert modifier =~ "node.onPinch?(scale, velocity, phase)"
    assert modifier =~ "node.onPinch?(scale, state.lastPinchVelocity, \"ended\")"
    assert modifier =~ "RotationGesture()"
    assert modifier =~ "node.onRotate?(degrees, velocity, phase)"

    assert modifier =~
             ~r/node\.onRotate\?\(\s*CGFloat\(angle\.degrees\),\s*state\.lastRotationVelocity,\s*"ended"/

    assert modifier =~ ".onContinuousHover(coordinateSpace: .local)"
    assert modifier =~ "node.onPointerMove?(location.x, location.y)"
    assert modifier =~ "@State private var state = GestureState()"
    refute modifier =~ "@State private var pinchActive"

    node_view =
      region(@root_swift, "struct MobNodeView: View {", "private struct MobLayoutWeight")

    assert node_view =~ ".modifier(MobContinuousInputModifier(node: node))"
  end

  test "text fields with on_compose observe UIKit marked text and emit every phase" do
    composing_field =
      region(
        @input_swift,
        "struct MobComposingTextField: UIViewRepresentable {",
        "final class Coordinator: NSObject, UITextFieldDelegate {"
      ) <>
        region(
          @input_swift,
          "final class Coordinator: NSObject, UITextFieldDelegate {",
          "private static func insertedText"
        )

    assert composing_field =~ "textField.markedTextRange"
    assert composing_field =~ "node.onCompose?(markedText, \"began\")"
    assert composing_field =~ "node.onCompose?(markedText, \"updating\")"
    assert composing_field =~ "node.onCompose?(committedText, \"committed\")"
    assert composing_field =~ "node.onCompose?(\"\", \"cancelled\")"
    assert composing_field =~ "lastFullText = current"

    field = region(@root_swift, "private struct MobTextField: View {", "private struct MobToggle")
    assert field =~ "if node.onCompose != nil"
    assert field =~ "MobComposingTextField("
  end

  test "composition text crosses the NIF as a UTF-8 binary" do
    sender = region(@objc, "static void mob_send_compose", "static void mob_send_long_press")

    assert sender =~ "enif_make_new_binary"
    assert sender =~ "memcpy(text_data, utf8, text_len)"
    refute sender =~ "ERL_NIF_LATIN1"
  end
end
