package expo.modules.rishipdfextractor

data class Line(val text: String, val originY: Double, val height: Double)

data class ParagraphOut(val index: String, val text: String)

object ParagraphSegmenter {
  private const val MAX_LINES_PER_PARAGRAPH = 5
  private const val GAP_MULTIPLIER = 1.5

  fun segment(lines: List<Line>, pageNumber: Int): List<ParagraphOut> {
    if (lines.isEmpty()) return emptyList()
    val sorted = lines.sortedByDescending { it.originY }
    val heights = sorted.map { it.height }.sorted()
    val median = if (heights.isEmpty()) 12.0 else heights[heights.size / 2]
    val gapThreshold = median * GAP_MULTIPLIER

    val out = mutableListOf<ParagraphOut>()
    val bucket = mutableListOf<String>()
    var prevY: Double? = null
    var counter = 0

    fun flush() {
      if (bucket.isEmpty()) return
      val index = "${pageNumber * 10000 + counter}"
      out.add(ParagraphOut(index = index, text = bucket.joinToString(" ")))
      bucket.clear()
      counter++
    }

    for (line in sorted) {
      val prev = prevY
      if (prev != null) {
        val gap = prev - (line.originY + line.height)
        if (gap > gapThreshold || bucket.size >= MAX_LINES_PER_PARAGRAPH) {
          flush()
        }
      }
      bucket.add(line.text)
      prevY = line.originY
    }
    flush()
    return out
  }
}
