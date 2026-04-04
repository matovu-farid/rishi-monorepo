import { TextItem } from "pdfjs-dist/types/src/display/api";

export const getParagraphThreshold = (item: TextItem): number => {
    // If height is available, use 1.5x the height
    if ("height" in item && typeof item.height === "number" && item.height > 0) {
      return item.height * 1.5;
    }
    // Fallback to dynamic calculation or default
    return 12;
  };