import SwiftUI

public struct InterviewRowView: View {
    @Bindable var interview: Interview
    public var isSelected: Bool
    public var onEdit: () -> Void
    public var onDelete: () -> Void

    public init(
        interview: Interview,
        isSelected: Bool,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.interview = interview
        self.isSelected = isSelected
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "briefcase")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(interview.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let parentInterview = interview.parentInterview {
                    Label("Inherits from \(parentInterview.title)", systemImage: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if !interview.childInterviews.isEmpty {
                    Label(sharedWithText, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer()

        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit Interview…") {
                onEdit()
            }
            Divider()
            Button("Delete Interview", role: .destructive) {
                onDelete()
            }
        }
    }

    private var sharedWithText: String {
        let count = interview.childInterviews.count
        return count == 1 ? "Shared with 1 set" : "Shared with \(count) sets"
    }
}
