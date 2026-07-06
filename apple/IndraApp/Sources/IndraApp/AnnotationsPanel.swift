// Annotations table: add (t0/t1/label fields), inline note editing, delete —
// all routed through DocumentStore.dispatch so undo/redo and backend sync
// follow BUILD_SPEC §5.7/§7.2. USER-SMOKE-TESTED ONLY — not CI-verifiable;
// see docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI)

    import IndraKitCore
    import SwiftUI

    @MainActor
    struct AnnotationsPanel: View {
        let file: AudioFile
        @Environment(AppModel.self) private var model
        @State private var t0Text = ""
        @State private var t1Text = ""
        @State private var labelText = ""

        var body: some View {
            GroupBox("Annotations") {
                VStack(alignment: .leading, spacing: 8) {
                    addRow

                    if model.editor.annotations.isEmpty {
                        Text("No annotations yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        List {
                            ForEach(model.editor.annotations) { annotation in
                                AnnotationRow(annotation: annotation)
                            }
                        }
                        .frame(height: min(
                            CGFloat(model.editor.annotations.count) * 32 + 16, 220))
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private var addRow: some View {
            HStack(spacing: 8) {
                TextField("t0 (s)", text: $t0Text)
                    .frame(width: 76)
                TextField("t1 (s)", text: $t1Text)
                    .frame(width: 76)
                TextField("label", text: $labelText)
                    .frame(width: 160)
                Button("Add") {
                    guard let t0 = Double(t0Text), let t1 = Double(t1Text) else { return }
                    model.addAnnotation(t0: t0, t1: t1, label: labelText)
                    labelText = ""
                }
                .disabled(Double(t0Text) == nil || Double(t1Text) == nil)
                Spacer()
                Button("Reload from server") {
                    Task { await model.reloadAnnotations() }
                }
                .help(
                    "Re-fetch annotations so new rows carry server ids (needed before "
                        + "note edits sync). Clears local undo history.")
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    @MainActor
    struct AnnotationRow: View {
        let annotation: Annotation
        @Environment(AppModel.self) private var model
        @State private var note: String

        init(annotation: Annotation) {
            self.annotation = annotation
            _note = State(initialValue: annotation.note ?? "")
        }

        var body: some View {
            HStack(spacing: 8) {
                Text(String(format: "%.2f–%.2f s", annotation.t0, annotation.t1))
                    .monospacedDigit()
                    .frame(width: 150, alignment: .leading)
                Text(annotation.label ?? "—")
                    .bold()
                    .frame(width: 120, alignment: .leading)
                    .lineLimit(1)
                TextField("note", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        var updated = annotation
                        updated.note = note.isEmpty ? nil : note
                        model.dispatch(.updateAnnotation(updated))
                    }
                if Int(annotation.id) == nil {
                    Text("unsynced")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(
                            "Created this session; press “Reload from server” to pick "
                                + "up its server id so edits/deletes sync.")
                }
                Button(role: .destructive) {
                    model.dispatch(.deleteAnnotation(id: annotation.id))
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete annotation")
            }
            // Keep the local field in step with undo/redo of note edits.
            .onChange(of: annotation.note) { _, newValue in
                note = newValue ?? ""
            }
        }
    }

#endif
