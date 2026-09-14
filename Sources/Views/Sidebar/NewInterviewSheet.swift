import SwiftUI
import SwiftData

public struct NewInterviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Interview.sortIndex) private var interviews: [Interview]

    public var interviewToEdit: Interview?
    public var onCreated: ((Interview) -> Void)?

    @State private var company: String = ""
    @State private var role: String = ""
    @State private var hasDate: Bool = false
    @State private var interviewDate: Date = Date()
    @State private var parentInterviewID: UUID?
    @State private var inheritanceError: String?

    public init(interviewToEdit: Interview? = nil, onCreated: ((Interview) -> Void)? = nil) {
        self.interviewToEdit = interviewToEdit
        self.onCreated = onCreated
        // Seed edit state before the first body evaluation. Initializing this
        // in `onAppear` briefly renders the creation form and can make native
        // Form controls rebuild after their first layout pass.
        _company = State(initialValue: interviewToEdit?.company ?? "")
        _role = State(initialValue: interviewToEdit?.role ?? "")
        _hasDate = State(initialValue: interviewToEdit?.interviewDate != nil)
        _interviewDate = State(initialValue: interviewToEdit?.interviewDate ?? Date())
        _parentInterviewID = State(initialValue: interviewToEdit?.parentInterview?.id)
    }

    public var body: some View {
        VStack(spacing: 20) {
            Text(interviewToEdit == nil ? "Create Interview" : "Edit Interview")
                .font(.system(size: 16, weight: .semibold))

            Form {
                TextField("Company", text: $company)
                    .textFieldStyle(.roundedBorder)

                TextField("Role", text: $role)
                    .textFieldStyle(.roundedBorder)

                Picker(selection: $parentInterviewID) {
                    Text("None").tag(UUID?.none)

                    ForEach(eligibleParentInterviews) { interview in
                        Text(interview.title)
                            .lineLimit(1)
                            .tag(Optional(interview.id))
                    }
                } label: {
                    Text("Inherit questions from")
                        .lineLimit(1)
                }
                .help("Questions and answers from this set appear before this set’s own questions.")
                .accessibilityHint("Inherited questions and answers appear before this set’s own questions.")

                if let inheritanceError {
                    Text(inheritanceError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Inheritance error: \(inheritanceError)")
                }

                Toggle("Include target date", isOn: $hasDate)

                if hasDate {
                    DatePicker("Date", selection: $interviewDate, displayedComponents: [.date])
                }
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(interviewToEdit == nil ? "Create" : "Save") {
                    if saveInterview() {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(company.trimmingCharacters(in: .whitespaces).isEmpty && role.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onChange(of: parentInterviewID) { _, _ in
            inheritanceError = nil
        }
    }

    private var eligibleParentInterviews: [Interview] {
        guard let interviewToEdit else {
            return interviews
        }

        return interviews.filter { candidate in
            interviewToEdit.canInherit(from: candidate)
        }
    }

    @discardableResult
    private func saveInterview() -> Bool {
        let finalCompany = company.trimmingCharacters(in: .whitespaces)
        let finalRole = role.trimmingCharacters(in: .whitespaces)
        let finalDate = hasDate ? interviewDate : nil
        let parentInterview = interviews.first { $0.id == parentInterviewID }

        if let interview = interviewToEdit {
            guard interview.canInherit(from: parentInterview) else {
                inheritanceError = "This set can’t inherit from that source because it would create a cycle."
                return false
            }
            interview.company = finalCompany
            interview.role = finalRole
            interview.interviewDate = finalDate
            interview.parentInterview = parentInterview
            interview.updatedAt = Date()
        } else {
            let newInterview = Interview(
                company: finalCompany,
                role: finalRole,
                interviewDate: finalDate,
                sortIndex: (interviews.map(\.sortIndex).max() ?? -1) + 1
            )
            guard newInterview.canInherit(from: parentInterview) else {
                inheritanceError = "This set can’t inherit from that source because it would create a cycle."
                return false
            }
            modelContext.insert(newInterview)
            newInterview.parentInterview = parentInterview
            AppPreferences.shared.hasCompletedOnboarding = true
            onCreated?(newInterview)
        }
        DataController.shared.flushSave()
        return true
    }
}
