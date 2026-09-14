import SwiftUI

public enum QuestionCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case leadership = "Leadership"
    case collaboration = "Collaboration"
    case process = "Process"
    case motivation = "Motivation"
    case technical = "Technical"
    case behavioral = "Behavioral"
    case other = "Other"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .leadership: return "person.crop.circle.badge.checkmark"
        case .collaboration: return "person.2"
        case .process: return "arrow.triangle.2.circlepath"
        case .motivation: return "sparkles"
        case .technical: return "chevron.left.forwardslash.chevron.right"
        case .behavioral: return "bubble.left.and.bubble.right"
        case .other: return "tag"
        }
    }
}

public enum AnswerFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case star = "star"
    case outline = "outline"
    case plain = "plain"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .star: return "STAR Method"
        case .outline: return "Outline"
        case .plain: return "Plain Text"
        }
    }
}

public enum Confidence: String, Codable, CaseIterable, Identifiable, Sendable {
    case unrated = "unrated"
    case again = "again"
    case good = "good"
    case confident = "confident"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .unrated: return "Unrated"
        case .again: return "Again"
        case .good: return "Good"
        case .confident: return "Confident"
        }
    }

    public var subtitle: String {
        switch self {
        case .unrated: return "Not practiced yet"
        case .again: return "Needs another pass · 1"
        case .good: return "Mostly there · 2"
        case .confident: return "Ready to use · 3"
        }
    }

    public var statusDescription: String {
        switch self {
        case .unrated: return "Not practiced yet"
        case .again: return "Building confidence"
        case .good: return "Getting there"
        case .confident: return "Confident"
        }
    }

    public var color: Color {
        switch self {
        case .unrated: return .secondary.opacity(0.4)
        case .again: return Color(nsColor: .systemRed)
        case .good: return Color(nsColor: .systemYellow)
        case .confident: return Color(nsColor: .systemGreen)
        }
    }

    public var shortcutNumber: Int? {
        switch self {
        case .again: return 1
        case .good: return 2
        case .confident: return 3
        case .unrated: return nil
        }
    }
}
