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
