package expo.modules.rishipdfextractor

import org.junit.Assert.assertEquals
import org.junit.Test

class ParagraphSegmenterTest {
  @Test
  fun splitsOnVerticalGapGreaterThan1_5x() {
    val lines = listOf(
      Line("First line of para A.", originY = 700.0, height = 12.0),
      Line("Second line of para A.", originY = 685.0, height = 12.0),
      Line("First line of para B.", originY = 640.0, height = 12.0),
    )
    val result = ParagraphSegmenter.segment(lines, pageNumber = 1)
    assertEquals(2, result.size)
    assertEquals("First line of para A. Second line of para A.", result[0].text)
    assertEquals("First line of para B.", result[1].text)
  }

  @Test
  fun splitsAfterFiveLinesEvenWithoutGap() {
    val lines = (0 until 7).map { i ->
      Line("Line $i.", originY = 700.0 - i * 14.0, height = 12.0)
    }
    val result = ParagraphSegmenter.segment(lines, pageNumber = 1)
    assertEquals(2, result.size)
  }

  @Test
  fun assignsDeterministicIndices() {
    val lines = listOf(
      Line("A", originY = 700.0, height = 12.0),
      Line("B", originY = 600.0, height = 12.0),
    )
    val result = ParagraphSegmenter.segment(lines, pageNumber = 3)
    assertEquals("30000", result[0].index)
    assertEquals("30001", result[1].index)
  }
}
