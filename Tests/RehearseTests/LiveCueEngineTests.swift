import XCTest
@testable import Rehearse

@MainActor
final class LiveCueEngineTests: XCTestCase {
    private let engine = LiveCueEngine()

    func testRanksPreparedDisagreementStoryUsingPromptCategoryAndAnswerEvidence() throws {
        let influence = Question(
            prompt: "Tell me about a time you influenced without authority.",
            category: .leadership,
            answerFormat: .star,
            situation: "Two teams had competing priorities.",
            action: "I built a prototype.",
            result: "The teams aligned."
        )
        let disagreement = Question(
            prompt: "Describe a difficult disagreement with a stakeholder.",
            category: .collaboration,
            answerFormat: .star,
            situation: "A regional lead wanted a bespoke checkout flow.",
            task: "Protect product coherence while meeting the market need.",
            action: "I reviewed support evidence and proposed a configurable alternative.",
            result: "Support tickets fell by 18%.",
            tags: ["checkout", "regional"]
        )

        let matches = engine.rank(
            transcript: "Tell me about a disagreement with a regional stakeholder over checkout.",
            among: [influence, disagreement]
        )

        let first = try XCTUnwrap(matches.first)
        XCTAssertEqual(first.questionID, disagreement.id)
        XCTAssertGreaterThan(first.score, 10)
        XCTAssertTrue(first.evidence.contains { $0.kind == .category && $0.detail == "Collaboration" })
        XCTAssertTrue(first.evidence.contains { $0.kind == .tag && $0.detail == "regional" })
    }

    func testStarRailIsAStableTopToBottomConversationPath() throws {
        let question = Question(
            prompt: "Describe a difficult disagreement with a stakeholder.",
            category: .collaboration,
            answerFormat: .star,
            situation: "A regional lead wanted a bespoke checkout flow.",
            task: "I had to protect product coherence without dismissing a legitimate market need.",
            action: "I listened for the underlying constraint, reviewed support evidence together, and proposed a configurable step that solved the need without forking the experience.",
            result: "We avoided a parallel flow and reduced regional support tickets by 18%."
        )
        let analysis = engine.analyze(
            "What was the disagreement, why did it matter, what did you do, what trade-off did you make, and what did you learn?"
        )

        let firstRail = engine.cueRail(for: question, analysis: analysis)
        let secondRail = engine.cueRail(for: question, analysis: analysis)

        XCTAssertEqual(firstRail, secondRail, "The rail must not reorder itself while someone is answering.")
        XCTAssertEqual(firstRail.map(\.label), [
            "THE DISAGREEMENT",
            "WHY IT MATTERED",
            "WHAT I DID",
            "THE TRADE-OFF / DECISION",
            "RESULT",
            "LESSON"
        ])
        XCTAssertEqual(firstRail.map(\.source), [.situation, .task, .action, .action, .result, .guidance])
        XCTAssertTrue(firstRail[2].cue.contains("reviewed support evidence"))
        XCTAssertTrue(firstRail[3].cue.hasPrefix("proposed"))
        XCTAssertTrue(firstRail[4].cue.contains("18%"))
        XCTAssertEqual(firstRail[5].cue, "Close with what you would carry forward from this experience.")
    }

    func testOutlineKeepsUserPointOrderAndCapsAtSix() {
        let question = Question(
            prompt: "How do you approach an ambiguous problem?",
            category: .process,
            talkingPoints: ["Frame the problem", "Test the riskiest assumption", "Make the next decision reversible"],
            answerFormat: .outline
        )
        let rail = engine.cueRail(for: question, analysis: engine.analyze(question.prompt))

        XCTAssertEqual(rail.map(\.cue), question.talkingPoints)
        XCTAssertEqual(rail.map(\.label), ["OPEN", "WHY IT MATTERED", "WHAT I DID"])
    }

    func testUnknownQuestionDoesNotChooseOrConstructAGuessedStory() {
        let prepared = Question(
            prompt: "Tell me about a difficult disagreement with a stakeholder.",
            category: .collaboration,
            answerFormat: .star,
            situation: "A regional lead wanted a bespoke checkout flow.",
            result: "Tickets fell."
        )

        let plan = engine.plan(
            transcript: "How is the weather on Mars today?",
            among: [prepared]
        )

        XCTAssertEqual(plan.resolution, .needsClarification)
        XCTAssertNil(plan.match)
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.analysis.intent, .unknown)
    }

    func testEqualScoresPreserveQuestionInputOrder() {
        let first = Question(prompt: "Tell me about customer research.", category: .behavioral)
        let second = Question(prompt: "Tell me about customer research.", category: .behavioral)

        let matches = engine.rank(transcript: "customer research", among: [first, second])

        XCTAssertEqual(matches.map(\.questionID), [first.id, second.id])
    }

    func testStarRailDoesNotInventADecisionStepUnlessAskedOrSaved() {
        let question = Question(
            prompt: "Tell me about a difficult delivery.",
            category: .behavioral,
            answerFormat: .star,
            situation: "A launch date was at risk.",
            task: "Keep the team aligned.",
            action: "I set up a daily unblocker and made ownership visible.",
            result: "We launched with the critical scope intact."
        )

        let rail = engine.cueRail(
            for: question,
            analysis: engine.analyze("Tell me about a difficult delivery.")
        )

        XCTAssertEqual(rail.map(\.label), ["OPEN", "WHY IT MATTERED", "WHAT I DID", "RESULT"])
        XCTAssertFalse(rail.contains { $0.label == "THE TRADE-OFF / DECISION" })
    }

    func testExplicitPersonalActionAndLessonStaySeparateFromSavedResult() {
        let question = Question(
            prompt: "Tell me about a difficult disagreement.",
            category: .collaboration,
            answerFormat: .star,
            situation: "A regional lead wanted a custom checkout.",
            action: "I reviewed the support evidence with them.",
            result: "Tickets fell by 18%."
        )

        let analysis = engine.analyze("What did you personally do, and what did you learn?")
        let rail = engine.cueRail(for: question, analysis: analysis)

        XCTAssertTrue(analysis.askedComponents.contains(.personalAction))
        XCTAssertEqual(rail.map(\.label), ["OPEN", "WHAT I DID", "RESULT", "LESSON"])
        XCTAssertEqual(rail[2].source, .result)
        XCTAssertEqual(rail[3].source, .guidance)
    }

    func testActionThatBeginsWithDecisionRemainsACompleteActionCue() {
        let question = Question(
            prompt: "Tell me about a product decision.",
            category: .process,
            answerFormat: .star,
            action: "I chose a configurable alternative instead of a separate flow."
        )

        let rail = engine.cueRail(for: question, analysis: engine.analyze(question.prompt))

        XCTAssertEqual(rail.map(\.label), ["WHAT I DID"])
        XCTAssertEqual(rail.first?.cue, "I chose a configurable alternative instead of a separate flow.")
    }
}
