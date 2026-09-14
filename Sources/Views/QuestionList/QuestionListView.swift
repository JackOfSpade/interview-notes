import SwiftUI
import SwiftData

/// The all-questions library can be temporarily selected while interview sets
/// already exist. Keep its empty action separate from the empty selected-set
/// action so it never creates an accidental duplicate interview.
enum QuestionListEmptyStateRoute: Equatable {
    case addQuestion
    case selectExistingInterview
    case createInterview

    static func resolve(
        hasCurrentInterview: Bool,
        hasExistingInterviews: Bool
    ) -> Self {
        if hasCurrentInterview {
            return .addQuestion
        }
        return hasExistingInterviews ? .selectExistingInterview : .createInterview
    }
}

enum QuestionListSelectionPolicy {
    /// Preserve the active editor when a context-menu action deletes some
    /// other row. If the selected row is deleted, prefer its next visible
    /// neighbor, then its previous one.
    static func selection(
        afterDeleting deletedID: UUID,
        currentSelection: UUID?,
        orderedQuestionIDs: [UUID]
    ) -> UUID? {
        guard currentSelection == deletedID else { return currentSelection }
        guard let deletedIndex = orderedQuestionIDs.firstIndex(of: deletedID) else {
            return nil
        }

        let remainingIDs = orderedQuestionIDs.filter { $0 != deletedID }
        guard !remainingIDs.isEmpty else { return nil }
        return remainingIDs[min(deletedIndex, remainingIDs.count - 1)]
    }
}

public struct QuestionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allQuestions: [Question]
    @Query(sort: \Interview.sortIndex) private var allInterviews: [Interview]

    @Binding public var selection: SidebarSelection
    @Binding var selectedQuestionID: UUID?
    public var showsInterviewMenu: Bool
    public var onNewInterview: () -> Void
    public var onEditInterview: (Interview) -> Void
    public var onDeleteInterview: (Interview) -> Void

    @State private var questionToDelete: Question?
    @State private var showDeleteConfirmation = false

    public init(
        selection: Binding<SidebarSelection>,
        selectedQuestionID: Binding<UUID?>,
        showsInterviewMenu: Bool,
        onNewInterview: @escaping () -> Void,
        onEditInterview: @escaping (Interview) -> Void,
        onDeleteInterview: @escaping (Interview) -> Void
    ) {
        self._selection = selection
        self._selectedQuestionID = selectedQuestionID
        self.showsInterviewMenu = showsInterviewMenu
        self.onNewInterview = onNewInterview
        self.onEditInterview = onEditInterview
        self.onDeleteInterview = onDeleteInterview
    }

    private var currentInterview: Interview? {
        guard case .interview(let id) = selection else { return nil }
        return allInterviews.first { $0.id == id }
    }

    private var questions: [Question] {
        switch selection {
        case .all:
            return orderedAllQuestions
        case .interview:
            // Never substitute the global library while a newly inserted or
            // deleted interview ID is briefly absent from `@Query`. Rows shown
            // here must always match the editor's selected scope.
            return currentInterview?.effectiveQuestions ?? []
        }
    }

    /// The all-questions view intentionally shows authored records once, not a
    /// copy for every interview that inherits them. `@Query` has no ordering
    /// here, so provide one stable order for both the visible list and any
    /// selection fallback based on it.
    private var orderedAllQuestions: [Question] {
        allQuestions.sorted { lhs, rhs in
            let lhsInterviewIndex = lhs.interview?.sortIndex ?? Int.max
            let rhsInterviewIndex = rhs.interview?.sortIndex ?? Int.max
            if lhsInterviewIndex != rhsInterviewIndex {
                return lhsInterviewIndex < rhsInterviewIndex
            }
            let lhsOwnerCreatedAt = lhs.interview?.createdAt ?? .distantFuture
            let rhsOwnerCreatedAt = rhs.interview?.createdAt ?? .distantFuture
            if lhsOwnerCreatedAt != rhsOwnerCreatedAt {
                return lhsOwnerCreatedAt < rhsOwnerCreatedAt
            }
            let lhsOwnerID = lhs.interview?.id.uuidString ?? ""
            let rhsOwnerID = rhs.interview?.id.uuidString ?? ""
            if lhsOwnerID != rhsOwnerID {
                return lhsOwnerID < rhsOwnerID
            }
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private var inheritedQuestions: [Question] {
        currentInterview?.effectiveInheritedQuestions ?? []
    }

    private var localQuestions: [Question] {
        currentInterview?.effectiveLocalQuestions ?? []
    }

    private func inheritedSource(for question: Question) -> Question? {
        currentInterview?.inheritedSourceQuestion(for: question)
    }

    private func isInherited(_ question: Question) -> Bool {
        inheritedSource(for: question) != nil
    }

    private func isLocalToCurrentInterview(_ question: Question) -> Bool {
        guard let currentInterview else { return false }
        return inheritedSource(for: question) == nil
            && question.interview?.id == currentInterview.id
    }

    private var emptyStateRoute: QuestionListEmptyStateRoute {
        QuestionListEmptyStateRoute.resolve(
            hasCurrentInterview: currentInterview != nil,
            hasExistingInterviews: !allInterviews.isEmpty
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if questions.isEmpty {
                emptyStateView
            } else {
                List(selection: $selectedQuestionID) {
                    if currentInterview != nil, !inheritedQuestions.isEmpty {
                        Section("Inherited questions") {
                            ForEach(inheritedQuestions, id: \.id) { question in
                                rowForQuestion(question)
                            }
                        }
                    }

                    if currentInterview != nil, !localQuestions.isEmpty {
                        Section(inheritedQuestions.isEmpty ? "Questions" : "This interview") {
                            ForEach(localQuestions, id: \.id) { question in
                                rowForQuestion(question)
                            }
                        }
                    } else if currentInterview == nil {
                        ForEach(questions, id: \.id) { question in
                            rowForQuestion(question)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog(
            "Delete Question?",
            isPresented: $showDeleteConfirmation,
            presenting: questionToDelete
        ) { question in
            Button("Delete Question", role: .destructive) {
                performDelete(question)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This question and its prepared answer will be deleted.")
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        switch emptyStateRoute {
        case .addQuestion:
            QuestionEmptyStateView(onAddQuestion: createNewQuestion)
        case .selectExistingInterview:
            QuestionEmptyStateView(
                onAddQuestion: createNewQuestion,
                onSelectInterview: {
                    guard let firstInterview = allInterviews.first else { return }
                    selection = .interview(firstInterview.id)
                }
            )
        case .createInterview:
            QuestionEmptyStateView(
                onAddQuestion: createNewQuestion,
                onCreateInterview: onNewInterview
            )
        }
    }

    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentInterview?.title ?? "Questions")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)

                if let date = currentInterview?.formattedDate, !date.isEmpty {
                    Text(date)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if showsInterviewMenu {
                Menu {
                    ForEach(allInterviews) { interview in
                        Button {
                            selection = .interview(interview.id)
                        } label: {
                            Text(interview.title)
                        }
                    }

                    Divider()

                    Button("New Interview…") {
                        onNewInterview()
                    }
                } label: {
                    Label("Choose interview", systemImage: "briefcase")
                        // At compact widths the visible menu label can crowd
                        // out the current interview title. The control still
                        // has an explicit VoiceOver label and Help text.
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Choose interview")
                .help("Choose interview")
            }

            if let currentInterview {
                Menu {
                    Button("Edit Interview…") {
                        onEditInterview(currentInterview)
                    }

                    Divider()

                    Button("Delete Interview…", role: .destructive) {
                        onDeleteInterview(currentInterview)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28, height: 28)
                .accessibilityLabel("Interview actions")
                .help("Edit or delete this interview")
            }

            Button(action: createNewQuestion) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("New question (⌘N)")
            .accessibilityLabel("New question")
            .disabled(currentInterview == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func rowForQuestion(_ question: Question) -> some View {
        let inherited = isInherited(question)
        QuestionRowView(
            question: question,
            isSelected: selectedQuestionID == question.id,
            inheritedFrom: inherited ? inheritedSource(for: question)?.interview : nil
        )
            .tag(question.id)
            .onTapGesture { selectedQuestionID = question.id }
            .contextMenu {
                if inherited {
                    Text("Inherited from \(inheritedSource(for: question)?.interview?.title ?? "its source interview")")
                } else if isLocalToCurrentInterview(question) {
                    let localIndex = localQuestions.firstIndex(where: { $0.id == question.id }) ?? 0
                    Button("Move Up") {
                        moveQuestion(question, by: -1)
                    }
                    .disabled(localIndex == 0)

                    Button("Move Down") {
                        moveQuestion(question, by: 1)
                    }
                    .disabled(localIndex + 1 >= localQuestions.count)

                    Divider()

                    Button("Duplicate Question") {
                        duplicateQuestion(question)
                    }

                    Divider()

                    Button("Delete Question", role: .destructive) {
                        confirmDelete(question)
                    }
                }
            }
    }

    public func createNewQuestion() {
        guard let interview = currentInterview else { return }
        let newQ = Question(
            prompt: "",
            category: .behavioral,
            talkingPoints: [],
            answerFormat: .star,
            sortIndex: (interview.sortedQuestions.map(\.sortIndex).max() ?? -1) + 1,
            interview: interview
        )
        modelContext.insert(newQ)
        selectedQuestionID = newQ.id
        DataController.shared.flushSave()
    }

    private func duplicateQuestion(_ question: Question) {
        guard isLocalToCurrentInterview(question),
              let interview = currentInterview,
              let sourceIndex = localQuestions.firstIndex(where: { $0.id == question.id }) else {
            return
        }

        let dup = Question(
            prompt: "\(question.prompt) (Copy)",
            category: question.category,
            talkingPoints: question.talkingPoints,
            answerFormat: question.answerFormat,
            situation: question.situation,
            task: question.task,
            action: question.action,
            result: question.result,
            plainAnswer: question.plainAnswer,
            tags: question.tags,
            isFavorite: question.isFavorite,
            confidence: question.confidence,
            sortIndex: question.sortIndex + 1,
            interview: interview
        )
        modelContext.insert(dup)

        // A copied row is inserted immediately after its source. Reindex only
        // the visible local section: child-owned overrides occupy inherited
        // slots and a local list action must not silently rewrite their order
        // metadata.
        var reorderedQuestions = localQuestions
        reorderedQuestions.removeAll { $0.id == dup.id }
        reorderedQuestions.insert(dup, at: sourceIndex + 1)
        let now = Date()
        for (index, orderedQuestion) in reorderedQuestions.enumerated() {
            orderedQuestion.sortIndex = index
            orderedQuestion.updatedAt = now
        }
        selectedQuestionID = dup.id
        DataController.shared.flushSave()
    }

    private func confirmDelete(_ question: Question) {
        guard isLocalToCurrentInterview(question) else { return }
        if question.hasNonEmptyAnswer {
            questionToDelete = question
            showDeleteConfirmation = true
        } else {
            performDelete(question)
        }
    }

    private func performDelete(_ question: Question) {
        guard isLocalToCurrentInterview(question) else { return }
        selectedQuestionID = QuestionListSelectionPolicy.selection(
            afterDeleting: question.id,
            currentSelection: selectedQuestionID,
            orderedQuestionIDs: questions.map(\.id)
        )
        modelContext.delete(question)
        questionToDelete = nil
        DataController.shared.flushSave()
    }

    private func moveQuestion(_ question: Question, by offset: Int) {
        guard isLocalToCurrentInterview(question),
              let currentIndex = localQuestions.firstIndex(where: { $0.id == question.id }) else { return }

        let destinationIndex = currentIndex + offset
        guard localQuestions.indices.contains(destinationIndex) else { return }

        var reorderedQuestions = localQuestions
        let movedQuestion = reorderedQuestions.remove(at: currentIndex)
        reorderedQuestions.insert(movedQuestion, at: destinationIndex)

        let now = Date()
        for (index, orderedQuestion) in reorderedQuestions.enumerated() {
            orderedQuestion.sortIndex = index
            orderedQuestion.updatedAt = now
        }
        DataController.shared.flushSave()
    }
}
