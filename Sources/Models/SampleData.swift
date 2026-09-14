import Foundation
import SwiftData

@MainActor
public struct SampleData {
    public static func insertSampleData(into context: ModelContext) {
        let calendar = Calendar.current
        let now = Date()

        // 1. Stripe — Product Designer
        let stripeInterview = Interview(
            company: "Stripe",
            role: "Product Designer",
            interviewDate: calendar.date(byAdding: .day, value: 14, to: now),
            sortIndex: 1
        )
        context.insert(stripeInterview)

        let q1 = Question(
            prompt: "Tell me about a time you influenced without authority.",
            category: .leadership,
            talkingPoints: [
                "Diagnosed why the roadmap conversation was stuck",
                "Made the tradeoffs visible with a lightweight prototype",
                "Earned alignment without escalating"
            ],
            answerFormat: .star,
            situation: "Our activation roadmap had stalled because Product and Engineering disagreed on whether onboarding speed or flexibility mattered more.",
            task: "I needed to create alignment even though I didn’t own either team’s priorities.",
            action: "I interviewed both leads, reframed the disagreement around a shared activation metric, and built a small prototype that made each tradeoff tangible. I facilitated a review using evidence rather than opinions.",
            result: "We agreed on a phased approach in one session. The first release shipped two weeks earlier and improved completion by 11%.",
            isFavorite: true,
            confidence: .again,
            sortIndex: 0,
            interview: stripeInterview
        )
        context.insert(q1)

        let attempt1 = PracticeAttempt(
            rating: .again,
            practicedAt: calendar.date(byAdding: .day, value: -3, to: now) ?? now,
            question: q1
        )
        context.insert(attempt1)
        q1.practiceAttempts.append(attempt1)

        let q2 = Question(
            prompt: "Describe a difficult disagreement with a stakeholder.",
            category: .collaboration,
            talkingPoints: [
                "Separated the relationship from the problem",
                "Brought user evidence into the conversation",
                "Left with a clear decision rule"
            ],
            answerFormat: .star,
            situation: "A regional lead wanted a bespoke checkout flow that conflicted with our shared product direction.",
            task: "I had to protect product coherence without dismissing a legitimate market need.",
            action: "I listened for the underlying constraint, reviewed support evidence together, and proposed a configurable step that solved the need without forking the experience.",
            result: "We avoided a costly parallel flow, launched the configurable option, and reduced regional support tickets by 18%.",
            isFavorite: false,
            confidence: .good,
            sortIndex: 1,
            interview: stripeInterview
        )
        context.insert(q2)

        let attempt2 = PracticeAttempt(
            rating: .good,
            practicedAt: calendar.date(byAdding: .day, value: -7, to: now) ?? now,
            question: q2
        )
        context.insert(attempt2)
        q2.practiceAttempts.append(attempt2)

        let q3 = Question(
            prompt: "Why Stripe, and why this role right now?",
            category: .motivation,
            talkingPoints: [
                "Infrastructure that makes complex work feel simple",
                "High-leverage systems design",
                "Ready to operate at broader scope"
            ],
            answerFormat: .star,
            situation: "I’m most energized by products that hide enormous complexity behind clear, trustworthy interfaces.",
            task: "My next role should combine systems thinking, craft, and measurable impact for ambitious users.",
            action: "Stripe sits at that intersection. This role would let me apply my platform experience while learning from teams setting the standard for developer and business tools.",
            result: "It is the rare move that deepens my current strengths while stretching me into a larger, more consequential problem space.",
            isFavorite: true,
            confidence: .confident,
            sortIndex: 2,
            interview: stripeInterview
        )
        context.insert(q3)

        let attempt3 = PracticeAttempt(
            rating: .confident,
            practicedAt: calendar.date(byAdding: .day, value: -1, to: now) ?? now,
            question: q3
        )
        context.insert(attempt3)
        q3.practiceAttempts.append(attempt3)

        let q4 = Question(
            prompt: "How do you make progress when the problem is ambiguous?",
            category: .process,
            talkingPoints: [
                "Turn uncertainty into explicit assumptions",
                "Find the cheapest useful evidence",
                "Make the next decision reversible"
            ],
            answerFormat: .star,
            situation: "I often begin with incomplete signals, competing definitions of success, and no obvious owner.",
            task: "My job is to create enough shared clarity for the team to move without pretending uncertainty is gone.",
            action: "I map what we know, label assumptions, agree on the riskiest question, and choose the smallest research or prototype that can answer it.",
            result: "The team gets momentum, decisions remain traceable, and we invest deeply only after the highest-risk assumptions survive contact with evidence.",
            isFavorite: false,
            confidence: .confident,
            sortIndex: 3,
            interview: stripeInterview
        )
        context.insert(q4)

        let attempt4 = PracticeAttempt(
            rating: .confident,
            practicedAt: calendar.date(byAdding: .day, value: -1, to: now) ?? now,
            question: q4
        )
        context.insert(attempt4)
        q4.practiceAttempts.append(attempt4)

        // 2. Figma — Staff Designer
        let figmaInterview = Interview(
            company: "Figma",
            role: "Staff Designer",
            interviewDate: calendar.date(byAdding: .day, value: 28, to: now),
            sortIndex: 2
        )
        context.insert(figmaInterview)

        let f1 = Question(
            prompt: "How do you scale a design system across autonomous product teams?",
            category: .technical,
            talkingPoints: [
                "Federated governance model over strict gatekeeping",
                "Token architecture aligned with engineering components",
                "Automated linters to maintain consistency without meetings"
            ],
            answerFormat: .star,
            situation: "Six independent squads were duplicating button variants and inconsistent modal patterns across three product surfaces.",
            task: "Establish a unified design system that teams would voluntarily adopt instead of bypass.",
            action: "Created a core working group with representatives from each squad, built a shared token pipeline, and held weekly open office hours.",
            result: "Adoption reached 92% across all repos within 4 months, cutting frontend UI review cycles by half.",
            isFavorite: true,
            confidence: .good,
            sortIndex: 0,
            interview: figmaInterview
        )
        context.insert(f1)

        let f2 = Question(
            prompt: "Tell me about a high-stakes project that failed and how you recovered.",
            category: .behavioral,
            talkingPoints: [
                "Early metrics looked promising but retention collapsed",
                "Ran immediate post-mortem without assigning blame",
                "Pivoted core workflow based on live customer shadowing"
            ],
            answerFormat: .star,
            situation: "We launched an automated team onboarding wizard that we expected to increase 7-day activation.",
            task: "Diagnose why users abandoned the wizard midway and salvage the project.",
            action: "Observed live user sessions, realized users felt forced into configuration before understanding value, and redesigned it as an optional checklist.",
            result: "Recovered onboarding completion from 34% back up to 68% and instituted pre-launch usability tests for all core flows.",
            isFavorite: false,
            confidence: .again,
            sortIndex: 1,
            interview: figmaInterview
        )
        context.insert(f2)

        // 3. General Behavioral
        let generalInterview = Interview(
            company: "General behavioral",
            role: "Core Question Bank",
            interviewDate: nil,
            sortIndex: 0
        )
        context.insert(generalInterview)

        let g1 = Question(
            prompt: "Walk me through your end-to-end design process for a 0-to-1 feature.",
            category: .process,
            talkingPoints: [
                "Problem framing & user hypothesis validation",
                "Cross-functional design sprints & rapid wireframing",
                "High-fidelity prototyping & usability benchmarks",
                "Instrumentation, launch readiness, and iterative polish"
            ],
            answerFormat: .star,
            situation: "Asked repeatedly across screeners and hiring manager rounds.",
            task: "Provide a clear, structured narrative showcasing strategic thinking and craft excellence.",
            action: "Walk through the Double Diamond model using a real-world payment dispute resolution tool as an anchor example.",
            result: "Consistently demonstrates both macro-level product strategy and micro-interaction rigor.",
            isFavorite: true,
            confidence: .confident,
            sortIndex: 0,
            interview: generalInterview
        )
        context.insert(g1)

        // The sample library should make the shared-question workflow
        // immediately visible: company sets retain their own questions while
        // this bank's answer appears first in each of them.
        stripeInterview.parentInterview = generalInterview
        figmaInterview.parentInterview = generalInterview

        try? context.save()
    }
}
