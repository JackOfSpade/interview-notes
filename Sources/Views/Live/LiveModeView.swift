import SwiftUI

private enum LiveModeScreen {
    case questionSelection
    case answer
}

/// The interview-facing surface: choose a prepared question, then read its
/// answer without exposing editing controls.
public struct LiveModeView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @ObservedObject private var windowManager = WindowManager.shared

    public var questions: [Question]
    public var onExit: (Question?) -> Void

    @State private var screen: LiveModeScreen = .questionSelection
    @State private var currentIndex: Int
    @State private var isPlaying = false
    @State private var pageCommand = 0
    /// A non-zero value means an arrow button is being held. The stage owns
    /// pausing and restoring playback while this value is active.
    @State private var manualScrollDirection = 0
    @State private var restartToken = 0
    @State private var shouldRestoreQuestionPosition = false

    private var reduceMotionIsActive: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var currentQuestion: Question? {
        guard questions.indices.contains(currentIndex) else { return nil }
        return questions[currentIndex]
    }

    private var answerText: String {
        guard let currentQuestion else { return "" }
        return liveAnswerText(for: currentQuestion)
    }

    private var answerWordCount: Int {
        max(1, answerText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count)
    }

    public init(
        questions: [Question],
        initialQuestionID: UUID?,
        onExit: @escaping (Question?) -> Void
    ) {
        self.questions = questions
        self.onExit = onExit
        self._currentIndex = State(
            initialValue: questions.firstIndex(where: { $0.id == initialQuestionID }) ?? 0
        )
    }

    init(
        questions: [Question],
        initialQuestionID: UUID?,
        startsOnAnswer: Bool,
        onExit: @escaping (Question?) -> Void
    ) {
        self.questions = questions
        self.onExit = onExit
        self._screen = State(initialValue: startsOnAnswer ? .answer : .questionSelection)
        self._currentIndex = State(
            initialValue: questions.firstIndex(where: { $0.id == initialQuestionID }) ?? 0
        )
    }

    public var body: some View {
        Group {
            if questions.isEmpty {
                emptySession
            } else {
                switch screen {
                case .questionSelection:
                    questionSelection
                case .answer:
                    if let question = currentQuestion {
                        answerScreen(for: question)
                    } else {
                        emptySession
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: currentIndex) { _, _ in
            resetReading()
        }
    }

    private var questionSelection: some View {
        VStack(spacing: 0) {
            questionSelectionHeader
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                            questionButton(for: question, at: index)
                                .id(question.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    guard shouldRestoreQuestionPosition,
                          let question = currentQuestion else { return }
                    shouldRestoreQuestionPosition = false
                    proxy.scrollTo(question.id, anchor: .center)
                }
            }
        }
    }

    private var questionSelectionHeader: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            snapButton

            Button("Exit Live") {
                exitLive()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Return to interview setup")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func questionButton(for question: Question, at index: Int) -> some View {
        let isAnswerReady = !liveAnswerText(for: question).isEmpty
        let button = Button {
            openQuestion(at: index)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(index == currentIndex ? Color.white : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(index == currentIndex ? Color.accentColor : Color.accentColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(question.prompt.isEmpty ? "Untitled question" : question.prompt)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        }
        .buttonStyle(LiveQuestionButtonStyle(isCurrent: index == currentIndex))
        .accessibilityLabel(
            "Question \(index + 1) of \(questions.count): "
                + (question.prompt.isEmpty ? "Untitled question" : question.prompt)
        )
        .accessibilityHint(
            isAnswerReady
                ? "Show the prepared answer"
                : "Show this question; no answer is prepared"
        )

        if index < 9 {
            button.keyboardShortcut(
                KeyEquivalent(Character(String(index + 1))),
                modifiers: []
            )
        } else {
            button
        }
    }

    private func answerScreen(for question: Question) -> some View {
        VStack(spacing: 0) {
            if answerText.isEmpty {
                Spacer(minLength: 0)
            } else {
                TeleprompterStageView(
                    text: answerText,
                    wordCount: answerWordCount,
                    isPlaying: $isPlaying,
                    wpm: prefs.teleprompterWPM,
                    onReachedEnd: {},
                    pageCommand: $pageCommand,
                    restartToken: restartToken,
                    manualScrollDirection: $manualScrollDirection
                )
                .accessibilityLabel("Prepared answer")
            }

            Divider()
            answerFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var questionsButton: some View {
        Button {
            showQuestionSelection()
        } label: {
            Label("Questions", systemImage: "chevron.left")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Back to question selection (Esc)")
    }

    private var snapButton: some View {
        Button {
            windowManager.toggleSnap()
        } label: {
            Image(systemName: windowManager.isSnapped ? "camera.viewfinder" : "camera.metering.spot")
        }
        .buttonStyle(.bordered)
        .frame(width: 30, height: 30)
        .accessibilityLabel(windowManager.isSnapped ? "Unsnap from camera" : "Snap below camera")
        .help(windowManager.isSnapped ? "Unsnap from camera" : "Snap below camera")
    }

    private var answerFooter: some View {
        HStack(spacing: 4) {
            if !answerText.isEmpty {
                Button {
                    isPlaying.toggle()
                } label: {
                    Label(isPlaying ? "Pause" : "Start", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 50)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(reduceMotionIsActive)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(isPlaying ? "Pause teleprompter" : "Start teleprompter")
                .help(
                    reduceMotionIsActive
                        ? "Automatic scrolling is unavailable with Reduce Motion"
                        : "Start or pause the teleprompter (Space)"
                )

                LiveManualScrollButton(
                    direction: -1,
                    manualScrollDirection: $manualScrollDirection,
                    pageCommand: $pageCommand,
                    isDisabled: false,
                    accessibilityLabel: "Move answer up",
                    help: "Hold to move up; release to resume scrolling"
                )

                LiveManualScrollButton(
                    direction: 1,
                    manualScrollDirection: $manualScrollDirection,
                    pageCommand: $pageCommand,
                    isDisabled: false,
                    accessibilityLabel: "Move answer down",
                    help: "Hold to move down; release to resume scrolling"
                )
            }

            Spacer(minLength: 2)
            questionsButton
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptySession: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No questions in this live set")
                .font(.system(size: 15, weight: .medium))
            Button("Return to Setup") { onExit(nil) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func liveAnswerText(for question: Question) -> String {
        let fullAnswer = question.fullAnswerDisplayText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullAnswer.isEmpty { return fullAnswer }

        return question.talkingPoints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "• \($0)" }
            .joined(separator: "\n\n")
    }

    private func openQuestion(at index: Int) {
        guard questions.indices.contains(index) else { return }
        manualScrollDirection = 0
        isPlaying = false
        currentIndex = index
        restartToken += 1
        screen = .answer
    }

    private func showQuestionSelection() {
        manualScrollDirection = 0
        isPlaying = false
        shouldRestoreQuestionPosition = true
        screen = .questionSelection
    }

    private func exitLive() {
        manualScrollDirection = 0
        isPlaying = false
        onExit(currentQuestion)
    }

    private func resetReading() {
        isPlaying = false
        restartToken += 1
    }
}

/// A mouse/trackpad press invokes continuous manual navigation. Keyboard and
/// VoiceOver activation retain a single-page action through `Button` itself.
private struct LiveManualScrollButton: View {
    let direction: Int
    @Binding var manualScrollDirection: Int
    @Binding var pageCommand: Int
    let isDisabled: Bool
    let accessibilityLabel: String
    let help: String

    @State private var isPointerHolding = false

    var body: some View {
        Button {
            // The button action follows a pointer release. That release was
            // already handled by the press gesture, but keyboard/accessibility
            // activation still needs a useful one-step movement.
            guard !isPointerHolding else { return }
            pageCommand += direction
        } label: {
            Image(systemName: direction < 0 ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.bordered)
        .frame(width: 34, height: 30)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .help(help)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isDisabled else { return }
                    isPointerHolding = true
                    manualScrollDirection = direction
                }
                .onEnded { _ in
                    guard !isDisabled else { return }
                    manualScrollDirection = 0
                    // Leave this true until Button's release action has run.
                    DispatchQueue.main.async {
                        isPointerHolding = false
                    }
                }
        )
    }
}

private struct LiveQuestionButtonStyle: ButtonStyle {
    var isCurrent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isCurrent
                            ? Color.accentColor.opacity(configuration.isPressed ? 0.2 : 0.12)
                            : Color(nsColor: .controlBackgroundColor).opacity(configuration.isPressed ? 0.7 : 1)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        isCurrent ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor),
                        lineWidth: isCurrent ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
