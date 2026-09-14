import SwiftUI

public struct QuestionRowView: View {
    public var question: Question
    public var isSelected: Bool
    public var inheritedFrom: Interview?

    public init(
        question: Question,
        isSelected: Bool,
        inheritedFrom: Interview? = nil
    ) {
        self.question = question
        self.isSelected = isSelected
        self.inheritedFrom = inheritedFrom
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Text(question.prompt.isEmpty ? "Untitled Question" : question.prompt)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(question.prompt.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }

            if let inheritedFrom {
                Label("From \(inheritedFrom.title)", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
