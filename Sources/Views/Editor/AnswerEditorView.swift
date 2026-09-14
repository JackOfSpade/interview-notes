import SwiftUI
import SwiftData

enum InheritedQuestionPresentation {
    static func sourceTitle(
        question: Question,
        inheritedFrom: Interview?
    ) -> String? {
        if let inheritedFrom {
            return inheritedFrom.title
        }

        // An untouched inherited row is still owned by its source, so the
        // owner is a safe fallback. An override is owned by the current child;
        // calling that child the source would be actively misleading when a
        // caller cannot resolve its lineage.
        guard question.overrideSourceQuestionID == nil else { return nil }
        return question.interview?.title
    }
}

public struct AnswerEditorView: View {
    public var question: Question
    public var isInherited: Bool
    public var inheritedFrom: Interview?
    public var onOpenSource: (() -> Void)?
    public var onBeginEditing: ((Question) -> Question?)?

    @State private var activeQuestion: Question
    @State private var hasPreparedForEditing: Bool
    @State private var editorContentID: UUID

    public init(
        question: Question,
        isInherited: Bool = false,
        inheritedFrom: Interview? = nil,
        onOpenSource: (() -> Void)? = nil,
        onBeginEditing: ((Question) -> Question?)? = nil
    ) {
        self.question = question
        self.isInherited = isInherited
        self.inheritedFrom = inheritedFrom
        self.onOpenSource = onOpenSource
        self.onBeginEditing = onBeginEditing
        self._activeQuestion = State(initialValue: question)
        self._hasPreparedForEditing = State(initialValue: !isInherited)
        self._editorContentID = State(initialValue: question.id)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isInherited {
                    inheritedQuestionNotice
                }

                Group {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Question")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        TextField(
                            "Interview question…",
                            text: editableBinding(for: \Question.prompt),
                            axis: .vertical
                        )
                            .textFieldStyle(.plain)
                            .font(.system(size: 25, weight: .medium))
                            .lineSpacing(4)
                            .padding(.vertical, 4)
                    }

                    Divider()

                    TalkingPointsEditorView(
                        talkingPoints: editableBinding(for: \Question.talkingPoints),
                        isReadOnly: false,
                        onEdit: {}
                    )
                    .id(editorContentID)

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Answer script")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Picker(
                                "Format",
                                selection: editableBinding(for: \Question.answerFormat)
                            ) {
                                ForEach(AnswerFormat.allCases) { format in
                                    Text(format.displayName).tag(format)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }

                        switch activeQuestion.answerFormat {
                        case .star:
                            StarAnswerEditorView(
                                situation: editableBinding(for: \Question.situation),
                                task: editableBinding(for: \Question.task),
                                action: editableBinding(for: \Question.action),
                                result: editableBinding(for: \Question.result),
                                onEdit: {}
                            )
                        case .outline:
                            Text("Live mode uses your concise cues as the answer outline.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        case .plain:
                            plainAnswerEditor
                        }
                    }
                }
                .disabled(isInherited && onBeginEditing == nil)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 710)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onChange(of: question.id) { _, newQuestionID in
            // Main remaps selection to the newly materialized override before
            // this callback runs. If it is already our active model, preserve
            // editor identity and focus; otherwise this is a real selection
            // change and the state-backed bindings must follow it.
            guard newQuestionID != activeQuestion.id else { return }
            activeQuestion = question
            hasPreparedForEditing = !isInherited
            editorContentID = newQuestionID
        }
        .onDisappear {
            // Typing is debounced, but leaving this editor is a navigation /
            // focus boundary and should commit the pending override and its
            // latest value immediately.
            DataController.shared.flushSave()
        }
    }

    private var inheritedQuestionNotice: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text(inheritedQuestionMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let onOpenSource {
                Button("Open Source", action: onOpenSource)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Open \(inheritedSourceTitle ?? "source") interview set")
                    .help("Open \(inheritedSourceTitle ?? "the source interview set")")
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var inheritedSourceTitle: String? {
        InheritedQuestionPresentation.sourceTitle(
            question: question,
            inheritedFrom: inheritedFrom
        )
    }

    private var inheritedQuestionMessage: String {
        if let inheritedSourceTitle {
            return "Inherited from \(inheritedSourceTitle). Edits here affect only this interview set; the source stays unchanged."
        }
        return "This question is inherited. Edits here affect only this interview set; the source stays unchanged."
    }

    /// `TextField(axis: .vertical)` grows to fit wrapped text, but it remains
    /// a single-line AppKit text field: Return ends editing rather than adding
    /// a line break. A plain answer is long-form content, so use `TextEditor`
    /// and keep the placeholder outside the editable text value.
    private var plainAnswerEditor: some View {
        PlainAnswerTextEditor(text: Binding(
            get: { activeQuestion.plainAnswer ?? "" },
            set: { setEditableValue($0, for: \Question.plainAnswer) }
        ))
    }
}

/// The plain-answer input is intentionally separated from its model binding so
/// its native multiline behavior can be tested without initializing the app's
/// shared persistence controller.
struct PlainAnswerTextEditor: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Write the words you want to have on screen…")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            TextEditor(text: $text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Plain text answer")
                .padding(6)
        }
        .frame(minHeight: 132, alignment: .topLeading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension AnswerEditorView {
    private func editableBinding<Value>(
        for keyPath: ReferenceWritableKeyPath<Question, Value>
    ) -> Binding<Value> {
        Binding(
            get: { activeQuestion[keyPath: keyPath] },
            set: { setEditableValue($0, for: keyPath) }
        )
    }

    private func setEditableValue<Value>(
        _ value: Value,
        for keyPath: ReferenceWritableKeyPath<Question, Value>
    ) {
        guard let editableQuestion = prepareForEditingIfNeeded() else { return }
        editableQuestion[keyPath: keyPath] = value
        editableQuestion.updatedAt = Date()
        DataController.shared.scheduleSave()
    }

    /// The editor never hands a source-owned property binding directly to an
    /// editable control. Its first setter resolves the child-owned target,
    /// then applies the pending value to that returned model.
    private func prepareForEditingIfNeeded() -> Question? {
        guard isInherited, !hasPreparedForEditing else {
            return activeQuestion
        }

        // An inherited source is never a safe fallback edit target. App
        // surfaces provide this resolver; previews or isolated callers that
        // omit it render disabled controls and remain non-mutating.
        guard let onBeginEditing else { return nil }
        guard let editableQuestion = onBeginEditing(activeQuestion) else { return nil }
        activeQuestion = editableQuestion
        hasPreparedForEditing = true
        return editableQuestion
    }
}
