import {
  Paragraph,
} from "@components/pdf/atoms/paragraph-atoms";
import { useAtomValue } from "jotai";
import type { TextContent } from "react-pdf";
import type { TextMarkedContent } from "pdfjs-dist/types/src/display/api";

import { TextItem } from "pdfjs-dist/types/src/display/api";

import { getParagraphThreshold } from "../utils/getParagraphThreshold";

const MIN_PARAGRAPH_LENGTH = 50;

const PARAGRAPH_INDEX_PER_PAGE = 10000;
// export function getPageParagraphs(pageNumber: number): Paragraph[] {
//   const pageData = useAtomValue(pageNumberToPageDataAtom);
//   return pageDataToParagraphs(pageNumber, pageData[pageNumber]);
// }

export function pageDataToParagraphs(
  pageNumber: number,
  pageData: TextContent
): Paragraph[] {
  const defaultDimensions = {
    bottom: Number.MAX_SAFE_INTEGER,
    top: Number.MIN_SAFE_INTEGER,
  };
  let paragraphsSoFarArray: Paragraph[] = [];

  // Reset arrays for this page parse
  let paragraghSoFar = {
    index: "",
    text: "",
    dimensions: defaultDimensions,
  };

  const items = pageData.items;
  function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
    return "str" in item;
  }

  let previousItem: TextItem | null = null;
  let lineCount = 0;
  for (let item of items) {
    if (!isTextItem(item)) continue;

    const text = item.str;
    let textSoFar = paragraghSoFar.text || "";

    const isVerticallySpaced =
      previousItem &&
      Math.abs(previousItem.transform[5] - item.transform[5]) >
        getParagraphThreshold(item) &&
      item.hasEOL;
    const isThereText = textSoFar.trim().length > 0;

    const hasAtlestFiveLines = lineCount >= 5 && item.hasEOL;

    if ((isVerticallySpaced && isThereText) || hasAtlestFiveLines) {
      if (hasAtlestFiveLines) {
        lineCount = 0;
      }
      paragraphsSoFarArray.push(paragraghSoFar);
      // Calculate index AFTER push, so it's incremented correctly
      const currentIdx = paragraphsSoFarArray.length;
      const pargraphIdx = (
        pageNumber * PARAGRAPH_INDEX_PER_PAGE +
        currentIdx
      ).toString();
      // reset the paragraph so far
      paragraghSoFar = {
        index: pargraphIdx,
        text: "",
        dimensions: defaultDimensions,
      };
    }
    previousItem = item;

    // Calculate index on each iteration for the accumulating paragraph
    const currentIdx = paragraphsSoFarArray.length;
    const pargraphIdx = (
      pageNumber * PARAGRAPH_INDEX_PER_PAGE +
      currentIdx
    ).toString();

    paragraghSoFar = {
      index: pargraphIdx,
      text: paragraghSoFar.text + text,
      dimensions: {
        top: Math.max(item.transform[5], paragraghSoFar.dimensions.top),
        bottom: Math.min(
          // item.transform[5] - item.height,
          item.transform[5],
          paragraghSoFar.dimensions.bottom
        ),
      },
    };
    if (item.hasEOL) {
      lineCount++;
    }
  }

  paragraphsSoFarArray.push(paragraghSoFar);

  paragraphsSoFarArray = paragraphsSoFarArray
    .filter((paragraph) => paragraph.text.trim().length > 0)
    // try best effort to remove headers
    .filter(
      (paragraph, index) =>
        index !== 0 || paragraph.text.trim().length > MIN_PARAGRAPH_LENGTH
    )

    // remove paragraphs that are too short
    .reduce<Paragraph[]>((acc, paragraph) => {
      const isParagraphTooShort =
        paragraph.text.trim().length < MIN_PARAGRAPH_LENGTH;
      // if the paragraph is not too short, add it to the accumulator
      if (!isParagraphTooShort) {
        acc.push(paragraph);
        return acc;
      }

      const lastParagraph = acc.pop();
      // if there is no last paragraph, add the paragraph to the accumulator
      if (!lastParagraph) {
        acc.push(paragraph);
        return acc;
      }
      // merge the paragraph with the last paragraph
      lastParagraph.text = lastParagraph.text + "\n" + paragraph.text;
      lastParagraph.dimensions = {
        top: Math.max(paragraph.dimensions.top, lastParagraph.dimensions.top),
        bottom: Math.min(
          paragraph.dimensions.bottom,
          lastParagraph.dimensions.bottom
        ),
      };
      acc.push(lastParagraph);

      return acc;
    }, []);
  return paragraphsSoFarArray;
}
