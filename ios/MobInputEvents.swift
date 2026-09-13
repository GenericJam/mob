// MobInputEvents.swift — continuous gesture/hover and IME composition bridges.

import Foundation
import SwiftUI
import UIKit

// High-frequency spatial input. Native NIF-side throttling still decides
// which dragging samples cross into BEAM; began/ended boundaries always do.
// Separate simultaneous gestures allow pinch and rotation to be recognised
// together and avoid replacing a ScrollView's own pan gesture.
struct MobContinuousInputModifier: ViewModifier {
    let node: MobNode

    // Retained by SwiftUI, but its plain properties do not publish changes.
    // Gesture callbacks run on the main thread, so this avoids multiple view
    // invalidations per raw sample while remaining stable across node rebuilds.
    @State private var state = GestureState()

    private final class GestureState {
        var pinchActive = false
        var lastScale: CGFloat = 1
        var lastPinchTime: TimeInterval = 0
        var lastPinchVelocity: CGFloat = 0

        var rotationActive = false
        var lastDegrees: CGFloat = 0
        var lastRotationTime: TimeInterval = 0
        var lastRotationVelocity: CGFloat = 0
    }

    private func sampleVelocity(
        current: CGFloat,
        previous: CGFloat,
        now: TimeInterval,
        previousTime: TimeInterval
    ) -> CGFloat {
        let elapsed = now - previousTime
        guard elapsed > 0 else { return 0 }
        return (current - previous) / CGFloat(elapsed)
    }

    func body(content: Content) -> some View {
        content
            .ifLet(node.onPinch != nil ? () : nil) { view, _ in
                view
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { scale in
                                let now = ProcessInfo.processInfo.systemUptime
                                let phase = state.pinchActive ? "dragging" : "began"
                                let velocity = state.pinchActive
                                    ? sampleVelocity(
                                        current: scale,
                                        previous: state.lastScale,
                                        now: now,
                                        previousTime: state.lastPinchTime
                                    )
                                    : 0

                                state.pinchActive = true
                                state.lastScale = scale
                                state.lastPinchTime = now
                                state.lastPinchVelocity = velocity
                                node.onPinch?(scale, velocity, phase)
                            }
                            .onEnded { scale in
                                node.onPinch?(scale, state.lastPinchVelocity, "ended")
                                state.pinchActive = false
                                state.lastScale = 1
                                state.lastPinchTime = 0
                                state.lastPinchVelocity = 0
                            }
                    )
            }
            .ifLet(node.onRotate != nil ? () : nil) { view, _ in
                view
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        RotationGesture()
                            .onChanged { angle in
                                let degrees = CGFloat(angle.degrees)
                                let now = ProcessInfo.processInfo.systemUptime
                                let phase = state.rotationActive ? "dragging" : "began"
                                let velocity = state.rotationActive
                                    ? sampleVelocity(
                                        current: degrees,
                                        previous: state.lastDegrees,
                                        now: now,
                                        previousTime: state.lastRotationTime
                                    )
                                    : 0

                                state.rotationActive = true
                                state.lastDegrees = degrees
                                state.lastRotationTime = now
                                state.lastRotationVelocity = velocity
                                node.onRotate?(degrees, velocity, phase)
                            }
                            .onEnded { angle in
                                node.onRotate?(
                                    CGFloat(angle.degrees),
                                    state.lastRotationVelocity,
                                    "ended"
                                )
                                state.rotationActive = false
                                state.lastDegrees = 0
                                state.lastRotationTime = 0
                                state.lastRotationVelocity = 0
                            }
                    )
            }
            .ifLet(node.onPointerMove != nil ? () : nil) { view, _ in
                view
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            node.onPointerMove?(location.x, location.y)
                        case .ended:
                            break
                        }
                    }
            }
    }
}

// SwiftUI's TextField does not expose UITextInput.markedTextRange. Opt into a
// UIKit-backed field only when on_compose is registered; ordinary fields keep
// their existing SwiftUI implementation and behavior.
struct MobComposingTextField: UIViewRepresentable {
    let node: MobNode
    let placeholder: String
    let keyboardType: UIKeyboardType
    let returnKeyType: UIReturnKeyType
    @Binding var text: String
    let isFocused: Bool
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.borderStyle = .roundedRect
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        configure(field)
        context.coordinator.synchronizeProgrammaticText(text)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        configure(field)

        // Never replace marked text underneath an active IME. MobTextField
        // already defers controlled-value re-seeds while focused; this guard
        // also protects against a parent update racing the native callback.
        if field.markedTextRange == nil && field.text != text {
            field.text = text
            context.coordinator.synchronizeProgrammaticText(text)
        }

        if isFocused && !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused && field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    private func configure(_ field: UITextField) {
        field.placeholder = placeholder
        field.keyboardType = keyboardType
        field.returnKeyType = returnKeyType
        field.isSecureTextEntry = node.isSecure
        field.autocorrectionType = .default
        field.autocapitalizationType = .sentences
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: MobComposingTextField
        private var composing = false
        private var lastMarkedText = ""
        private var textBeforeComposition = ""
        private var lastFullText: String

        init(parent: MobComposingTextField) {
            self.parent = parent
            lastFullText = parent.text
        }

        func synchronizeProgrammaticText(_ text: String) {
            guard !composing else { return }
            lastFullText = text
        }

        @objc func textDidChange(_ textField: UITextField) {
            observeComposition(in: textField)

            let current = textField.text ?? ""
            lastFullText = current
            if parent.text != current {
                parent.text = current
            }
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            // Some IMEs change markedTextRange before UIControl emits
            // editingChanged. Observing both hooks makes phase transitions
            // reliable; identical marked text is deduplicated below.
            observeComposition(in: textField)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.onFocusChange(true) }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            observeComposition(in: textField)
            if parent.isFocused { parent.onFocusChange(false) }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.node.onSubmit?()
            guard parent.node.returnKeyStr != "next" else { return false }
            textField.resignFirstResponder()
            parent.onFocusChange(false)
            return true
        }

        private func observeComposition(in textField: UITextField) {
            if let range = textField.markedTextRange {
                let markedText = textField.text(in: range) ?? ""

                if !composing {
                    composing = true
                    textBeforeComposition = lastFullText
                    lastMarkedText = markedText
                    parent.node.onCompose?(markedText, "began")
                } else if markedText != lastMarkedText {
                    lastMarkedText = markedText
                    parent.node.onCompose?(markedText, "updating")
                }

                return
            }

            guard composing else { return }

            let current = textField.text ?? ""
            let committedText = Self.insertedText(from: textBeforeComposition, to: current)
            lastFullText = current
            if committedText.isEmpty {
                parent.node.onCompose?("", "cancelled")
            } else {
                parent.node.onCompose?(committedText, "committed")
            }

            composing = false
            lastMarkedText = ""
            textBeforeComposition = ""
        }

        // Return only the graphemes introduced by the IME, rather than the
        // entire field value. CollectionDifference offsets are sorted because
        // replacement edits can report removals and insertions interleaved.
        private static func insertedText(from before: String, to after: String) -> String {
            let inserted = after.difference(from: before).compactMap { change -> (Int, Character)? in
                guard case let .insert(offset, character, _) = change else { return nil }
                return (offset, character)
            }

            return String(inserted.sorted { $0.0 < $1.0 }.map { $0.1 })
        }
    }
}
