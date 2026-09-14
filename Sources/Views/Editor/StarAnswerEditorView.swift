import SwiftUI

public struct StarAnswerEditorView: View {
    @Binding var situation: String?
    @Binding var task: String?
    @Binding var action: String?
    @Binding var result: String?
    public var onEdit: () -> Void

    public init(
        situation: Binding<String?>,
        task: Binding<String?>,
        action: Binding<String?>,
        result: Binding<String?>,
        onEdit: @escaping () -> Void
    ) {
        self._situation = situation
        self._task = task
        self._action = action
        self._result = result
        self.onEdit = onEdit
    }

    public var body: some View {
        VStack(spacing: 12) {
            starSection(
                title: "Situation",
                prompt: "Set the context and problem you were addressing…",
                binding: Binding(
                    get: { situation ?? "" },
                    set: { situation = $0; onEdit() }
                )
            )

            starSection(
                title: "Task",
                prompt: "What was your specific responsibility or goal…",
                binding: Binding(
                    get: { task ?? "" },
                    set: { task = $0; onEdit() }
                )
            )

            starSection(
                title: "Action",
                prompt: "What concrete steps did you take and why…",
                binding: Binding(
                    get: { action ?? "" },
                    set: { action = $0; onEdit() }
                )
            )

            starSection(
                title: "Result",
                prompt: "What was the outcome, business impact, or lesson…",
                binding: Binding(
                    get: { result ?? "" },
                    set: { result = $0; onEdit() }
                )
            )
        }
    }

    private func starSection(
        title: String,
        prompt: String,
        binding: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TextField(prompt, text: binding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
