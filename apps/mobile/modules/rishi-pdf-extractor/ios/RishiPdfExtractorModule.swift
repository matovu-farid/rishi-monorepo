import ExpoModulesCore

public class RishiPdfExtractorModule: Module {
  public func definition() -> ModuleDefinition {
    Name("RishiPdfExtractor")

    Function("hello") { () -> String in
      "hello from rishi-pdf-extractor (ios)"
    }
  }
}
