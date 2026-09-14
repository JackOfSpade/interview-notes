import SwiftUI
import SwiftData

public enum SidebarSelection: Hashable {
    case all
    case interview(UUID)
}

public struct LibrarySidebarView: View {
    @Query(sort: \Interview.sortIndex) private var interviews: [Interview]

    @Binding var selection: SidebarSelection
    @Binding var showNewInterviewSheet: Bool
    public var onEditInterview: (Interview) -> Void
    public var onDeleteInterview: (Interview) -> Void

    public init(
        selection: Binding<SidebarSelection>,
        showNewInterviewSheet: Binding<Bool>,
        onEditInterview: @escaping (Interview) -> Void,
        onDeleteInterview: @escaping (Interview) -> Void
    ) {
        self._selection = selection
        self._showNewInterviewSheet = showNewInterviewSheet
        self.onEditInterview = onEditInterview
        self.onDeleteInterview = onDeleteInterview
    }

    public var body: some View {
        List(selection: $selection) {
                Section {
                    ForEach(interviews) { interview in
                        NavigationLink(value: SidebarSelection.interview(interview.id)) {
                            InterviewRowView(
                                interview: interview,
                                isSelected: selection == .interview(interview.id),
                                onEdit: {
                                    onEditInterview(interview)
                                },
                                onDelete: {
                                    onDeleteInterview(interview)
                                }
                            )
                        }
                    }
                } header: {
                    HStack {
                        Text("Interviews")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showNewInterviewSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add interview")
                        .help("Add interview")
                    }
                }
            }
            .listStyle(.sidebar)
    }
}
