import EventEmitter from "eventemitter3";

export type ParagraphWithIndex = {
  text: string;
  index: string;
};
export enum PlayerControlEvent {
  PARAGRAPH_HIGHLIGHTED = "paragraphHighlighted",
  PARAGRAPH_UNHIGHLIGHTED = "paragraphUnhighlighted",
  PAGE_CHANGED = "pageChanged",
  NEW_PARAGRAPHS_AVAILABLE = "newParagraphsAvailable",
  NEXT_VIEW_PARAGRAPHS_AVAILABLE = "nextViewParagraphsAvailable",
  PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE = "previousViewParagraphsAvailable",
  REMOVE_HIGHLIGHT = "removeHighlight",
  MOVE_TO_NEXT_PAGE = "moveToNextPage",
  MOVE_TO_PREVIOUS_PAGE = "moveToPreviousPage",
  HIGHLIGHT_PARAGRAPH = "highlightParagraph",
}
export type PlayerControlEventMap = {
  [PlayerControlEvent.PARAGRAPH_HIGHLIGHTED]: [ParagraphWithIndex];
  [PlayerControlEvent.PARAGRAPH_UNHIGHLIGHTED]: [ParagraphWithIndex];
  [PlayerControlEvent.PAGE_CHANGED]: [void];
  [PlayerControlEvent.NEW_PARAGRAPHS_AVAILABLE]: [ParagraphWithIndex[]];
  [PlayerControlEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE]: [ParagraphWithIndex[]];
  [PlayerControlEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE]: [
    ParagraphWithIndex[],
  ];
  [PlayerControlEvent.HIGHLIGHT_PARAGRAPH]: [string];
  [PlayerControlEvent.REMOVE_HIGHLIGHT]: [string];
  [PlayerControlEvent.MOVE_TO_NEXT_PAGE]: [void];
  [PlayerControlEvent.MOVE_TO_PREVIOUS_PAGE]: [void];
};
export type PlayerControlInterface = EventEmitter<PlayerControlEventMap> & {
  initialize: () => Promise<void>;
};
