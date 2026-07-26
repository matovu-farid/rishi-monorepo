import Foundation
import PDFKit


#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders page 1 of a PDF to a PNG thumbnail.
///
/// Per `PITFALLS.md` Pitfall 5, PDFKit's view-layer thumbnail caches the
/// ENTIRE document — we explicitly render a single page on a background
/// task wrapped in `autoreleasepool` to keep peak memory bounded.
public struct PDFKitCoverExtractor: CoverExtractor {
    /// Target render size for the cover thumbnail. The library grid uses a
    /// 140pt-wide tile; 600x800 gives ~4x retina headroom for the largest
    /// supported display.
    public let targetSize: CGSize

    public init(targetSize: CGSize = CGSize(width: 600, height: 800)) {
        self.targetSize = targetSize
    }

    public func extractCover(from fileURL: URL) async -> Data? {
        let size = targetSize
        return await Task.detached(priority: .utility) {
            autoreleasepool {
                guard let doc = PDFDocument(url: fileURL),
                      let page = doc.page(at: 0) else {
                    Log.event(
                        "cover.extract.pdf.failed",
                        level: .info,
                        data: ["reason": "no_page_zero", "url": fileURL.lastPathComponent]
                    )
                    return Data?.none
                }
                #if canImport(UIKit)
                let image = page.thumbnail(of: size, for: .mediaBox)
                guard let data = image.pngData() else {
                    Log.event(
                        "cover.extract.pdf.failed",
                        level: .info,
                        data: ["reason": "png_encode_failed", "url": fileURL.lastPathComponent]
                    )
                    return Data?.none
                }
                return data
                #elseif canImport(AppKit)
                let image = page.thumbnail(of: size, for: .mediaBox)
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    Log.event(
                        "cover.extract.pdf.failed",
                        level: .info,
                        data: ["reason": "png_encode_failed", "url": fileURL.lastPathComponent]
                    )
                    return Data?.none
                }
                return png
                #else
                return Data?.none
                #endif
            }
        }.value
    }
}
