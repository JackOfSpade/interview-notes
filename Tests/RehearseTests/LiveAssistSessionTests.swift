import XCTest
@testable import Rehearse

@MainActor
final class LiveAssistSessionTests: XCTestCase {
    func testExtractorUsesOnlyTheLastCompletedQuestion() {
        let question = LiveTranscriptQuestionExtractor.latestQuestion(
            in: "Thanks for explaining that. Tell me about a disagreement with a stakeholder?"
        )

        XCTAssertEqual(question, "Tell me about a disagreement with a stakeholder?")
    }

    func testExtractorAcceptsAQuestionShapeWhenASROmitsPunctuation() {
        let question = LiveTranscriptQuestionExtractor.latestQuestion(
            in: "Describe a time you changed a difficult decision"
        )

        XCTAssertEqual(question, "Describe a time you changed a difficult decision")
    }

    func testExtractorDoesNotPromoteOrdinaryTranscriptAsAQuestion() {
        XCTAssertNil(
            LiveTranscriptQuestionExtractor.latestQuestion(
                in: "Thanks, that gives me a clear picture of the project"
            )
        )
    }

    func testServiceForwardsFinalWithSameWordsButFiltersExactDuplicateCallbacks() {
        let service = SystemAudioTranscriptionService()
        var delivered: [SystemAudioTranscriptionService.Transcript] = []
        service.onTranscriptUpdate = { delivered.append($0) }

        // This models the normal Speech sequence: repeated partial callbacks,
        // then a final callback whose words have not changed. The final event
        // is significant because it ends the recognition request.
        service.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a disagreement with a stakeholder",
            isFinal: false
        ))
        service.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a disagreement with a stakeholder",
            isFinal: false
        ))
        service.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a disagreement with a stakeholder",
            isFinal: true
        ))
        service.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a disagreement with a stakeholder",
            isFinal: true
        ))

        XCTAssertEqual(delivered, [
            .init(text: "Tell me about a disagreement with a stakeholder", isFinal: false),
            .init(text: "Tell me about a disagreement with a stakeholder", isFinal: true)
        ])
        XCTAssertEqual(service.transcript, delivered.last)
    }

    func testSyntheticInterviewerTranscriptFlowsThroughServiceAndShowsMatchingRail() throws {
        let checkout = checkoutQuestion()
        let architecture = Question(
            prompt: "Tell me about a time you designed a scalable system.",
            category: .technical,
            answerFormat: .star,
            situation: "The service was reaching its capacity limit.",
            action: "I separated the workload and added observability.",
            result: "We handled the launch without reliability incidents.",
            tags: ["scalable", "architecture"]
        )
        let session = LiveAssistSession()
        session.setQuestions([checkout, architecture])

        // This is the same onTranscriptUpdate closure invoked after Speech
        // recognises a ScreenCaptureKit audio buffer. No OS privacy prompt or
        // physical audio output is involved in the automated test.
        session.transcription.acceptRecognizedTranscriptForTesting(.init(
            text: "Thanks. Tell me about a disagreement with a regional stakeholder over checkout?",
            isFinal: false
        ))

        let plan = try XCTUnwrap(session.cuePlan)
        XCTAssertEqual(plan.resolution, .matched)
        XCTAssertEqual(plan.match?.questionID, checkout.id)
        XCTAssertEqual(session.heardQuestion, "Tell me about a disagreement with a regional stakeholder over checkout?")
        XCTAssertEqual(plan.steps.map(\.label), [
            "THE DISAGREEMENT",
            "WHY IT MATTERED",
            "WHAT I DID",
            "THE TRADE-OFF / DECISION",
            "RESULT"
        ])
    }

    func testSyntheticASRRevisionCannotReplaceRailMidAnswer() throws {
        let checkout = checkoutQuestion()
        let architecture = Question(
            prompt: "Tell me about a time you designed a scalable system.",
            category: .technical,
            answerFormat: .star,
            situation: "A service needed to scale.",
            action: "I changed the architecture.",
            result: "It handled launch traffic.",
            tags: ["scalable", "architecture"]
        )
        let session = LiveAssistSession()
        session.setQuestions([checkout, architecture])

        session.transcription.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a disagreement with a regional stakeholder over checkout",
            isFinal: false
        ))
        let originalRail = try XCTUnwrap(session.cuePlan)
        XCTAssertEqual(originalRail.match?.questionID, checkout.id)

        // A realistic partial-recognition revision can change the words—and
        // therefore the best match—after the candidate has started speaking.
        // The displayed rail must remain the original, one-way path.
        session.transcription.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a scalable system architecture?",
            isFinal: false
        ))

        XCTAssertEqual(session.cuePlan?.match?.questionID, checkout.id)
        XCTAssertEqual(session.cuePlan?.steps, originalRail.steps)
        XCTAssertEqual(session.heardQuestion, "Tell me about a disagreement with a regional stakeholder over checkout")
    }

    func testFinalRevisionKeepsTheRailShownFromAPartialQuestion() throws {
        let checkout = checkoutQuestion()
        let session = LiveAssistSession()
        session.setQuestions([checkout])

        session.transcription.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a disagreement with a regional stakeholder over checkout?",
            isFinal: false
        ))
        let initialPlan = try XCTUnwrap(session.cuePlan)

        // A final correction can add context or alter punctuation after the
        // candidate has begun. It must never rebuild the rail mid-answer.
        session.transcription.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a disagreement with a regional stakeholder over checkout in Europe?",
            isFinal: true
        ))

        XCTAssertEqual(session.cuePlan?.match?.questionID, checkout.id)
        XCTAssertEqual(session.cuePlan?.steps, initialPlan.steps)
        XCTAssertEqual(session.heardQuestion, "Tell me about a disagreement with a regional stakeholder over checkout?")
    }

    func testUnmatchedPartialDoesNotBlockLaterConfidentMatch() throws {
        let checkout = checkoutQuestion()
        let session = LiveAssistSession()
        session.setQuestions([checkout])

        session.transcription.acceptRecognizedTranscriptForTesting(.init(
            text: "How would you assess an unfamiliar market?",
            isFinal: false
        ))
        XCTAssertEqual(session.cuePlan?.resolution, .needsClarification)

        session.transcription.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a disagreement with a regional stakeholder over checkout?",
            isFinal: false
        ))

        XCTAssertEqual(session.cuePlan?.resolution, .matched)
        XCTAssertEqual(session.cuePlan?.match?.questionID, checkout.id)
    }

    func testNextQuestionUnlocksAnotherSyntheticInterviewerTurn() throws {
        let checkout = checkoutQuestion()
        let architecture = Question(
            prompt: "Tell me about a scalable system architecture.",
            category: .technical,
            answerFormat: .plain,
            plainAnswer: "I start with the load profile, isolate the bottleneck, and instrument the risks.",
            tags: ["scalable", "architecture"]
        )
        let session = LiveAssistSession()
        session.setQuestions([checkout, architecture])

        session.transcription.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a disagreement with a regional stakeholder over checkout?",
            isFinal: false
        ))
        XCTAssertEqual(session.cuePlan?.match?.questionID, checkout.id)

        session.prepareForNextQuestion()
        session.transcription.acceptRecognizedTranscriptForTesting(.init(
            text: "Tell me about a scalable system architecture?",
            isFinal: false
        ))

        XCTAssertEqual(session.cuePlan?.match?.questionID, architecture.id)
        XCTAssertEqual(session.cuePlan?.steps.map(\.label), ["OPEN"])
    }

    private func checkoutQuestion() -> Question {
        Question(
            prompt: "Describe a difficult disagreement with a stakeholder.",
            category: .collaboration,
            answerFormat: .star,
            situation: "A regional lead wanted a bespoke checkout flow.",
            task: "Protect product coherence while meeting the market need.",
            action: "I reviewed support evidence together and proposed a configurable alternative.",
            result: "Regional support tickets fell by 18%.",
            tags: ["checkout", "regional", "stakeholder"]
        )
    }
}
