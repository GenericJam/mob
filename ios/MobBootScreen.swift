// MobBootScreen.swift — what MobRootView shows until the first screen renders.

import SwiftUI

/// The boot screen: the app's own icon with three pulsing dots under it while
/// the BEAM starts, the error once boot fails. It shows the app the user
/// tapped, nothing of Mob's, on the system background (no theme exists yet).
/// It takes over from the launch screen, which mob_new apps give the same
/// icon (UILaunchScreen's UIImageName, MobLaunchIcon from mob_dev), so only
/// the dots arrive. The startup phase stays readable as the accessibility
/// label.
struct MobBootScreen: View {
    @ObservedObject var model: MobViewModel

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()
            if let error = model.startupError {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(Color.orange)
                    Text("Startup Error")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.primary)
                    Text(error)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(UIColor.systemRed))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
            } else {
                // Centred on the whole screen, as UILaunchScreen centres its
                // image, so the icon doesn't move at the handover; the dots
                // sit 28 pt under it.
                ZStack {
                    MobBootIcon(size: 96)
                    MobLoadingDots().offset(y: 48 + 28 + 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.startupPhase)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The boot screen's centrepiece: the app's own icon. Prefers the launch
/// screen's `MobLaunchIcon` (mob_dev's MobDev.LaunchIcon: the app icon at
/// 96 pt, already rounded), so the handover from the launch screen is the
/// same pixels. Without it, the app icon itself: mob_dev compiles AppIcon
/// with actool and merges its partial Info.plist, which names the icon's
/// files under `CFBundleIcons` (the last is the largest). Draws nothing for
/// an app with neither, leaving the dots alone.
private struct MobBootIcon: View {
    let size: CGFloat

    private static let launchIcon = UIImage(named: "MobLaunchIcon")

    private static let appIcon: UIImage? = {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        return files?.last.flatMap { UIImage(named: $0) } ?? UIImage(named: "AppIcon")
    }()

    var body: some View {
        if let image = Self.launchIcon {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else if let image = Self.appIcon {
            // The home screen's continuous-corner mask, as the user saw it.
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        }
    }
}

/// Three dots brightening in turn, left to right, once every 1.2 s; the same
/// wave as the mob_new Android template's `LoadingDots`.
private struct MobLoadingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let wave: Double = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.2) / 1.2
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color(UIColor.systemGray))
                        .frame(width: 8, height: 8)
                        .opacity(Self.opacity(dot: i, wave: wave))
                }
            }
        }
    }

    /// Dot `dot`'s opacity at `wave` (0..<1 through the 1.2 s cycle): a
    /// cosine between 0.25 and 1 that peaks a third of a cycle later for each
    /// dot. Typed and on its own so the type checker doesn't time out on it.
    private static func opacity(dot: Int, wave: Double) -> Double {
        let phase: Double = 2 * Double.pi * (wave - Double(dot) / 3)
        let pulse: Double = 0.5 + 0.5 * cos(phase)
        return 0.25 + 0.75 * pulse
    }
}
