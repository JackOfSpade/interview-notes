import Foundation

/// The broad kind of answer an interviewer is asking for. This is deliberately
/// small and rule based: live matching should be explainable, immediate, and
/// work without a network connection.
public enum LiveQuestionIntent: String, CaseIterable, Sendable, Hashable {
    case leadership
    case collaboration
    case process
    case motivation
    case technical
    case behavioral
    case unknown
}

/// A part of an answer the interviewer explicitly requested. These become
/// labels in the live rail; they are not a second checklist for the speaker.
public enum LiveAskedComponent: String, CaseIterable, Sendable, Hashable {
    case context
    case conflict
    case stakes
    case personalAction
    case decision
    case outcome
    case lesson
    case motivation
}

public struct LiveQuestionAnalysis: Sendable, Hashable {
    public let transcript: String
    public let intent: LiveQuestionIntent
    public let askedComponents: [LiveAskedComponent]

    public init(
        transcript: String,
        intent: LiveQuestionIntent,
        askedComponents: [LiveAskedComponent]
    ) {
        self.transcript = transcript
        self.intent = intent
        self.askedComponents = askedComponents
    }
}

/// Why a prepared question ranked where it did. The UI can show these verbatim
/// when the user wants to check a match, while normal live use stays uncluttered.
public struct LiveMatchEvidence: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case promptWord = "Prompt word"
        case promptPhrase = "Prompt phrase"
        case answerWord = "Answer word"
        case tag = "Tag"
        case category = "Category"
    }

    public let kind: Kind
    public let detail: String
    public let points: Int

    public init(kind: Kind, detail: String, points: Int) {
        self.kind = kind
        self.detail = detail
        self.points = points
    }
}

/// A stable ranked reference to an existing SwiftData question. `position` is
/// retained solely as a deterministic tie breaker; input order never changes
/// while the same transcript is being answered.
public struct LiveRankedQuestion {
    public let question: Question
    public let questionID: UUID
    public let score: Int
    public let evidence: [LiveMatchEvidence]
    public let position: Int

    public init(
        question: Question,
        score: Int,
        evidence: [LiveMatchEvidence],
        position: Int
    ) {
        self.question = question
        self.questionID = question.id
        self.score = score
        self.evidence = evidence
        self.position = position
    }
}

public enum LiveCueSource: String, Sendable, Hashable {
    case situation
    case task
    case action
    case result
    case plainAnswer
    case talkingPoint
    case prompt
    case guidance
}

/// One immutable stop on the live answer path. `cue` is either the user's own
/// prepared content or a short neutral reminder when the answer has no stored
/// decision/lesson field. It never invents a result or a personal experience.
public struct LiveCueStep: Sendable, Hashable, Identifiable {
    public let id: String
    public let component: LiveAskedComponent
    public let label: String
    public let cue: String
    public let source: LiveCueSource

    public init(
        id: String,
        component: LiveAskedComponent,
        label: String,
        cue: String,
        source: LiveCueSource
    ) {
        self.id = id
        self.component = component
        self.label = label
        self.cue = cue
        self.source = source
    }
}

public enum LiveCueResolution: Sendable, Hashable {
    case matched
    case needsClarification
}

/// The output is intentionally a finished path, rather than a bag of answer
/// fragments. A caller can advance through `steps` only in this order.
public struct LiveCuePlan {
    public let analysis: LiveQuestionAnalysis
    public let resolution: LiveCueResolution
    public let match: LiveRankedQuestion?
    public let steps: [LiveCueStep]

    public init(
        analysis: LiveQuestionAnalysis,
        resolution: LiveCueResolution,
        match: LiveRankedQuestion?,
        steps: [LiveCueStep]
    ) {
        self.analysis = analysis
        self.resolution = resolution
        self.match = match
        self.steps = steps
    }
}

/// Deterministic, local question matching and rail construction for Live mode.
/// It has no audio, persistence, model, or UI dependency beyond reading the
/// caller-owned `Question` objects.
public struct LiveCueEngine {
    /// A category signal alone is deliberately insufficient. We only surface a
    /// prepared story once there is at least one useful lexical or tag signal.
    public static let minimumMatchScore = 10
    public static let maximumRailSteps = 6

    public init() {}

    public func analyze(_ transcript: String) -> LiveQuestionAnalysis {
        let normalized = Self.normalized(transcript)
        let words = Self.meaningfulWords(in: transcript)
        let scores = intentScores(in: normalized, words: words)
        let intent = scores
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                lhs.value == rhs.value
                    ? Self.intentOrder(lhs.key) < Self.intentOrder(rhs.key)
                    : lhs.value > rhs.value
            }
            .first?.key ?? .unknown

        var components: [LiveAskedComponent] = []
        func add(_ component: LiveAskedComponent, when condition: Bool) {
            if condition, !components.contains(component) {
                components.append(component)
            }
        }

        add(.context, when: Self.containsAny(normalized, [
            "tell me about", "describe", "walk me through", "give me an example", "a time"
        ]))
        add(.conflict, when: Self.containsAny(normalized, [
            "disagree", "disagreement", "conflict", "pushback", "resistance", "stakeholder"
        ]))
        add(.stakes, when: Self.containsAny(normalized, [
            "why did it matter", "why it mattered", "important", "challenge", "difficult", "high stakes"
        ]))
        add(.personalAction, when: Self.containsAny(normalized, [
            "what did you do", "what did you personally do", "personally", "your contribution",
            "how did you", "how do you", "your role", "your approach", "handle"
        ]))
        add(.decision, when: Self.containsAny(normalized, [
            "decision", "decide", "tradeoff", "trade-off", "choose", "chose", "alternative"
        ]))
        add(.outcome, when: Self.containsAny(normalized, [
            "result", "outcome", "impact", "what happened", "successful", "success"
        ]))
        add(.lesson, when: Self.containsAny(normalized, [
            "learn", "lesson", "would you do differently", "take away", "takeaway"
        ]))
        add(.motivation, when: intent == .motivation)

        return LiveQuestionAnalysis(
            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            intent: intent,
            askedComponents: components
        )
    }

    /// Scores every question with positive evidence. Results are stable: ties
    /// keep the order supplied by the owning interview/question set.
    public func rank(
        transcript: String,
        among questions: [Question]
    ) -> [LiveRankedQuestion] {
        let analysis = analyze(transcript)
        let queryWords = Self.meaningfulWords(in: transcript)
        let queryPhrases = Self.adjacentPhrases(from: queryWords)

        return questions.enumerated().compactMap { position, question in
            let scored = score(
                question: question,
                position: position,
                intent: analysis.intent,
                queryWords: queryWords,
                queryPhrases: queryPhrases
            )
            return scored.score > 0 ? scored : nil
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.position < rhs.position : lhs.score > rhs.score
        }
    }

    /// Chooses one prepared answer only when the evidence passes the matching
    /// threshold. An unmatched question produces no rail, so Live mode can ask
    /// for clarification instead of making the speaker recover from a guess.
    public func plan(
        transcript: String,
        among questions: [Question]
    ) -> LiveCuePlan {
        let analysis = analyze(transcript)
        guard let match = rank(transcript: transcript, among: questions).first,
              match.score >= Self.minimumMatchScore else {
            return LiveCuePlan(
                analysis: analysis,
                resolution: .needsClarification,
                match: nil,
                steps: []
            )
        }

        return LiveCuePlan(
            analysis: analysis,
            resolution: .matched,
            match: match,
            steps: cueRail(for: match.question, analysis: analysis)
        )
    }

    /// Builds the final, fixed rail for an already selected question. The
    /// caller should retain this result for the whole spoken answer rather
    /// than regenerate it from a growing transcript.
    public func cueRail(
        for question: Question,
        analysis: LiveQuestionAnalysis
    ) -> [LiveCueStep] {
        let steps: [LiveCueStep]
        switch question.answerFormat {
        case .star:
            steps = starRail(for: question, analysis: analysis)
        case .outline:
            steps = orderedContentRail(
                content: nonEmptyTalkingPoints(question) + plainSegments(question.plainAnswer),
                sources: Array(repeating: .talkingPoint, count: nonEmptyTalkingPoints(question).count)
                    + Array(repeating: .plainAnswer, count: plainSegments(question.plainAnswer).count),
                analysis: analysis
            )
        case .plain:
            let content = plainSegments(question.plainAnswer)
            steps = orderedContentRail(
                content: content.isEmpty ? nonEmptyTalkingPoints(question) : content,
                sources: Array(
                    repeating: content.isEmpty ? .talkingPoint : .plainAnswer,
                    count: content.isEmpty ? nonEmptyTalkingPoints(question).count : content.count
                ),
                analysis: analysis
            )
        }
        return Array(steps.prefix(Self.maximumRailSteps))
    }

    private func score(
        question: Question,
        position: Int,
        intent: LiveQuestionIntent,
        queryWords: [String],
        queryPhrases: [String]
    ) -> LiveRankedQuestion {
        let promptWords = Set(Self.meaningfulWords(in: question.prompt))
        let answerWords = Set(Self.meaningfulWords(in: question.fullAnswerDisplayText))
        let tagWords = Set(question.tags.flatMap(Self.meaningfulWords))
        let promptPhrases = Set(Self.adjacentPhrases(from: Self.meaningfulWords(in: question.prompt)))
        var evidence: [LiveMatchEvidence] = []

        for word in queryWords where promptWords.contains(word) {
            evidence.append(.init(kind: .promptWord, detail: word, points: 5))
        }
        for phrase in queryPhrases where promptPhrases.contains(phrase) {
            evidence.append(.init(kind: .promptPhrase, detail: phrase, points: 8))
        }
        for word in queryWords where tagWords.contains(word) {
            evidence.append(.init(kind: .tag, detail: word, points: 7))
        }
        for word in queryWords where answerWords.contains(word) && !promptWords.contains(word) {
            evidence.append(.init(kind: .answerWord, detail: word, points: 2))
        }

        if intent != .unknown, categoryIntent(question.category) == intent {
            evidence.append(.init(kind: .category, detail: question.category.rawValue, points: 6))
        }

        return LiveRankedQuestion(
            question: question,
            score: evidence.reduce(0) { $0 + $1.points },
            evidence: evidence,
            position: position
        )
    }

    private func starRail(for question: Question, analysis: LiveQuestionAnalysis) -> [LiveCueStep] {
        let situation = Self.nonEmpty(question.situation)
        let task = Self.nonEmpty(question.task)
        let action = Self.nonEmpty(question.action)
        let result = Self.nonEmpty(question.result)
        let actionSplit = splitAction(action)
        let hasConflict = analysis.askedComponents.contains(.conflict)
        let asksForLesson = analysis.askedComponents.contains(.lesson)
        var raw: [(LiveAskedComponent, String, String, LiveCueSource)] = []

        if let situation {
            raw.append((.context, hasConflict ? "THE DISAGREEMENT" : "OPEN", situation, .situation))
        }
        if let task {
            raw.append((.stakes, hasConflict || analysis.askedComponents.contains(.stakes) ? "WHY IT MATTERED" : "ROLE / GOAL", task, .task))
        }
        if let action = actionSplit.action ?? action {
            raw.append((.personalAction, "WHAT I DID", action, .action))
        }
        if let decision = actionSplit.decision {
            raw.append((.decision, "THE TRADE-OFF / DECISION", decision, .action))
        } else if action != nil,
                  analysis.askedComponents.contains(.decision),
                  !hasDecisionLanguage(action) {
            // Only ask for a decision when the interviewer asked for one.
            // A generic STAR answer with no saved choice should not add a
            // synthetic hurdle halfway through an otherwise usable answer.
            raw.append((.decision, "THE TRADE-OFF / DECISION", "Make the choice and what it protected explicit.", .guidance))
        }
        if let result {
            raw.append((.outcome, "RESULT", result, .result))
        }
        if asksForLesson {
            // STAR has no lesson field. Keep the saved result distinct from
            // the requested reflection rather than mislabelling the result as
            // a lesson the candidate never wrote.
            raw.append((.lesson, "LESSON", "Close with what you would carry forward from this experience.", .guidance))
        }

        if raw.isEmpty {
            return orderedContentRail(
                content: nonEmptyTalkingPoints(question),
                sources: Array(repeating: .talkingPoint, count: nonEmptyTalkingPoints(question).count),
                analysis: analysis
            )
        }
        return raw.enumerated().map { index, value in
            cueStep(index: index, component: value.0, label: value.1, cue: value.2, source: value.3)
        }
    }

    private func orderedContentRail(
        content: [String],
        sources: [LiveCueSource],
        analysis: LiveQuestionAnalysis
    ) -> [LiveCueStep] {
        let labels: [(LiveAskedComponent, String)] = [
            (.context, analysis.askedComponents.contains(.conflict) ? "THE DISAGREEMENT" : "OPEN"),
            (.stakes, "WHY IT MATTERED"),
            (.personalAction, "WHAT I DID"),
            (.decision, "THE TRADE-OFF / DECISION"),
            (.outcome, "RESULT"),
            (.lesson, "CLOSE / LESSON")
        ]
        return content.enumerated().map { index, text in
            let label = labels[min(index, labels.count - 1)]
            return cueStep(
                index: index,
                component: label.0,
                label: label.1,
                cue: text,
                source: sources.indices.contains(index) ? sources[index] : .plainAnswer
            )
        }
    }

    private func cueStep(
        index: Int,
        component: LiveAskedComponent,
        label: String,
        cue: String,
        source: LiveCueSource
    ) -> LiveCueStep {
        LiveCueStep(
            id: "\(index)-\(component.rawValue)",
            component: component,
            label: label,
            cue: cue,
            source: source
        )
    }

    private func splitAction(_ action: String?) -> (action: String?, decision: String?) {
        guard let action else { return (nil, nil) }
        let markers = decisionMarkers
        let lower = action.lowercased()
        guard let marker = markers.compactMap({ marker -> Range<String.Index>? in
            lower.range(of: marker, options: .caseInsensitive)
        }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return (action, nil)
        }

        var prefix = String(action[..<marker.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if prefix.lowercased().hasSuffix(" and") {
            prefix = String(prefix.dropLast(4))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        let decision = String(action[marker.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // “I chose …” is itself a complete action. Splitting it would turn
        // its useful first cue into just “I” or “We”. Preserve it as one
        // thought instead of producing a hollow action before the decision.
        let prefixWords = prefix.lowercased().split(whereSeparator: \.isWhitespace)
        let isOnlyLeadIn = prefixWords.isEmpty || prefixWords.allSatisfy {
            ["i", "we", "then", "and"].contains(String($0))
        }
        guard !isOnlyLeadIn else { return (action, nil) }
        return (prefix, decision.isEmpty ? nil : decision)
    }

    private func hasDecisionLanguage(_ action: String?) -> Bool {
        guard let action else { return false }
        let lower = action.lowercased()
        return decisionMarkers.contains { lower.range(of: $0, options: .caseInsensitive) != nil }
    }

    private var decisionMarkers: [String] {
        ["decided", "chose", "chosen", "proposed", "recommended", "selected", "prioritized", "opted"]
    }

    private func intentScores(in text: String, words: [String]) -> [LiveQuestionIntent: Int] {
        let wordSet = Set(words)
        func count(_ terms: [String]) -> Int {
            terms.reduce(into: 0) { total, term in
                if term.contains(" ") {
                    if text.contains(term) { total += 2 }
                } else if wordSet.contains(term) {
                    total += 1
                }
            }
        }
        return [
            .leadership: count(["lead", "leadership", "influence", "authority", "manage", "manager"]),
            .collaboration: count(["disagreement", "disagree", "conflict", "stakeholder", "collaborate", "partner", "alignment", "pushback"]),
            .process: count(["process", "approach", "ambiguous", "problem", "prioritize", "decision", "how do you"]),
            .motivation: count(["why", "interested", "interest", "role", "company", "career", "join"]),
            .technical: count(["technical", "system", "engineering", "architecture", "scale", "implementation"]),
            .behavioral: count(["tell me about", "describe", "a time", "example", "behavioral"])
        ]
    }

    private func categoryIntent(_ category: QuestionCategory) -> LiveQuestionIntent {
        switch category {
        case .leadership: return .leadership
        case .collaboration: return .collaboration
        case .process: return .process
        case .motivation: return .motivation
        case .technical: return .technical
        case .behavioral, .other: return .behavioral
        }
    }

    private static func intentOrder(_ intent: LiveQuestionIntent) -> Int {
        LiveQuestionIntent.allCases.firstIndex(of: intent) ?? .max
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func nonEmptyTalkingPoints(_ question: Question) -> [String] {
        question.talkingPoints.compactMap(Self.nonEmpty)
    }

    private func plainSegments(_ text: String?) -> [String] {
        guard let text = Self.nonEmpty(text) else { return [] }
        let byParagraph = text
            .components(separatedBy: .newlines)
            .compactMap(Self.nonEmpty)
        if byParagraph.count > 1 { return byParagraph }

        let sentences = text
            .split(whereSeparator: { ".!?".contains($0) })
            .map(String.init)
            .compactMap(Self.nonEmpty)
        return sentences.isEmpty ? [text] : sentences
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: .current)
    }

    private static func containsAny(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains { text.contains($0) }
    }

    private static func meaningfulWords(in text: String) -> [String] {
        let raw = normalized(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(Self.canonicalWord)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) && !stopWords.contains($0) }
        var seen: Set<String> = []
        return raw.filter { seen.insert($0).inserted }
    }

    private static func adjacentPhrases(from words: [String]) -> [String] {
        guard words.count > 1 else { return [] }
        return zip(words, words.dropFirst()).map { "\($0) \($1)" }
    }

    private static func canonicalWord(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies"), word.count > 4 {
            return String(word.dropLast(3)) + "y"
        }
        if word.hasSuffix("ing"), word.count > 5 {
            return String(word.dropLast(3))
        }
        if word.hasSuffix("ed"), word.count > 4 {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), word.count > 4 {
            return String(word.dropLast())
        }
        return word
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "could", "did", "do", "for", "from",
        "had", "has", "have", "how", "i", "if", "in", "is", "it", "me", "my", "of", "on", "or", "our",
        "please", "tell", "that", "the", "their", "this", "to", "was", "we", "what", "when", "with", "would",
        "you", "your", "about", "time", "into", "through"
    ]
}
