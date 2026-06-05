package expo.modules.rishipdfextractor

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class RishiPdfExtractorModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("RishiPdfExtractor")

    Function("hello") { -> "hello from rishi-pdf-extractor (android)" }

    AsyncFunction("getPageCount") { path: String ->
      PdfExtractor(appContext.reactContext!!).getPageCount(path)
    }

    AsyncFunction("extractPage") { path: String, pageNumber: Int ->
      val out = PdfExtractor(appContext.reactContext!!).extractPage(path, pageNumber)
      mapOf(
        "pageNumber" to out.pageNumber,
        "widthPts" to out.widthPts,
        "heightPts" to out.heightPts,
        "paragraphs" to out.paragraphs.map { mapOf("index" to it.index, "text" to it.text) },
        "words" to out.words.map {
          mapOf(
            "idx" to it.idx,
            "text" to it.text,
            "x" to it.x, "y" to it.y, "w" to it.w, "h" to it.h,
          )
        },
      )
    }
  }
}
