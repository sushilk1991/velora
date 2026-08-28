import Foundation
import ImageIO
import Vision

/// Read-only text observed in one exact-window screenshot. A record has no
/// element token or input route, so visual evidence can never authorize an
/// action against an approximate coordinate.
struct CuaVisualTextRecord: Equatable {
    let text: String
    let frame: CGRect
}

enum CuaVisualEvidence {
    /// Base64 expands by one third, so six MiB is the largest PNG that can fit
    /// inside the transport's existing eight MiB response bound.
    private static let maxPNGBytes = 6 << 20

    private static let maxEncodedBytes = ((maxPNGBytes + 2) / 3) * 4
    private static let maxImagePixels = 40_000_000
    private static let pngMIME = "image/png"
    private static let pngType = "public.png"
    private static let replyKey = "_velora_mcp_image_png"
    private static let coordinateScale = 1_000_000.0
    private static let pngSignature: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ]

    /// Copies one sanitized MCP image block beside structured tool output.
    /// Missing images preserve existing calls; ambiguous or malformed image
    /// evidence fails the whole reply closed.
    static func preserve(
        content: Any?, in reply: inout [String: Any]
    ) -> Bool {
        guard reply[replyKey] == nil else { return false }
        guard let content else { return true }
        guard let blocks = content as? [[String: Any]] else { return false }
        let images = blocks.filter { ($0["type"] as? String) == "image" }
        guard !images.isEmpty else { return true }
        guard images.count == 1, let block = images.first,
              (block["mimeType"] as? String) == pngMIME,
              let encoded = block["data"] as? String,
              let png = decodedPNG(encoded) else { return false }

        // Keep only the three MCP fields that were validated. Extra daemon
        // fields must not silently acquire meaning at the trust boundary.
        reply[replyKey] = [
            "type": "image",
            "mimeType": pngMIME,
            "data": png.base64EncodedString(),
        ]
        return true
    }

    static func pngData(from reply: [String: Any]) -> Data? {
        guard let block = reply[replyKey] as? [String: Any],
              block.count == 3,
              (block["type"] as? String) == "image",
              (block["mimeType"] as? String) == pngMIME,
              let encoded = block["data"] as? String else { return nil }
        return decodedPNG(encoded)
    }

    /// Runs Apple's local recognizer over the bounded screenshot. Frames use
    /// normalized top-left geometry, quantized so equal images produce stable
    /// records across serialization without exposing click authority.
    static func readText(in png: Data) -> [CuaVisualTextRecord] {
        guard let image = image(from: png) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(
            cgImage: image, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }

        var records: [CuaVisualTextRecord] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence > 0 else { continue }
            let text = candidate.string.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let frame = stableFrame(observation.boundingBox)
            else { continue }
            records.append(CuaVisualTextRecord(text: text, frame: frame))
        }
        return records.sorted(by: recordBefore)
    }

    private static func decodedPNG(_ encoded: String) -> Data? {
        guard encoded.utf8.count <= maxEncodedBytes,
              let data = Data(base64Encoded: encoded),
              data.count <= maxPNGBytes,
              imageSource(for: data) != nil else { return nil }
        return data
    }

    private static func image(from data: Data) -> CGImage? {
        guard data.count <= maxPNGBytes,
              let source = imageSource(for: data) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func imageSource(for data: Data) -> CGImageSource? {
        guard data.count >= pngSignature.count,
              Array(data.prefix(pngSignature.count)) == pngSignature,
              let source = CGImageSourceCreateWithData(
                data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == pngType,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth]
                as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight]
                as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxImagePixels else { return nil }
        return source
    }

    private static func stableFrame(_ raw: CGRect) -> CGRect? {
        let minX = quantize(clamp(raw.minX))
        let maxX = quantize(clamp(raw.maxX))
        let minY = quantize(clamp(1 - raw.maxY))
        let maxY = quantize(clamp(1 - raw.minY))
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(
            x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        Swift.max(0, Swift.min(1, value))
    }

    private static func quantize(_ value: CGFloat) -> CGFloat {
        (value * coordinateScale).rounded() / coordinateScale
    }

    private static func recordBefore(
        _ lhs: CuaVisualTextRecord, _ rhs: CuaVisualTextRecord
    ) -> Bool {
        if lhs.frame.minY != rhs.frame.minY {
            return lhs.frame.minY < rhs.frame.minY
        }
        if lhs.frame.minX != rhs.frame.minX {
            return lhs.frame.minX < rhs.frame.minX
        }
        return lhs.text < rhs.text
    }
}
