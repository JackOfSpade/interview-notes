import SwiftUI
import SwiftData

/// SwiftUI state may be reused as long as a view's identity is unchanged.
/// Scope the answer editor to the selected collection as well as the logical
/// question lineage so moving between a source set, `.all`, and a child set
/// can never carry an already-prepared source model into the new context.
/// Within one child, the source row and its materialized override deliberately
/// retain the same identity so the first keystroke does not lose focus.
struct QuestionEditorIdentity: Hashable {
    let selection: SidebarSelection
    let logicalQuestionID: UUID
    let isInherited: Bool

    static func resolve(
        selection: SidebarSelection,
        currentInterview: Interview?,
        question: Question
    ) -> Self {
        let inheritedSource = currentInterview?.inheritedSourceQuestion(for: question)
        return Self(
            selection: selection,
            logicalQuestionID: inheritedSource?.id ?? question.id,
            isInherited: inheritedSource != nil
        )
    }
}

/// Produces a resolver bound to the interview that rendered an editor. The
/// active-scope closures are evaluated when a TextField setter fires, which
/// lets a late IME/focus callback be rejected after navigation has moved on.
@MainActor
enum InheritedQuestionEditingCoordinator {
    static func resolver(
        targetInterview: Interview,
        renderedQuestionID: UUID,
        modelContext: ModelContext,
        activeSelection: @escaping () -> SidebarSelection,
        currentInterviewID: @escaping () -> UUID?,
        activeQuestionID: @escaping () -> UUID?,
        onSelectionRemap: @escaping (UUID) -> Void
    ) -> (Question) -> Question? {
        let targetSelection = SidebarSelection.interview(targetInterview.id)

        return { question in
            guard activeSelection() == targetSelection,
                  currentInterviewID() == targetInterview.id,
                  activeQuestionID() == renderedQuestionID,
                  question.id == renderedQuestionID,
                  targetInterview.effectiveQuestions.contains(where: {
                      $0.id == renderedQuestionID
                  }) else {
                return nil
            }

            // Capture ownership before materialization. Creating an override
            // can immediately update the inverse relationship even before the
            // new model has been explicitly inserted into this context.
            let existingQuestionIDs = Set(targetInterview.questions.map(\.id))
            let editableQuestion = targetInterview.materializeQuestionOverride(for: question)
            guard editableQuestion.interview?.id == targetInterview.id else {
                // The source left this inheritance chain while an editor still
                // held it. Never mutate that former source as a fallback.
                return nil
            }
            if !existingQuestionIDs.contains(editableQuestion.id) {
                modelContext.insert(editableQuestion)
            }

            onSelectionRemap(editableQuestion.id)
            return editableQuestion
        }
    }
}

struct QuestionSourceDestination: Equatable {
    let interviewID: UUID
    let questionID: UUID
}

@MainActor
enum InheritedQuestionSourceCoordinator {
    static func destination(
        for question: Question,
        renderedQuestionID: UUID,
        sourceScope: Interview,
        activeSelection: SidebarSelection,
        currentInterviewID: UUID?,
        activeQuestionID: UUID?
    ) -> QuestionSourceDestination? {
        guard activeSelection == .interview(sourceScope.id),
              currentInterviewID == sourceScope.id,
              activeQuestionID == renderedQuestionID,
              question.id == renderedQuestionID,
              sourceScope.effectiveQuestions.contains(where: {
                  $0.id == renderedQuestionID
              }),
              let sourceQuestion = sourceScope.inheritedSourceQuestion(for: question),
              let sourceInterview = sourceQuestion.interview else {
            return nil
        }
        return QuestionSourceDestination(
            interviewID: sourceInterview.id,
            questionID: sourceQuestion.id
        )
    }
}

public struct MainWorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var prefs = AppPreferences.shared

    @Query(sort: \Interview.sortIndex) private var allInterviews: [Interview]
    @Query private var allQuestions: [Question]

    @State private var sidebarSelection: SidebarSelection = .all
    @State private var selectedQuestionID: UUID?
    @State private var showNewInterviewSheet: Bool = false
    @State private var interviewToEdit: Interview?
    @State private var interviewToDelete: Interview?
    @State private var showDeleteConfirmation = false
    @State private var deletionErrorMessage: String?
    @State private var isLiveActive: Bool = false
    @State private var liveSessionQuestions: [Question] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init() {}

    private var selectedQuestion: Question? {
        guard let id = selectedQuestionID else { return nil }

        // A first edit inserts a child override and remaps selection in the
        // same event. Resolve from the relationship-backed effective list so
        // the editor never disappears while `@Query` publishes that insert.
        if case .interview = sidebarSelection {
            return currentQuestionsList.first { $0.id == id }
        }
        return allQuestions.first { $0.id == id }
    }

    private var currentInterview: Interview? {
        guard case .interview(let id) = sidebarSelection else { return nil }
        return allInterviews.first { $0.id == id }
    }

    /// The global library lists authored records once. A source question is
    /// shown through inheritance only in the child interview's focused view.
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

    private var currentQuestionsList: [Question] {
        switch sidebarSelection {
        case .all:
            return orderedAllQuestions
        case .interview:
            return currentInterview?.effectiveQuestions ?? []
        }
    }

    private var currentEffectiveQuestionIDs: [UUID] {
        currentQuestionsList.map(\.id)
    }

    private var selectedQuestionIsInherited: Bool {
        guard let selectedQuestion,
              let currentInterview else { return false }
        return currentInterview.inheritedSourceQuestion(for: selectedQuestion) != nil
    }

    private var selectedQuestionInheritedSource: Question? {
        guard let selectedQuestion,
              let currentInterview else { return nil }
        return currentInterview.inheritedSourceQuestion(for: selectedQuestion)
    }

    private func sourceOpener(for question: Question) -> (() -> Void)? {
        guard let sourceScope = currentInterview,
              let initialSource = sourceScope.inheritedSourceQuestion(for: question),
              initialSource.interview != nil else {
            return nil
        }

        let renderedQuestionID = question.id
        return {
            // Bind navigation to the editor that rendered the button. A stale
            // action must not inspect another child that became selected in
            // the meantime, and a removed source should not leave an enabled
            // button that silently does nothing.
            guard let destination = InheritedQuestionSourceCoordinator.destination(
                for: question,
                renderedQuestionID: renderedQuestionID,
                sourceScope: sourceScope,
                activeSelection: sidebarSelection,
                currentInterviewID: currentInterview?.id,
                activeQuestionID: selectedQuestionID
            ) else {
                return
            }
            sidebarSelection = .interview(destination.interviewID)
            selectedQuestionID = destination.questionID
        }
    }

    private func editorIdentity(for question: Question) -> QuestionEditorIdentity {
        QuestionEditorIdentity.resolve(
            selection: sidebarSelection,
            currentInterview: currentInterview,
            question: question
        )
    }

    private func editingResolver(
        for question: Question,
        in editingInterview: Interview?
    ) -> ((Question) -> Question?)? {
        guard let editingInterview else { return nil }
        return InheritedQuestionEditingCoordinator.resolver(
            targetInterview: editingInterview,
            renderedQuestionID: question.id,
            modelContext: modelContext,
            activeSelection: { sidebarSelection },
            currentInterviewID: { currentInterview?.id },
            activeQuestionID: { selectedQuestionID },
            onSelectionRemap: { selectedQuestionID = $0 }
        )
    }

    private var navigationTitleText: String {
        switch sidebarSelection {
        case .all: return "Interviews"
        case .interview(let id):
            return allInterviews.first { $0.id == id }?.title ?? "Interview"
        }
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isLiveActive {
                    LiveModeView(
                        questions: liveSessionQuestions,
                        initialQuestionID: selectedQuestionID,
                        onExit: { lastQuestion in
                            WindowManager.shared.exitLiveLayout()
                            isLiveActive = false
                            if let q = lastQuestion {
                                selectedQuestionID = q.id
                            }
                        }
                    )
                } else if allInterviews.isEmpty && allQuestions.isEmpty {
                    LibraryEmptyStateView(showNewInterviewSheet: $showNewInterviewSheet)
                } else {
                    adaptiveSplitView(width: geometry.size.width)
                }

                // Invisible window accessor to capture NSWindow
                WindowAccessor()
                    .frame(width: 0, height: 0)
            }
        }
        // Attach the material to the root rather than the content stack so it
        // continues through the safe area behind the unified toolbar/titlebar.
        .background(WindowBackgroundView().ignoresSafeArea())
        .navigationTitle(isLiveActive ? "" : navigationTitleText)
        .toolbar {
            if !isLiveActive {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        createNewQuestion()
                    } label: {
                        Label("New question", systemImage: "plus")
                    }
                    .help("New question (⌘N)")
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(currentInterview == nil)

                    Button {
                        startLive(with: currentQuestionsList, initialQuestionID: selectedQuestionID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                            Text("Open Live")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .help("Open the live answer panel (⌘Return)")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(currentQuestionsList.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showNewInterviewSheet) {
            NewInterviewSheet(onCreated: { interview in
                sidebarSelection = .interview(interview.id)
            })
        }
        .sheet(item: $interviewToEdit) { interview in
            NewInterviewSheet(interviewToEdit: interview)
        }
        .confirmationDialog(
            interviewToDelete.map { "Delete “\($0.title)”?”" } ?? "Delete Interview?",
            isPresented: $showDeleteConfirmation,
            presenting: interviewToDelete
        ) { interview in
            Button("Delete Interview", role: .destructive) {
                deleteInterview(interview)
            }
            Button("Cancel", role: .cancel) {}
        } message: { interview in
            Text(deleteConfirmationMessage(for: interview))
        }
        .alert(
            "Interview Couldn’t Be Deleted",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? "The interview is still in your library.")
        }
        .onAppear {
            restoreSelection()
        }
        .onChange(of: sidebarSelection) { _, newSel in
            // Persist selected interview
            if case .interview(let id) = newSel {
                prefs.lastSelectedInterviewID = id.uuidString
            } else {
                prefs.lastSelectedInterviewID = nil
            }
            // Move question selection only if current is no longer valid in new list
            if !currentQuestionsList.contains(where: { $0.id == selectedQuestionID }) {
                selectedQuestionID = currentQuestionsList.first?.id
            }
        }
        .onChange(of: allQuestions.count) { _, _ in
            if selectedQuestionID == nil {
                selectedQuestionID = currentQuestionsList.first?.id
            }
        }
        // A parent-link edit changes neither model count. Revalidate against
        // the current effective list so a detached source question cannot
        // remain selected in the child interview.
        .onChange(of: currentEffectiveQuestionIDs) { _, ids in
            guard let selectedQuestionID else {
                self.selectedQuestionID = ids.first
                return
            }
            if !ids.contains(selectedQuestionID) {
                self.selectedQuestionID = ids.first
            }
        }
        .onChange(of: allInterviews.count) { oldCount, newCount in
            // Enter the first set when onboarding/sample creation populates an
            // empty library. Do not kick a legitimate `.all` selection into a
            // random interview after unrelated creation or deletion.
            if oldCount == 0,
               newCount > 0,
               case .all = sidebarSelection,
               let firstInterview = allInterviews.first {
                sidebarSelection = .interview(firstInterview.id)
            }
        }
        .onChange(of: selectedQuestionID) { _, newID in
            prefs.lastSelectedQuestionID = newID?.uuidString
        }
    }

    @ViewBuilder
    private func adaptiveSplitView(width: CGFloat) -> some View {
        if width < 720 {
            // Single pane mode with drilldown navigation
            NavigationStack {
                QuestionListView(
                    selection: $sidebarSelection,
                    selectedQuestionID: $selectedQuestionID,
                    showsInterviewMenu: true,
                    onNewInterview: { showNewInterviewSheet = true },
                    onEditInterview: requestEditInterview,
                    onDeleteInterview: requestDeleteInterview
                )
                .navigationDestination(isPresented: Binding(
                    get: { selectedQuestionID != nil },
                    set: { if !$0 { selectedQuestionID = nil } }
                )) {
                    if let question = selectedQuestion {
                        AnswerEditorView(
                            question: question,
                            isInherited: selectedQuestionIsInherited,
                            inheritedFrom: selectedQuestionInheritedSource?.interview,
                            onOpenSource: sourceOpener(for: question),
                            onBeginEditing: editingResolver(for: question, in: currentInterview)
                        )
                        // A source row and its new child override are the same
                        // logical editor destination. Keep identity stable
                        // through that first-write remap so typing focus stays
                        // in the control that triggered materialization.
                        .id(editorIdentity(for: question))
                    }
                }
            }
        } else {
            // Native 3-pane split view (or 2-pane collapsible)
            NavigationSplitView(columnVisibility: $columnVisibility) {
                LibrarySidebarView(
                    selection: $sidebarSelection,
                    showNewInterviewSheet: $showNewInterviewSheet,
                    onEditInterview: requestEditInterview,
                    onDeleteInterview: requestDeleteInterview
                )
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
            } content: {
                QuestionListView(
                    selection: $sidebarSelection,
                    selectedQuestionID: $selectedQuestionID,
                    showsInterviewMenu: false,
                    onNewInterview: { showNewInterviewSheet = true },
                    onEditInterview: requestEditInterview,
                    onDeleteInterview: requestDeleteInterview
                )
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 360)
            } detail: {
                if let question = selectedQuestion {
                    AnswerEditorView(
                        question: question,
                        isInherited: selectedQuestionIsInherited,
                        inheritedFrom: selectedQuestionInheritedSource?.interview,
                        onOpenSource: sourceOpener(for: question),
                        onBeginEditing: editingResolver(for: question, in: currentInterview)
                    )
                    .id(editorIdentity(for: question))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.book.closed")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)

                        Text("Select a question to prepare its answer")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private func restoreSelection() {
        // Restore the last interview, otherwise choose the first real interview.
        if let savedInterviewStr = prefs.lastSelectedInterviewID,
           let uuid = UUID(uuidString: savedInterviewStr),
           allInterviews.contains(where: { $0.id == uuid }) {
            sidebarSelection = .interview(uuid)
        } else if let firstInterview = allInterviews.first {
            sidebarSelection = .interview(firstInterview.id)
        }

        // Restore a question only when it belongs to the restored interview.
        if let savedQStr = prefs.lastSelectedQuestionID,
           let uuid = UUID(uuidString: savedQStr),
           currentQuestionsList.contains(where: { $0.id == uuid }) {
            selectedQuestionID = uuid
        } else {
            selectedQuestionID = currentQuestionsList.first?.id
        }
    }

    private func createNewQuestion() {
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

    private func requestEditInterview(_ interview: Interview) {
        interviewToEdit = interview
    }

    private func requestDeleteInterview(_ interview: Interview) {
        interviewToDelete = interview
        showDeleteConfirmation = true
    }

    private func deleteConfirmationMessage(for interview: Interview) -> String {
        let count = interview.questions.count
        let questionText = count == 1 ? "1 question" : "\(count) questions"
        var message = "This permanently deletes this interview, its \(questionText), prepared answers, and practice history. This can’t be undone."
        let dependentCount = inheritingDescendants(of: interview).count
        if dependentCount > 0 {
            let dependentText = dependentCount == 1 ? "1 interview set" : "\(dependentCount) interview sets"
            message += "\n\n\(dependentText) inherit directly or through a child and will lose these inherited questions. Direct children will be detached; every surviving set keeps its own questions."
        }
        return message
    }

    /// A master can have nested shared sets. Deleting the master severs only
    /// its direct links, but every descendant loses the master's questions, so
    /// include the full dependent tree in the confirmation. UUID tracking also
    /// keeps this safe if old persisted data contains a malformed cycle.
    private func inheritingDescendants(of interview: Interview) -> [Interview] {
        var descendants: [Interview] = []
        var pending = Array(interview.childInterviews)
        var visitedIDs: Set<UUID> = [interview.id]

        while let candidate = pending.popLast() {
            guard visitedIDs.insert(candidate.id).inserted else { continue }
            descendants.append(candidate)
            pending.append(contentsOf: candidate.childInterviews)
        }
        return descendants
    }

    private func deleteInterview(_ interview: Interview) {
        guard let deletedIndex = allInterviews.firstIndex(where: { $0.id == interview.id }) else {
            return
        }

        let deletedQuestionIDs = Set(interview.questions.map(\.id))
        let remainingInterviews = allInterviews.filter { $0.id != interview.id }
        let replacementInterview: Interview? = {
            guard !remainingInterviews.isEmpty else { return nil }
            return remainingInterviews[min(deletedIndex, remainingInterviews.count - 1)]
        }()

        let deletingCurrentInterview = sidebarSelection == .interview(interview.id)
        let selectedQuestionIsDeleted = selectedQuestionID.map(deletedQuestionIDs.contains) ?? false

        // Commit any debounced editor changes first. If the delete itself then
        // fails, rollback only needs to undo the deletion—not unrelated typing.
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                AppSessionLogger.shared.log(
                    "Could not save pending changes before deleting an interview (\(String(reflecting: type(of: error))))",
                    level: .error
                )
                deletionErrorMessage = "Your recent changes couldn’t be saved, so the interview was not deleted. \(error.localizedDescription)"
                return
            }
        }

        // Detach children explicitly before deleting their master. This keeps
        // company-specific sets and their local questions even if SwiftData's
        // relationship default changes in a future schema migration.
        for child in Array(interview.childInterviews) {
            child.parentInterview = nil
            child.updatedAt = Date()
        }
        modelContext.delete(interview)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            AppSessionLogger.shared.log(
                "Could not save an interview deletion (\(String(reflecting: type(of: error))))",
                level: .error
            )
            deletionErrorMessage = error.localizedDescription
            return
        }

        if deletingCurrentInterview {
            if let replacementInterview {
                sidebarSelection = .interview(replacementInterview.id)
                selectedQuestionID = replacementInterview.effectiveQuestions.first?.id
            } else {
                sidebarSelection = .all
                selectedQuestionID = nil
            }
        } else if selectedQuestionIsDeleted {
            switch sidebarSelection {
            case .interview(let id):
                selectedQuestionID = remainingInterviews
                    .first(where: { $0.id == id })?
                    .effectiveQuestions.first?.id
            case .all:
                selectedQuestionID = orderedAllQuestions
                    .first(where: { !deletedQuestionIDs.contains($0.id) })?
                    .id
            }
        }

        interviewToDelete = nil
    }

    private func startLive(with questions: [Question], initialQuestionID: UUID?) {
        guard !questions.isEmpty else { return }
        liveSessionQuestions = questions
        selectedQuestionID = initialQuestionID ?? questions.first?.id
        WindowManager.shared.enterLiveLayout()
        isLiveActive = true
    }
}
