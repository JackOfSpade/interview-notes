import Foundation
import SwiftData

@Model
public final class Interview {
    @Attribute(.unique) public var id: UUID
    public var company: String
    public var role: String
    public var interviewDate: Date?
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Question.interview)
    public var questions: [Question] = []

    /// The optional set this interview inherits common questions from. A child
    /// owns only its additions and question overrides. Untouched inherited
    /// questions remain live references to their source interview; editing one
    /// in the child creates a child-owned copy instead of changing the source.
    public var parentInterview: Interview?

    /// Inverse of `parentInterview`. Deleting a master only severs this link;
    /// company-specific child interviews and their local questions are kept.
    @Relationship(deleteRule: .nullify, inverse: \Interview.parentInterview)
    public var childInterviews: [Interview] = []

    public init(
        id: UUID = UUID(),
        company: String,
        role: String,
        interviewDate: Date? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.company = company
        self.role = role
        self.interviewDate = interviewDate
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.questions = []
        self.parentInterview = nil
        self.childInterviews = []
    }

    public var title: String {
        if role.isEmpty {
            return company.isEmpty ? "Untitled Interview" : company
        }
        return "\(company) — \(role)"
    }

    public var formattedDate: String {
        guard let date = interviewDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    public var sortedQuestions: [Question] {
        // SwiftData keeps deleted relationship members attached until the
        // context saves. Exclude them immediately so list projections and a
        // just-deleted override reveal the source in the same transaction.
        questions.filter { !$0.isDeleted }.sorted { (q1: Question, q2: Question) in
            if q1.sortIndex != q2.sortIndex {
                return q1.sortIndex < q2.sortIndex
            }
            if q1.createdAt != q2.createdAt {
                return q1.createdAt < q2.createdAt
            }
            // A stable final key avoids rows changing order when two questions
            // were created in the same timestamp resolution bucket.
            return q1.id.uuidString < q2.id.uuidString
        }
    }

    /// Questions supplied by parent sets, ordered from the root master down to
    /// the immediate parent. A child-owned override remains in the inherited
    /// slot it replaces, while local additions and orphaned overrides are
    /// intentionally excluded.
    public var inheritedQuestions: [Question] {
        effectiveInheritedQuestions
    }

    /// The visible questions occupying inherited slots. This includes a
    /// child-owned override because it still represents its ancestor's row.
    /// Keeping that provenance separate from ownership lets the UI preserve
    /// the inherited/local sections without rendering both source and copy.
    public var effectiveInheritedQuestions: [Question] {
        resolvedQuestionSlots
            .filter(\.occupiesInheritedSlot)
            .map(\.question)
    }

    /// Visible questions introduced by this interview. Overrides whose source
    /// is no longer in the active inheritance chain become ordinary local
    /// content here, so detaching or deleting a source never loses the copy.
    public var effectiveLocalQuestions: [Question] {
        resolvedQuestionSlots
            .filter { !$0.occupiesInheritedSlot }
            .map(\.question)
    }

    /// The question set presented for this interview: root-master questions
    /// first, followed by each descendant set's local questions. The traversal
    /// is defensive so corrupted cyclic relationships never hang the UI.
    public var effectiveQuestions: [Question] {
        resolvedQuestionSlots.map(\.question)
    }

    /// Returns the nearest ancestor question behind a visible inherited row.
    /// For an untouched inherited question this is the question itself. For a
    /// child-owned override it is the effective question that was visible in
    /// the parent immediately before the child override was applied.
    public func inheritedSourceQuestion(for question: Question) -> Question? {
        resolvedQuestionSlots
            .first { $0.question.id == question.id }?
            .inheritedSourceQuestion
    }

    /// Convenience for source-set navigation.
    public func inheritedSource(for question: Question) -> Interview? {
        inheritedSourceQuestion(for: question)?.interview
    }

    /// Materializes an inherited question as an editable, child-owned copy.
    /// Repeated calls for any question in the same lineage return the existing
    /// effective override instead of creating another row.
    @discardableResult
    public func materializeQuestionOverride(for question: Question) -> Question {
        let slots = resolvedQuestionSlots

        // Duplicate or older direct-link data can leave a caller holding a
        // child-owned record that is no longer the effective member of its
        // lineage. Always return the visible winner rather than allowing an
        // editor to keep mutating a hidden duplicate.
        if question.interview?.id == id {
            guard let ownedSlot = slots.first(where: { slot in
                slot.lineageIDs.contains(question.id)
                    && slot.question.interview?.id == id
            }) else {
                return question
            }

            canonicalizeOverrideIfNeeded(in: ownedSlot)
            return ownedSlot.question
        }

        // A stale editor can outlive a reparent or source deletion. Never turn
        // an unrelated question into a local override merely because a caller
        // still holds that object.
        guard let inheritedSlot = slots.first(where: { slot in
            slot.occupiesInheritedSlot && slot.lineageIDs.contains(question.id)
        }) else {
            return question
        }

        if inheritedSlot.question.interview?.id == id {
            canonicalizeOverrideIfNeeded(in: inheritedSlot)
            return inheritedSlot.question
        }

        let source = inheritedSlot.question
        let lineageSourceID = inheritedSlot.canonicalQuestionID
        let now = Date()
        let override = Question(
            prompt: source.prompt,
            category: source.category,
            talkingPoints: source.talkingPoints,
            answerFormat: source.answerFormat,
            situation: source.situation,
            task: source.task,
            action: source.action,
            result: source.result,
            plainAnswer: source.plainAnswer,
            tags: source.tags,
            isFavorite: source.isFavorite,
            confidence: source.confidence,
            sortIndex: source.sortIndex,
            createdAt: now,
            updatedAt: now,
            overrideSourceQuestionID: lineageSourceID,
            interview: self
        )

        // Preserve raw values as metadata even if a future app version does
        // not recognize an enum case written by a newer schema.
        override.categoryRaw = source.categoryRaw
        override.answerFormatRaw = source.answerFormatRaw
        override.confidenceRaw = source.confidenceRaw
        return override
    }

    /// Older builds could persist an override that named the immediately
    /// overridden question. Once that record is edited through the current
    /// set, store the stable root identifier so deleting an intermediate set
    /// or reparenting does not strand the customized copy.
    private func canonicalizeOverrideIfNeeded(in slot: ResolvedQuestionSlot) {
        let question = slot.question
        // Rewriting a same-owner direct chain would turn its records into
        // indistinguishable canonical duplicates and could change which one
        // wins on the very next resolution. Leave malformed/legacy chains
        // intact unless there is exactly one child-owned member to migrate.
        let childOwnedLineageCount = sortedQuestions.lazy
            .filter { slot.lineageIDs.contains($0.id) }
            .prefix(2)
            .count
        guard slot.occupiesInheritedSlot,
              question.interview?.id == id,
              childOwnedLineageCount == 1,
              question.overrideSourceQuestionID != slot.canonicalQuestionID else {
            return
        }
        question.overrideSourceQuestionID = slot.canonicalQuestionID
    }

    /// Returns `true` when assigning `candidate` as this interview's parent
    /// would introduce (or join) an invalid inheritance cycle.
    public func wouldCreateInheritanceCycle(with candidate: Interview?) -> Bool {
        guard let candidate else { return false }

        var visitedIDs: Set<UUID> = []
        var current: Interview? = candidate
        while let interview = current {
            if interview.id == id {
                return true
            }
            // A pre-existing loop is not a safe inheritance source either.
            guard visitedIDs.insert(interview.id).inserted else {
                return true
            }
            current = interview.parentInterview
        }
        return false
    }

    /// Convenience helper for parent pickers. `nil` means no inheritance and
    /// is always valid.
    public func canInherit(from candidate: Interview?) -> Bool {
        !wouldCreateInheritanceCycle(with: candidate)
    }

    /// Builds the ancestor-to-self chain once, using stable UUIDs rather than
    /// object identity. If a malformed loop is encountered, it returns only
    /// the non-repeating portion so callers can safely render what remains.
    private func inheritanceChain(dropSelf: Bool) -> [Interview] {
        var reversedChain: [Interview] = []
        var visitedIDs: Set<UUID> = []
        var current: Interview? = dropSelf ? parentInterview : self

        // As with to-many relationships, SwiftData may leave a deleted parent
        // reachable until save. Treat it as already detached for projections.
        while let interview = current,
              !interview.isDeleted,
              visitedIDs.insert(interview.id).inserted {
            // Starting from a parent can still eventually revisit `self` in a
            // malformed graph. Inherited content must never include local
            // questions, even in that case.
            if dropSelf, interview.id == id {
                break
            }
            reversedChain.append(interview)
            current = interview.parentInterview
        }

        return Array(reversedChain.reversed())
    }

    /// Resolves questions from the root toward this interview. An override
    /// replaces its lineage's current row in place; later (therefore nearer)
    /// layers win. The accumulated lineage also lets new overrides point to a
    /// stable root ID while still matching direct-link data.
    private var resolvedQuestionSlots: [ResolvedQuestionSlot] {
        var slots: [ResolvedQuestionSlot] = []

        for interview in inheritanceChain(dropSelf: false) {
            let isCurrentInterview = interview.id == id

            let sortedQuestions = interview.sortedQuestions
            var unresolvedQuestionIDs = Set(sortedQuestions.map(\.id))
            var deferredQuestions: [Question] = []

            for question in sortedQuestions {
                unresolvedQuestionIDs.remove(question.id)

                if applyOverride(
                    question,
                    to: &slots,
                    isCurrentInterview: isCurrentInterview
                ) {
                    resolveDeferredOverrides(
                        &deferredQuestions,
                        in: &slots,
                        isCurrentInterview: isCurrentInterview
                    )
                    continue
                }

                // A direct-link override may sort before the same-layer
                // record it names. Defer it until that record has joined its
                // inherited lineage. This makes resolution independent of
                // relationship-array and sort order.
                if let sourceID = question.overrideSourceQuestionID,
                   sourceID != question.id,
                   (unresolvedQuestionIDs.contains(sourceID)
                    || deferredQuestions.contains(where: { $0.id == sourceID })) {
                    deferredQuestions.append(question)
                    continue
                }

                appendQuestionSlot(
                    question,
                    to: &slots,
                    isCurrentInterview: isCurrentInterview
                )
                resolveDeferredOverrides(
                    &deferredQuestions,
                    in: &slots,
                    isCurrentInterview: isCurrentInterview
                )
            }

            // Only malformed source cycles can remain here. Seed each
            // disconnected component deterministically, then collapse every
            // member reachable from it. This guarantees finite traversal and
            // avoids duplicate visible rows for one cyclic lineage.
            while !deferredQuestions.isEmpty {
                let seed = deferredQuestions.removeFirst()
                appendQuestionSlot(
                    seed,
                    to: &slots,
                    isCurrentInterview: isCurrentInterview
                )
                resolveDeferredOverrides(
                    &deferredQuestions,
                    in: &slots,
                    isCurrentInterview: isCurrentInterview
                )
            }
        }

        return slots
    }

    /// Applies a question to an already known lineage. Returns `false` when
    /// its source has not been encountered yet.
    private func applyOverride(
        _ question: Question,
        to slots: inout [ResolvedQuestionSlot],
        isCurrentInterview: Bool
    ) -> Bool {
        guard let sourceID = question.overrideSourceQuestionID,
              let index = slots.firstIndex(where: { $0.lineageIDs.contains(sourceID) }) else {
            return false
        }

        let replacedQuestion = slots[index].question
        slots[index].lineageIDs.insert(question.id)
        slots[index].question = question

        if isCurrentInterview {
            if slots[index].occupiesInheritedSlot,
               replacedQuestion.interview?.id != id {
                slots[index].inheritedSourceQuestion = replacedQuestion
            }
        } else {
            // From this interview's perspective, the nearest ancestor owns
            // the source row it can navigate to.
            slots[index].inheritedSourceQuestion = question
        }
        return true
    }

    private func appendQuestionSlot(
        _ question: Question,
        to slots: inout [ResolvedQuestionSlot],
        isCurrentInterview: Bool
    ) {
        let occupiesInheritedSlot = !isCurrentInterview
        let lineageIDs = Set([question.id, question.overrideSourceQuestionID].compactMap { $0 })
        slots.append(
            ResolvedQuestionSlot(
                question: question,
                lineageIDs: lineageIDs,
                canonicalQuestionID: question.overrideSourceQuestionID ?? question.id,
                occupiesInheritedSlot: occupiesInheritedSlot,
                inheritedSourceQuestion: occupiesInheritedSlot ? question : nil
            )
        )
    }

    private func resolveDeferredOverrides(
        _ questions: inout [Question],
        in slots: inout [ResolvedQuestionSlot],
        isCurrentInterview: Bool
    ) {
        var madeProgress = true
        while madeProgress, !questions.isEmpty {
            madeProgress = false
            var remaining: [Question] = []

            for question in questions {
                if applyOverride(
                    question,
                    to: &slots,
                    isCurrentInterview: isCurrentInterview
                ) {
                    madeProgress = true
                } else {
                    remaining.append(question)
                }
            }
            questions = remaining
        }
    }
}

private struct ResolvedQuestionSlot {
    var question: Question
    var lineageIDs: Set<UUID>
    var canonicalQuestionID: UUID
    var occupiesInheritedSlot: Bool
    var inheritedSourceQuestion: Question?
}

@Model
public final class Question {
    @Attribute(.unique) public var id: UUID
    public var prompt: String
    public var categoryRaw: String
    public var talkingPoints: [String]
    public var answerFormatRaw: String
    public var situation: String?
    public var task: String?
    public var action: String?
    public var result: String?
    public var plainAnswer: String?
    public var tags: [String]
    public var isFavorite: Bool
    public var confidenceRaw: String
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    /// The stable source-lineage identifier for a child-owned override. This
    /// is intentionally a scalar rather than a SwiftData relationship: source
    /// deletion must not delete or nullify the child's editable copy.
    public var overrideSourceQuestionID: UUID?

    public var interview: Interview?

    @Relationship(deleteRule: .cascade, inverse: \PracticeAttempt.question)
    public var practiceAttempts: [PracticeAttempt] = []

    public init(
        id: UUID = UUID(),
        prompt: String = "",
        category: QuestionCategory = .behavioral,
        talkingPoints: [String] = [],
        answerFormat: AnswerFormat = .star,
        situation: String? = nil,
        task: String? = nil,
        action: String? = nil,
        result: String? = nil,
        plainAnswer: String? = nil,
        tags: [String] = [],
        isFavorite: Bool = false,
        confidence: Confidence = .unrated,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        overrideSourceQuestionID: UUID? = nil,
        interview: Interview? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.categoryRaw = category.rawValue
        self.talkingPoints = talkingPoints
        self.answerFormatRaw = answerFormat.rawValue
        self.situation = situation
        self.task = task
        self.action = action
        self.result = result
        self.plainAnswer = plainAnswer
        self.tags = tags
        self.isFavorite = isFavorite
        self.confidenceRaw = confidence.rawValue
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.overrideSourceQuestionID = overrideSourceQuestionID
        self.interview = interview
        self.practiceAttempts = []
    }

    public var category: QuestionCategory {
        get { QuestionCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    public var answerFormat: AnswerFormat {
        get { AnswerFormat(rawValue: answerFormatRaw) ?? .star }
        set { answerFormatRaw = newValue.rawValue }
    }

    public var confidence: Confidence {
        get { Confidence(rawValue: confidenceRaw) ?? .unrated }
        set { confidenceRaw = newValue.rawValue }
    }

    public var lastPracticedDate: Date? {
        practiceAttempts.map(\.practicedAt).max()
    }

    public var relativeLastPracticed: String {
        guard let last = lastPracticedDate else {
            return "Never practiced"
        }
        let elapsed = abs(Date().timeIntervalSince(last))
        if elapsed < 60 {
            return "Practiced just now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Practiced " + formatter.localizedString(for: last, relativeTo: Date())
    }

    public var isDueForPractice: Bool {
        if confidence == .again { return true }
        if confidence == .unrated { return true }
        guard let last = lastPracticedDate else { return true }
        // If practiced more than 3 days ago for 'good', it's due
        if confidence == .good {
            return Date().timeIntervalSince(last) > 3 * 86400
        }
        // If 'confident', due after 7 days
        return Date().timeIntervalSince(last) > 7 * 86400
    }

    public var hasNonEmptyAnswer: Bool {
        if let s = situation, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let t = task, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let a = action, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let r = result, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let p = plainAnswer, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !talkingPoints.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).isEmpty { return true }
        return false
    }

    public var fullAnswerDisplayText: String {
        switch answerFormat {
        case .star:
            var sections: [String] = []
            if let s = situation?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sections.append("Situation: \(s)")
            }
            if let t = task?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                sections.append("Task: \(t)")
            }
            if let a = action?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
                sections.append("Action: \(a)")
            }
            if let r = result?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
                sections.append("Result: \(r)")
            }
            return sections.joined(separator: "\n\n")
        case .outline:
            var points = talkingPoints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { "• \($0)" }
            if let plain = plainAnswer, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                points.append(plain.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return points.joined(separator: "\n")
        case .plain:
            return plainAnswer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    public var wordCount: Int {
        let text = fullAnswerDisplayText
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return max(1, words.count)
    }
}

@Model
public final class PracticeAttempt {
    @Attribute(.unique) public var id: UUID
    public var ratingRaw: String
    public var practicedAt: Date

    public var question: Question?

    public init(
        id: UUID = UUID(),
        rating: Confidence,
        practicedAt: Date = Date(),
        question: Question? = nil
    ) {
        self.id = id
        self.ratingRaw = rating.rawValue
        self.practicedAt = practicedAt
        self.question = question
    }

    public var rating: Confidence {
        get { Confidence(rawValue: ratingRaw) ?? .good }
        set { ratingRaw = newValue.rawValue }
    }
}
