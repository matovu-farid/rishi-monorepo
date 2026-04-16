import {
  IReactReaderStyle,
  ReactReaderStyle,
} from "@components/react-reader/style";
import { ReaderTheme } from "./commonReader";

export default function createIReactReaderTheme(
  theme: ReaderTheme
): IReactReaderStyle {
  return {
    ...ReactReaderStyle,
    arrow: {
      ...ReactReaderStyle.arrow,
      color: theme.arrowColor,
      padding: "0px 5px",
      borderRadius: "10px",
      opacity: "0.3",
    },
    arrowHover: {
      ...ReactReaderStyle.arrowHover,
      color: theme.arrowColor,
    },
    readerArea: {
      ...ReactReaderStyle.readerArea,
      backgroundColor: theme.background,
    },
    titleArea: {
      ...ReactReaderStyle.titleArea,
      color: theme.color,
      // Reserve space on the right for the top-right action bar rendered above
      // the reader in epub.tsx (BackButton, Highlighter, Chat, Settings, Palette).
      // The button bar is ~260px wide; without this reservation the centered
      // title overlaps them — especially when the TOC is expanded, because
      // readerArea is shifted with translateX(256px) while the buttons are not.
      right: 260,
      // Truncate extremely long titles instead of wrapping into the button zone.
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis",
    },
    tocArea: {
      ...ReactReaderStyle.tocArea,
      background: theme.background,
    },
    tocButtonExpanded: {
      ...ReactReaderStyle.tocButtonExpanded,
      background: theme.background,
    },
    tocButtonBar: {
      ...ReactReaderStyle.tocButtonBar,
      background: theme.color,
    },
    tocButton: {
      ...ReactReaderStyle.tocButton,
      color: theme.color,
    },
    toc: {
      ...ReactReaderStyle.toc,
      color: theme.color,
    },
  };
}
