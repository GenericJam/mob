// MobFonts.swift — resolving a node's `font` prop to a face iOS can draw.
// `resolvedFont` (MobRootView.swift) and `resolvedUIFont` (MobInputEvents.swift)
// both go through `MobNode.resolveFontFace`. See MOB_FONTS.md.

import SwiftUI
import UIKit

/// A node's `font` resolved to something iOS can draw.
enum MobFontFace: Equatable {
    /// A face `UIFont(name:)` can load: a PostScript or family name.
    case named(String)
    /// A generic family name (`monospace`, `serif`, `sans-serif`, `rounded`),
    /// drawn in the system font's matching design.
    case system(Font.Design)

    /// The generic family names, as Android's `Typeface.create` accepts them.
    /// `rounded` has no Android family and falls back to the default there.
    static let genericDesigns: [String: Font.Design] = [
        "monospace": .monospaced,
        "serif": .serif,
        "sans-serif": .default,
        "rounded": .rounded
    ]
}

extension Font.Design {
    /// The UIKit equivalent, for the UIKit text field (`resolvedUIFont`).
    var uiKitDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .serif:      return .serif
        case .rounded:    return .rounded
        case .monospaced: return .monospaced
        default:          return .default
        }
    }
}

extension MobNode {
    /// Walks `[primary, ...fallback]` (fallback from the last `Mob.Theme.set/1`
    /// via `mob_font_fallback()`) and returns the first candidate iOS can draw:
    /// a generic family name (`MobFontFace.genericDesigns`) becomes the system
    /// font in that design, any other name must load with `UIFont(name:)`.
    /// `Font.custom` itself has no "did this resolve?" signal — it silently
    /// substitutes the system font — so `UIFont(name:)` is the resolvability
    /// probe. `nil` means "use the system font", same as the no-font-set
    /// behavior. Logs when the primary choice misses so a missing/misnamed
    /// font is diagnosable instead of just looking like the wrong font.
    static func resolveFontFace(primary: String?) -> MobFontFace? {
        let candidates = ([primary].compactMap { $0 } + mob_font_fallback()).filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        for (index, name) in candidates.enumerated() {
            let face: MobFontFace
            if let design = MobFontFace.genericDesigns[name] {
                face = .system(design)
            } else if UIFont(name: name, size: 12) != nil {
                face = .named(name)
            } else {
                continue
            }
            if index > 0 {
                NSLog("[mob/font] \"%@\" not found — fell back to \"%@\"", candidates[0], name)
            }
            return face
        }

        NSLog("[mob/font] none of %@ resolved — using system font", candidates)
        return nil
    }
}
