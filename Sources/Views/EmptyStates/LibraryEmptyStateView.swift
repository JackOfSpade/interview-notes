import SwiftUI
import SwiftData

public struct LibraryEmptyStateView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var prefs = AppPreferences.shared
    @Binding var showNewInterviewSheet: Bool

    public init(showNewInterviewSheet: Binding<Bool>) {
        self._showNewInterviewSheet = showNewInterviewSheet
    }

    public var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "message.badge.waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Prepare your first live panel")
                    .font(.system(size: 19, weight: .semibold))

                Text("Keep each interview question, its cues, and the exact words you want available during the conversation.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 12) {
                Button {
                    showNewInterviewSheet = true
                } label: {
                    Label("Create interview", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    exploreSample()
                } label: {
                    Text("Explore a sample")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exploreSample() {
        SampleData.insertSampleData(into: modelContext)
        prefs.hasCompletedOnboarding = true
        DataController.shared.flushSave()
    }
}

public struct QuestionEmptyStateView: View {
    public var onAddQuestion: () -> Void
    public var onSelectInterview: (() -> Void)?
    public var onCreateInterview: (() -> Void)?

    public init(
        onAddQuestion: @escaping () -> Void,
        onSelectInterview: (() -> Void)? = nil,
        onCreateInterview: (() -> Void)? = nil
    ) {
        self.onAddQuestion = onAddQuestion
        self.onSelectInterview = onSelectInterview
        self.onCreateInterview = onCreateInterview
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(emptyStateTitle)
                    .font(.system(size: 16, weight: .medium))

                Text(emptyStateDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if let onSelectInterview {
                Button(action: onSelectInterview) {
                    Label("Open first interview", systemImage: "briefcase")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else if let onCreateInterview {
                Button(action: onCreateInterview) {
                    Label("Create an interview", systemImage: "briefcase.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                Button {
                    onAddQuestion()
                } label: {
                    Label("Add your first question", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        if onSelectInterview != nil {
            return "No questions in the library"
        }
        return onCreateInterview == nil ? "No questions in this interview" : "No interviews yet"
    }

    private var emptyStateDescription: String {
        if onSelectInterview != nil {
            return "Choose an interview above, or open your first set to add questions."
        }
        if onCreateInterview != nil {
            return "Create an interview set before adding questions, concise cues, and answer scripts."
        }
        return "Add a likely question, concise cues, and an answer script for the live panel."
    }
}
