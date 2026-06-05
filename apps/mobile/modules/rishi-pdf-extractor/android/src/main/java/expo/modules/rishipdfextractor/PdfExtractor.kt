package expo.modules.rishipdfextractor

import android.content.Context
import android.os.ParcelFileDescriptor
import com.shockwave.pdfium.PdfiumCore
import com.shockwave.pdfium.PdfDocument
import com.shockwave.pdfium.util.Size
import java.io.File
import kotlin.math.max
import kotlin.math.min

data class WordRectOut(
  val idx: Int,
  val text: String,
  val x: Double, val y: Double, val w: Double, val h: Double,
)

data class PageDataOut(
  val pageNumber: Int,
  val widthPts: Double,
  val heightPts: Double,
  val paragraphs: List<ParagraphOut>,
  val words: List<WordRectOut>,
)

class PdfExtractor(private val ctx: Context) {

  private fun openDoc(path: String): Pair<PdfiumCore, PdfDocument> {
    val core = PdfiumCore(ctx)
    val fd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
    val doc = core.newDocument(fd)
    return core to doc
  }

  fun getPageCount(path: String): Int {
    val (core, doc) = openDoc(path)
    try {
      return core.getPageCount(doc)
    } finally {
      core.closeDocument(doc)
    }
  }

  fun extractPage(path: String, pageNumber: Int): PageDataOut {
    val (core, doc) = openDoc(path)
    try {
      val idx = pageNumber - 1
      core.openPage(doc, idx)
      val size: Size = core.getPageSize(doc, idx)
      val widthPts = size.width.toDouble()
      val heightPts = size.height.toDouble()

      val textPagePtr = core.openTextPage(doc, idx)
      val charCount = core.textPageCountChars(textPagePtr)

      val lines = mutableListOf<Line>()
      var currentText = StringBuilder()
      var currentMinY = Double.POSITIVE_INFINITY
      var currentMaxY = Double.NEGATIVE_INFINITY
      var prevLineKey = Int.MIN_VALUE

      for (i in 0 until charCount) {
        val unicode = core.textPageGetUnicode(textPagePtr, i)
        // Skip CR/LF — line breaks come from Y-grouping.
        if (unicode == 0x000A || unicode == 0x000D) continue

        val rect = core.textPageGetCharBox(textPagePtr, i)
        // Pdfium reports rects in PDF coords; .top may be greater than .bottom.
        val minY = min(rect.top.toDouble(), rect.bottom.toDouble())
        val maxY = max(rect.top.toDouble(), rect.bottom.toDouble())
        val height = maxY - minY
        // Guard against zero-size rects.
        if (height <= 0) continue

        val midY = (minY + maxY) / 2
        val key = (midY / max(height, 1.0)).toInt()

        if (key != prevLineKey && prevLineKey != Int.MIN_VALUE) {
          if (currentText.isNotEmpty()) {
            lines += Line(
              text = currentText.toString(),
              originY = currentMinY,
              height = max(currentMaxY - currentMinY, 1.0),
            )
          }
          currentText = StringBuilder()
          currentMinY = Double.POSITIVE_INFINITY
          currentMaxY = Double.NEGATIVE_INFINITY
        }
        currentText.append(unicode.toChar())
        currentMinY = min(currentMinY, minY)
        currentMaxY = max(currentMaxY, maxY)
        prevLineKey = key
      }
      if (currentText.isNotEmpty()) {
        lines += Line(
          text = currentText.toString(),
          originY = currentMinY,
          height = max(currentMaxY - currentMinY, 12.0),
        )
      }
      core.closeTextPage(textPagePtr)

      val paragraphs = ParagraphSegmenter.segment(lines, pageNumber)
      return PageDataOut(
        pageNumber = pageNumber,
        widthPts = widthPts,
        heightPts = heightPts,
        paragraphs = paragraphs,
        words = emptyList(),  // filled in Task 7
      )
    } finally {
      core.closeDocument(doc)
    }
  }
}
