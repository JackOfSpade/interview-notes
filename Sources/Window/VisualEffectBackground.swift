import AppKit
import SwiftUI

public struct VisualEffectView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .underWindowBackground,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

public struct WindowBackgroundView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private var isReduceTransparencyActive: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var isIncreaseContrastActive: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    public var effectiveTransparency: Double {
        if isReduceTransparencyActive || isIncreaseContrastActive {
            return 0.0
        }
        return prefs.windowTransparency
    }

    public var body: some View {
        ZStack {
            // Native material behind window
            VisualEffectView(
                material: .underWindowBackground,
                blendingMode: .behindWindow
            )

            // Dynamic tint overlay that controls opacity (1.0 = opaque, 0.6 = 40% transparent)
            Color(nsColor: .windowBackgroundColor)
                .opacity(1.0 - effectiveTransparency)

            if isIncreaseContrastActive {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(0.15)
            }
        }
        .ignoresSafeArea()
    }
}
