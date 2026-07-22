import Foundation
import spacesterminalcore
import workspacecore

/// Reconciles ad-hoc foreground coding-agent classifications when a terminal's
/// runtime state changes (the foreground process is part of runtime state).
///
/// The daemon hosts the terminal session cores, which post
/// `.spacesTerminalRuntimeStateDidChange` in-process on a runtime-state change, so
/// this classification — device-runtime work — runs in `spacesd` rather than the
/// thin-client GUI. The reconcile writes through `SQLiteStore`, so the GUI sidebar
/// and remote overview refresh on `databaseDidChange`.
///
/// Foreground changes can arrive faster than a reconcile completes, so events that
/// land mid-flight collapse into a single trailing re-run.
@MainActor final class TerminalForegroundAgentReconciler {
    private let databasePath: String
    private let onError: (@Sendable (any Error) -> Void)?
    private var observer: NSObjectProtocol?
    private var inFlight = false
    private var pending = false

    init(databasePath: String, onError: (@Sendable (any Error) -> Void)? = nil) {
        self.databasePath = databasePath
        self.onError = onError
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .spacesTerminalRuntimeStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    private func reconcile() {
        guard !inFlight else {
            pending = true
            return
        }
        inFlight = true
        let databasePath = databasePath
        let onError = onError
        Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.pending = false
                await Task.detached(priority: .utility) {
                    do {
                        let store = try SQLiteStore(path: databasePath)
                        _ = try await WorkspaceOrchestrator(store: store).reconcileTerminalForegroundAgentClassifications()
                    } catch { onError?(error) }
                }.value
            } while self.pending
            self.inFlight = false
        }
    }
}
