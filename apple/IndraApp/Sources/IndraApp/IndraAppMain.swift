// IndraApp entry point: @main SwiftUI App + Settings + Edit-menu undo/redo
// (BUILD_SPEC §5.2, §5.7). USER-SMOKE-TESTED ONLY — this target cannot be
// compiled or run in the headless dev environment (no macOS SDK); verify
// locally per docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI)

    import AppKit
    import Combine
    import SwiftUI

    @main
    struct IndraDebugApp: App {
        @State private var model = AppModel()

        var body: some Scene {
            WindowGroup("Indra (debug harness)") {
                ContentView()
                    .environment(model)
                    .frame(minWidth: 960, minHeight: 640)
                    .task {
                        // SwiftPM executables have no app bundle; make sure we
                        // get a Dock icon, menu bar, and key window anyway.
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        await model.start()
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSApplication.willTerminateNotification)
                    ) { _ in
                        model.backend.shutdown()
                    }
            }
            .commands {
                // store.undo()/redo() already route annotation-scoped steps to
                // POST /undo / /redo (DocumentStore, BUILD_SPEC §5.7, §7.2).
                CommandGroup(replacing: .undoRedo) {
                    Button(model.undoMenuTitle) { model.undo() }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(!model.canUndo)
                    Button(model.redoMenuTitle) { model.redo() }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                        .disabled(!model.canRedo)
                }
            }

            Settings {
                SettingsView()
            }
        }
    }

    struct SettingsView: View {
        @AppStorage("indra.backendPython") private var backendPython = ""

        var body: some View {
            Form {
                TextField(
                    "Backend Python", text: $backendPython,
                    prompt: Text("…/Indra/backend/.venv/bin/python"))
                Text(
                    """
                    Used to spawn `python -m indra.server` when no backend is already \
                    running. Point this at the virtualenv Python that has the indra \
                    backend installed (backend/.venv/bin/python). If empty, the app \
                    searches PATH for python3/python — a bare system Python will fail \
                    because it lacks the indra package. Press Retry in the main window \
                    after changing this.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: 540)
        }
    }

#else

    // Keeps the executable target buildable on Linux CI (structural check
    // only). Exactly one @main exists per build configuration.
    @main
    struct IndraAppStub {
        static func main() {
            print("IndraApp is a macOS SwiftUI application; nothing to run on this platform.")
        }
    }

#endif
