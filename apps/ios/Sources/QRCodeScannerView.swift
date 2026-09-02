import SwiftUI
import VisionKit

struct QRCodeScannerView: View {
    let onScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            DataScannerRepresentable { payload in
                onScanned(payload)
                dismiss()
            }.ignoresSafeArea()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.85)).padding(20)
            }.accessibilityLabel("Close").accessibilityIdentifier("pairing.scanner.close")
            // An accessibility container rather than a plain identified view: an identifier on a SwiftUI
            // container replaces the identifier of every element beneath it, which would leave the close
            // control carrying "pairing.scanner" too.
        }.accessibilityElement(children: .contain).accessibilityIdentifier("pairing.scanner")
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScanned: onScanned) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .accurate, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScanned: (String) -> Void
        private var hasScanned = false

        init(onScanned: @escaping (String) -> Void) { self.onScanned = onScanned }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !hasScanned else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    hasScanned = true
                    let captured = payload
                    Task { @MainActor in self.onScanned(captured) }
                    return
                }
            }
        }
    }
}
