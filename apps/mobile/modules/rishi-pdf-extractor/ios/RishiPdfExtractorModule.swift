import ExpoModulesCore

public class RishiPdfExtractorModule: Module {
  public func definition() -> ModuleDefinition {
    Name("RishiPdfExtractor")

    Function("hello") { () -> String in
      "hello from rishi-pdf-extractor (ios)"
    }

    AsyncFunction("getPageCount") { (path: String) -> Int in
      return try PdfExtractor.getPageCount(path: path)
    }

    AsyncFunction("extractPage") { (path: String, pageNumber: Int) -> [String: Any] in
      let data = try PdfExtractor.extractPage(path: path, pageNumber: pageNumber)
      return [
        "pageNumber": data.pageNumber,
        "widthPts": data.widthPts,
        "heightPts": data.heightPts,
        "paragraphs": data.paragraphs.map { ["index": $0.index, "text": $0.text] },
        "words": [] as [[String: Any]],
      ]
    }
  }
}
