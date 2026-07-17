import QuickLook
import SwiftUI
import UIKit
import spacesterminalcore

/// Identifies a captured screenshot awaiting markup. Carries the temp-file URL the QuickLook Markup
/// editor annotates in place and the browser session title used as the staged screenshot's provenance.
struct ScreenshotMarkupItem: Identifiable {
    let id = UUID()
    let fileURL: URL
    let sourceTitle: String
}

/// How a Markup pass over a captured screenshot ended: staged into the single-slot store, or rejected
/// (e.g. annotations grew the PNG past the shared size cap). Either way the temp file is already gone.
enum ScreenshotMarkupOutcome {
    case staged
    case failed(message: String)
}

/// Presents the system QuickLook Markup editor full screen over a freshly captured browser screenshot.
///
/// `QLPreviewController` only shows its native chrome — the Done button and the markup pencil — when it
/// is the root of its own presentation. Embedding it inside SwiftUI navigation suppresses that chrome and
/// loses the edit affordance entirely, so this representable (shown via `.fullScreenCover`) is just a
/// bridge: a bare container view controller that, once on screen, presents the `QLPreviewController`
/// modally with `present(_:animated:)`.
///
/// Flow: the editor is configured with `.updateContents`, so tapping QuickLook's Done flushes annotations
/// back into `item.fileURL` in place. Dismissing the preview — Done or swipe — always stages whatever
/// bytes are on disk (annotated or original; the single-slot store is replaceable and composer attach is
/// explicit, so auto-staging on dismiss is the whole confirmation step). The bytes are re-validated first
/// because markup can grow a PNG past the size cap. `onFinished` then reports the outcome so the browser
/// view can show its toast and tear down the cover.
struct ScreenshotMarkupPresenter: UIViewControllerRepresentable {
    let item: ScreenshotMarkupItem
    let stagedScreenshots: StagedScreenshotStore
    let onFinished: @MainActor (ScreenshotMarkupOutcome) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(item: item, stagedScreenshots: stagedScreenshots, onFinished: onFinished) }

    func makeUIViewController(context: Context) -> ScreenshotMarkupHostViewController {
        ScreenshotMarkupHostViewController(coordinator: context.coordinator)
    }

    func updateUIViewController(_ controller: ScreenshotMarkupHostViewController, context: Context) {}

    // `QLPreviewControllerDataSource` is main-actor-isolated in the SDK (`NS_SWIFT_UI_ACTOR`), which
    // infers `@MainActor` for this class — the same isolation `TerminalQuickLookPreview.Coordinator`
    // gets. `QLPreviewControllerDelegate` is not actor-isolated, so its conformance needs
    // `@preconcurrency` to let the main-actor witnesses satisfy it; QuickLook only calls the delegate
    // on the main thread.
    final class Coordinator: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
        private let item: ScreenshotMarkupItem
        private let stagedScreenshots: StagedScreenshotStore
        private let onFinished: @MainActor (ScreenshotMarkupOutcome) -> Void

        init(item: ScreenshotMarkupItem, stagedScreenshots: StagedScreenshotStore, onFinished: @escaping @MainActor (ScreenshotMarkupOutcome) -> Void)
        {
            self.item = item
            self.stagedScreenshots = stagedScreenshots
            self.onFinished = onFinished
        }

        func makePreviewController() -> QLPreviewController {
            let controller = QLPreviewController()
            controller.dataSource = self
            controller.delegate = self
            return controller
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item.fileURL as NSURL }

        /// `.updateContents` makes the system Markup editor write annotations back into the temp-file URL
        /// in place, so re-reading it after dismissal yields the annotated PNG with no copy bookkeeping.
        /// The unannotated case needs no special handling — the original bytes stay on disk.
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode {
            .updateContents
        }

        /// Fires for both Done and swipe-down, making it the single stage-on-dismiss point.
        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            defer { try? FileManager.default.removeItem(at: item.fileURL) }
            do {
                let data = try Data(contentsOf: item.fileURL)
                let screenshot = try ScreenshotStager.makeStagedScreenshot(pngData: data, sourceTitle: item.sourceTitle, capturedAt: .now)
                stagedScreenshots.stage(screenshot)
                onFinished(.staged)
            } catch { onFinished(.failed(message: Self.errorMessage(for: error))) }
        }

        private static func errorMessage(for error: Error) -> String {
            if case TerminalImageAttachmentValidationError.imageTooLarge = error { return "Screenshot is too large after markup." }
            return "Couldn't stage this screenshot."
        }
    }
}

/// Bare container that hands the screen to `QLPreviewController` as soon as it appears, so QuickLook is
/// the root of its own modal presentation and shows its native chrome. Itself just a dark backdrop that
/// is only briefly visible around the preview's presentation and dismissal animations; the coordinator's
/// dismiss callback tears down the enclosing `.fullScreenCover`, so it never lingers on screen.
final class ScreenshotMarkupHostViewController: UIViewController {
    private let coordinator: ScreenshotMarkupPresenter.Coordinator
    private var hasPresentedPreview = false

    init(coordinator: ScreenshotMarkupPresenter.Coordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("ScreenshotMarkupHostViewController is created in code only.") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // viewDidAppear fires again when the preview dismisses (just before the cover itself is torn
        // down), so present exactly once.
        guard !hasPresentedPreview else { return }
        hasPresentedPreview = true
        present(coordinator.makePreviewController(), animated: true)
    }
}
