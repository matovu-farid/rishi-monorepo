package expo.modules.rishipdfextractor

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class RishiPdfExtractorModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("RishiPdfExtractor")

    Function("hello") {
      "hello from rishi-pdf-extractor (android)"
    }
  }
}
