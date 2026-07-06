// Backend process lifecycle: discover a running server via the session
// handshake file, or spawn `python -m indra.server` and poll for it
// (BUILD_SPEC §4.1 server lifecycle). USER-SMOKE-TESTED ONLY — not
// CI-verifiable; see docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI)

    import Foundation
    import IndraKitCore
    import IndraKitNet
    import Observation

    @MainActor
    @Observable
    final class BackendController {
        enum Status: Equatable {
            case idle
            case launching(String)
            case connected
            case failed(String)
        }

        private(set) var status: Status = .idle
        /// Set once connected; nil otherwise.
        private(set) var client: APIClient?
        /// Session handshake contents (port, token, pid, project). Kept so the
        /// app layer can make raw requests for endpoints APIClient does not
        /// cover yet (POST /export).
        private(set) var session: SessionInfo?

        @ObservationIgnored private var process: Process?
        @ObservationIgnored private let processLog = ProcessLogBuffer()

        static var sessionFileURL: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("Indra", isDirectory: true)
                .appendingPathComponent("session.json")
        }

        static var defaultProjectURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/Indra/scratch.indra")
        }

        /// Connect to an already-running backend if the session file points at
        /// a healthy one; otherwise spawn our own and poll for the handshake.
        func connect() async {
            if case .launching = status { return }
            if case .connected = status, let client, await Self.isHealthy(client) { return }
            status = .launching("Looking for a running backend…")
            if let existing = Self.readSession(),
                let client = Self.makeClient(existing),
                await Self.isHealthy(client)
            {
                adopt(session: existing, client: client)
                return
            }
            await spawnAndPoll()
        }

        /// Terminate a backend we spawned (never one the user started).
        func shutdown() {
            process?.terminate()
            process = nil
        }

        // MARK: - Spawn path

        private func spawnAndPoll() async {
            guard let python = findPython() else {
                status = .failed(
                    """
                    No Python interpreter found and no backend is running. Set the \
                    backend Python path in Settings (⌘,) to your backend virtualenv, \
                    e.g. …/Indra/backend/.venv/bin/python, then press Retry. \
                    Alternatively start the backend yourself:
                    python -m indra.server --project ~/Music/Indra/scratch.indra --port 0
                    """)
                return
            }

            let projectURL = Self.defaultProjectURL
            try? FileManager.default.createDirectory(
                at: projectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A stale handshake from a dead server must not satisfy the poll.
            try? FileManager.default.removeItem(at: Self.sessionFileURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [
                "-m", "indra.server", "--project", projectURL.path, "--port", "0",
            ]
            let pipe = Pipe()
            pipe.fileHandleForReading.readabilityHandler = { [log = processLog] handle in
                log.append(handle.availableData)
            }
            process.standardOutput = pipe
            process.standardError = pipe

            status = .launching("Starting backend: \(python) -m indra.server …")
            do {
                try process.run()
            } catch {
                status = .failed("Could not launch \(python): \(error.localizedDescription)")
                return
            }
            self.process = process

            for _ in 0..<60 {  // ~30 s
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !process.isRunning {
                    status = .failed(
                        "Backend exited during startup (wrong Python? set the venv "
                            + "python in Settings ⌘,).\n\(processLog.tail())")
                    self.process = nil
                    return
                }
                if let session = Self.readSession(),
                    let client = Self.makeClient(session),
                    await Self.isHealthy(client)
                {
                    adopt(session: session, client: client)
                    return
                }
            }
            process.terminate()
            self.process = nil
            status = .failed(
                "Backend never wrote \(Self.sessionFileURL.path) (waited 30 s).\n"
                    + processLog.tail())
        }

        private func adopt(session: SessionInfo, client: APIClient) {
            self.session = session
            self.client = client
            self.status = .connected
        }

        // MARK: - Helpers

        private static func readSession() -> SessionInfo? {
            guard let data = try? Data(contentsOf: sessionFileURL) else { return nil }
            return try? IndraJSON.decoder().decode(SessionInfo.self, from: data)
        }

        private static func makeClient(_ session: SessionInfo) -> APIClient? {
            guard let url = URL(string: "http://127.0.0.1:\(session.port)") else { return nil }
            return APIClient(baseURL: url, token: session.token)
        }

        private static func isHealthy(_ client: APIClient) async -> Bool {
            ((try? await client.health())?.status) == "ok"
        }

        /// Settings override first, then PATH, then common Homebrew locations.
        private func findPython() -> String? {
            let fm = FileManager.default
            let custom = UserDefaults.standard.string(forKey: "indra.backendPython") ?? ""
            if !custom.isEmpty {
                let expanded = NSString(string: custom).expandingTildeInPath
                if fm.isExecutableFile(atPath: expanded) { return expanded }
            }
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            var dirs = path.split(separator: ":").map(String.init)
            dirs.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
            for name in ["python3", "python"] {
                for dir in dirs where fm.isExecutableFile(atPath: "\(dir)/\(name)") {
                    return "\(dir)/\(name)"
                }
            }
            return nil
        }
    }

    /// Collects backend stdout/stderr across threads (pipe readability
    /// handlers run off-main) for failure diagnostics.
    final class ProcessLogBuffer: @unchecked Sendable {
        private var text = ""
        private let lock = NSLock()

        func append(_ data: Data) {
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            text += chunk
            if text.count > 16_384 { text = String(text.suffix(8192)) }
            lock.unlock()
        }

        /// Last ~1.5 KB of backend output, for error messages.
        func tail() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(text.suffix(1500))
        }
    }

#endif
