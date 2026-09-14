import SwiftUI

public struct TalkingPointsEditorView: View {
    @Binding var talkingPoints: [String]
    public var isReadOnly: Bool
    public var onEdit: () -> Void

    @State private var cueIDs: [UUID]
    @State private var previousTalkingPoints: [String]
    @FocusState private var focusedCueID: UUID?

    private struct CueRow: Identifiable {
        let id: UUID
        let index: Int
    }

    public init(
        talkingPoints: Binding<[String]>,
        isReadOnly: Bool = false,
        onEdit: @escaping () -> Void
    ) {
        self._talkingPoints = talkingPoints
        self.isReadOnly = isReadOnly
        self.onEdit = onEdit
        self._cueIDs = State(initialValue: talkingPoints.wrappedValue.map { _ in UUID() })
        self._previousTalkingPoints = State(initialValue: talkingPoints.wrappedValue)
    }

    private var cueRows: [CueRow] {
        zip(cueIDs, talkingPoints.indices).map { CueRow(id: $0.0, index: $0.1) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Talking points")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !isReadOnly {
                    Button {
                        addPoint()
                    } label: {
                        Label("Add cue", systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Add a talking point cue")
                }
            }

            if talkingPoints.isEmpty {
                HStack {
                    Text("No talking points yet. Add 3–5 short recall cues.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    if !isReadOnly {
                        Spacer()
                        Button("Add first cue") {
                            addPoint()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                    }
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(cueRows) { row in
                        let index = row.index
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                                .padding(.top, 4)

                            TextField("Recall cue", text: Binding(
                                get: { talkingPoints[index] },
                                set: { newValue in
                                    // Keep the reconciliation snapshot in step
                                    // with an in-place edit; the row's UUID must
                                    // not change for every keystroke.
                                    if !previousTalkingPoints.indices.contains(index) {
                                        previousTalkingPoints = talkingPoints
                                    }
                                    previousTalkingPoints[index] = newValue
                                    talkingPoints[index] = newValue
                                    onEdit()
                                }
                            ), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focusedCueID, equals: row.id)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            if !isReadOnly {
                                Button {
                                    removePoint(row)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 6)
                                .accessibilityLabel("Remove cue \(index + 1)")
                                .help("Remove cue")
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            synchronizeCueIDs(with: talkingPoints)
        }
        .onChange(of: talkingPoints) { _, newPoints in
            synchronizeCueIDs(with: newPoints)
        }
    }

    private func addPoint() {
        let id = UUID()
        cueIDs.append(id)
        previousTalkingPoints.append("")
        talkingPoints.append("")
        focusedCueID = id
        onEdit()
    }

    private func removePoint(_ row: CueRow) {
        guard talkingPoints.indices.contains(row.index), cueIDs.indices.contains(row.index) else { return }

        cueIDs.remove(at: row.index)
        previousTalkingPoints.remove(at: row.index)
        talkingPoints.remove(at: row.index)
        if focusedCueID == row.id {
            focusedCueID = cueIDs.indices.contains(row.index) ? cueIDs[row.index] : cueIDs.last
        }
        onEdit()
    }

    /// Reconcile parent-driven updates without assigning identity from the cue
    /// text itself. This preserves row/focus identity through external inserts,
    /// removals, and moves, including lists containing duplicate strings.
    private func synchronizeCueIDs(with newPoints: [String]) {
        defer { previousTalkingPoints = newPoints }

        guard cueIDs.count == previousTalkingPoints.count else {
            cueIDs = newPoints.map { _ in UUID() }
            focusedCueID = nil
            return
        }

        let changes = newPoints.difference(from: previousTalkingPoints).inferringMoves()
        var removedIDs: [Int: UUID] = [:]
        var removals: [(offset: Int, associatedWith: Int?)] = []
        var insertions: [(offset: Int, associatedWith: Int?)] = []

        for change in changes {
            switch change {
            case let .remove(offset, _, associatedWith):
                removals.append((offset, associatedWith))
            case let .insert(offset, _, associatedWith):
                insertions.append((offset, associatedWith))
            }
        }

        for removal in removals.sorted(by: { $0.offset > $1.offset }) {
            guard cueIDs.indices.contains(removal.offset) else { continue }
            removedIDs[removal.offset] = cueIDs.remove(at: removal.offset)
        }

        for insertion in insertions.sorted(by: { $0.offset < $1.offset }) {
            let id = insertion.associatedWith.flatMap { removedIDs[$0] } ?? UUID()
            cueIDs.insert(id, at: min(insertion.offset, cueIDs.count))
        }

        if let focusedCueID, !cueIDs.contains(focusedCueID) {
            self.focusedCueID = nil
        }
    }
}
