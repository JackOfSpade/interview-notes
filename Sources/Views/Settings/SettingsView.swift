import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject private var prefs = AppPreferences.shared

    private var isReduceTransparencyActive: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    public init() {}

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Window transparency")
                            .font(.system(size: 13, weight: .medium))

                        Spacer()

                        Text("\(Int(prefs.windowTransparency * 100))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Text("Opaque")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Slider(
                            value: $prefs.windowTransparency,
                            in: 0.0...0.4,
                            step: 0.05
                        )
                        .disabled(isReduceTransparencyActive)

                        Text("More transparent")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if isReduceTransparencyActive {
                        HStack(spacing: 5) {
                            Image(systemName: "accessibility")
                                .font(.system(size: 11))
                            Text("Controlled by Reduce Transparency in macOS Settings.")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Affects the Setup workspace only. Live stays opaque so your answer remains easy to read.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Setup appearance")
                    .font(.system(size: 12, weight: .semibold))
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Teleprompter speed")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(prefs.teleprompterWPM) WPM")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(prefs.teleprompterWPM) },
                            set: { prefs.teleprompterWPM = Int($0) }
                        ),
                        in: 70...200,
                        step: 5
                    )

                    HStack {
                        Text("70 WPM")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("200 WPM")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Live teleprompter")
                .font(.system(size: 12, weight: .semibold))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 310)
        .padding(16)
    }
}
