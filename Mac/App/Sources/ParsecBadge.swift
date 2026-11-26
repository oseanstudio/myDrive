import AppKit
import ScreenCaptureKit
import Vision

enum ParsecBadge {
    /// Accept one fresh badge for a known, exact Blip recipient.
    static func match(_ values: [String], owner: String, recipients: [String], now: Date = .now) -> String? {
        guard BlipPolicy.exactPeer(owner) else { return nil }
        let current = Int64(now.timeIntervalSince1970) / 30
        let peers = Set(values.compactMap { value -> String? in
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0] == "mydrive-parsec-v1",
                  let account = uuid(fields[1]), let device = uuid(fields[2]),
                  let interval = Int64(fields[3]), (current - 2...current + 1).contains(interval) else { return nil }
            return account.uuidString.lowercased() + ":" + device.uuidString.lowercased()
        })
        guard peers.count == 1, let peer = peers.first, peer != owner.lowercased(),
              recipients.contains(where: { $0.lowercased() == peer }) else { return nil }
        return peer
    }

    private static func uuid(_ hex: Substring) -> UUID? {
        guard hex.utf8.count == 32,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let bytes = Array(hex.utf8)
        let blocks = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return UUID(uuidString: blocks.map { String(decoding: bytes[$0], as: UTF8.self) }.joined(separator: "-"))
    }

    /// Capture the hovered Parsec window once. Keep pixels and barcode values in memory only.
    static func capture(window id: CGWindowID, process: pid_t) async -> [String] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard !Task.isCancelled,
                  let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == process }),
                  window.frame.width >= 1, window.frame.height >= 1 else { return [] }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = min(CGFloat(filter.pointPixelScale), 4096 / max(window.frame.width, window.frame.height))
            let settings = SCStreamConfiguration()
            settings.width = max(1, Int(window.frame.width * scale))
            settings.height = max(1, Int(window.frame.height * scale))
            settings.showsCursor = false
            settings.ignoreShadowsSingleWindow = true
            let picture = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: settings)
            guard !Task.isCancelled else { return [] }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: picture).perform([request])
            return request.results?.compactMap(\.payloadStringValue) ?? []
        } catch { return [] }
    }
}
