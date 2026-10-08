import SwiftUI

/// Small, explicit controls for a passive meeting-audio session. This surface
/// never exposes a microphone toggle: it only observes the selected app's
/// digital output, which continues to play normally through the user's chosen
/// headphones or speakers.
struct LiveAssistControls: View {
    @ObservedObject var session: LiveAssistSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sourceMenu

                Spacer(minLength: 0)

                listenButton
            }

            HStack(spacing: 6) {
                Image(systemName: session.isListening ? "waveform" : "speaker.wave.2")
                    .foregroundStyle(session.isListening ? Color.accentColor : .secondary)
                Text(statusText)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if session.isListening, !session.transcription.transcript.text.isEmpty {
                Text("Hearing: \(session.transcription.transcript.text)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if let error = session.lastErrorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(session.isListening ? 0.10 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var sourceMenu: some View {
        Menu {
            if session.capture.availableApplications.isEmpty {
                Text("No apps loaded")
            } else {
                ForEach(session.capture.availableApplications) { application in
                    Button {
                        session.selectAudioSource(id: application.id)
                    } label: {
                        if application.id == session.capture.selectedApplication?.id {
                            Label(application.name, systemImage: "checkmark")
                        } else {
                            Text(application.name)
                        }
                    }
                }
            }

            Divider()

            Button("Refresh apps") {
                Task {
                    if session.capture.permission != .granted {
                        _ = session.requestCapturePermission()
                    }
                    await session.refreshAudioSources()
                }
            }
        } label: {
            Label(
                session.capture.selectedApplication?.name ?? "Choose meeting audio",
                systemImage: "speaker.wave.2"
            )
            .lineLimit(1)
        }
        .controlSize(.small)
        .help("Choose the meeting app whose system output should be transcribed")
    }

    @ViewBuilder
    private var listenButton: some View {
        if session.isListening {
            Button {
                Task { await session.stopListening() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Stop listening to meeting audio")
        } else {
            Button {
                Task { await session.startListening() }
            } label: {
                Label("Listen", systemImage: "waveform")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(session.isStarting || session.capture.selectedApplication == nil)
            .help("Listen to the selected meeting app's system audio")
        }
    }

    private var statusText: String {
        if let application = session.capture.selectedApplication {
            if session.isListening {
                return "Listening to \(application.name)'s system output. Your headphones stay unchanged."
            }
            return "Ready for \(application.name). Audio is not being captured yet."
        }
        if session.capture.permission == .required {
            return "Choose Refresh apps, then allow Screen & System Audio Recording."
        }
        return "Choose the app playing the interviewer’s voice."
    }
}

/// A finished answer path, not a second checklist. The candidate reads it
/// straight down; every row contains the next conversational thought.
struct LiveCueRailView: View {
    let plan: LiveCuePlan
    let heardQuestion: String

    /// The rail is deliberately advanced by the candidate, never by a timer
    /// or subsequent transcription. During an answer, the current thought is
    /// visually unambiguous and the path behind it stays available as a quiet
    /// reference.
    @State private var currentStep = 0

    private var railKey: String {
        let matchID = plan.match?.questionID.uuidString ?? "unlisted"
        return "\(matchID)|\(heardQuestion)"
    }

    private var hasSteps: Bool { !plan.steps.isEmpty }
    private var isAtLastStep: Bool { currentStep >= plan.steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    railHeader

                    if plan.resolution == .matched {
                        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                            cueRow(
                                number: index + 1,
                                label: step.label,
                                cue: step.cue,
                                state: cueState(for: index)
                            )
                        }
                    } else {
                        unknownRail
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            // Keep the one deliberate interaction in the same place even
            // when a long cue needs scrolling. A candidate should never have
            // to hunt below the answer to move to the next thought.
            if plan.resolution == .matched, plan.steps.count > 1 {
                Divider()
                cueAdvanceControl
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live answer path")
        .onAppear { resetStep() }
        .onChange(of: railKey) { _, _ in resetStep() }
    }

    private var railHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(plan.resolution == .matched ? "ANSWER PATH" : "UNLISTED QUESTION")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            if hasSteps {
                Text(isAtLastStep ? "Final thought" : "Thought \(currentStep + 1) of \(plan.steps.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            // The heard wording is useful only as a quick confidence check.
            // It must never crowd the first cue in a compact live window.
            if plan.resolution != .matched, !heardQuestion.isEmpty {
                Text(heardQuestion)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
    }

    private enum CueState {
        case completed
        case current
        case upcoming
    }

    private func cueState(for index: Int) -> CueState {
        if index < currentStep { return .completed }
        return index == currentStep ? .current : .upcoming
    }

    private func cueRow(number: Int, label: String, cue: String, state: CueState = .current) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state == .completed ? "checkmark" : "\(number).circle.fill")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(state == .current ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(state == .current ? Color.accentColor : .secondary)
                Text(cue)
                    .font(.system(size: state == .current ? 16 : 14, weight: state == .current ? .semibold : .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(state == .current ? Color.accentColor.opacity(0.10) : .clear)
        }
        .opacity(state == .completed ? 0.42 : (state == .upcoming ? 0.68 : 1))
        .accessibilityLabel("\(state == .current ? "Current: " : "")\(label). \(cue)")
    }

    private var cueAdvanceControl: some View {
        HStack(spacing: 8) {
            Button {
                currentStep = max(0, currentStep - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.bordered)
            .disabled(currentStep == 0)
            .accessibilityLabel("Previous thought")
            .help("Return to the previous thought")

            Button {
                currentStep = min(plan.steps.count - 1, currentStep + 1)
            } label: {
                HStack(spacing: 5) {
                    Text(isAtLastStep ? "Final thought" : "Next thought")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .background(Color.accentColor, in: Capsule())
            .disabled(isAtLastStep)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help(isAtLastStep ? "This is the final thought" : "Move to the next thought")
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 2)
    }

    private func resetStep() {
        currentStep = 0
    }

    private var unknownRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            cueRow(
                number: 1,
                label: "OPEN",
                cue: "Take a beat, then state the part you can answer directly."
            )
            cueRow(
                number: 2,
                label: "CLARIFY IF NEEDED",
                cue: "Ask which dimension matters most instead of assuming the wrong one."
            )
            cueRow(
                number: 3,
                label: "STAY TRUTHFUL",
                cue: "Use the closest real example or explain your approach without inventing details."
            )
        }
    }
}
