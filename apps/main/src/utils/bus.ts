import EventEmitter from "eventemitter3";
import { atom } from "jotai";
export class EventBus extends EventEmitter<EventBusEventMap> {
  private _logsBugger = [] as {
    timestamp: number;
    event: string;
    args: any[];
  }[];
  private logsBufferSize = 100;
  constructor() {
    super();
  }

  publish<T extends EventEmitter.EventNames<EventBusEventMap>>(
    event: T,
    ...args: EventEmitter.EventArgs<EventBusEventMap, T>
  ): boolean {
    this._logsBugger.unshift({ event, args, timestamp: Date.now() });
    while (this._logsBugger.length > this.logsBufferSize) {
      this._logsBugger.pop();
    }
    return this.emit(event, ...args);
  }

  get logsBugger() {
    return this._logsBugger;
  }
  subscribe = this.on;
}
export const eventBus = new EventBus();

export type EventBusEventMap = PlayerControlEventMap & PlayerEventMap;
export type ParagraphWithIndex = {
  text: string;
  index: string;
};
/**
 * PlayerControlEvent is used to communicate between the PlayerControl and the Player
 */
export enum PlayerControlEvent {
  PARAGRAPH_HIGHLIGHTED = "paragraphHighlighted",
  PARAGRAPH_UNHIGHLIGHTED = "paragraphUnhighlighted",
  PAGE_CHANGED = "pageChanged",
  NEW_PARAGRAPHS_AVAILABLE = "newParagraphsAvailable",
  NEXT_VIEW_PARAGRAPHS_AVAILABLE = "nextViewParagraphsAvailable",
  PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE = "previousViewParagraphsAvailable",
  NEXT_PAGE_PARAGRAPHS_EMPTIED = "nextPageParagraphsEmptied",
  PREVIOUS_PAGE_PARAGRAPHS_EMPTIED = "previousPageParagraphsEmptied",
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
  [PlayerControlEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED]: [void];
  [PlayerControlEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED]: [void];
};

/**
 * PlayingState is used to communicate between the Player and the PlayerControl
 */
export enum PlayingState {
  Playing = "playing",
  Paused = "paused",
  Stopped = "stopped",
  Loading = "loading",
  WaitingForNewParagraphs = "waitingFoNewParagraphs",
}
export enum Direction {
  Forward = "forward",
  Backward = "backward",
}
export enum PlayerEvent {
  PARAGRAPH_INDEX_CHANGED = "paragraphIndexChanged",
  PLAYING_STATE_CHANGED = "playingStateChanged",
  ERRORS_CHANGED = "errorsChanged",
  MOVED_TO_NEXT_PARAGRAPH = "movedToNextParagraph",
  MOVED_TO_PREV_PARAGRAPH = "movedToPrevParagraph",
  AUDIO_ENDED = "audioEnded",
  PLAYING_AUDIO = "playingAudio",
}
export type MoveChange = {
  from: ParagraphWithIndex;
  to: ParagraphWithIndex;
  direction: Direction;
};
export type PlayerEventMap = {
  [PlayerEvent.PARAGRAPH_INDEX_CHANGED]: [ParagraphIndexChangedEvent];
  [PlayerEvent.PLAYING_STATE_CHANGED]: [PlayingState];
  [PlayerEvent.ERRORS_CHANGED]: [ErrorsChangedEvent];
  [PlayerEvent.MOVED_TO_NEXT_PARAGRAPH]: [MoveChange];
  [PlayerEvent.MOVED_TO_PREV_PARAGRAPH]: [MoveChange];
  [PlayerEvent.AUDIO_ENDED]: [ParagraphWithIndex];
  [PlayerEvent.PLAYING_AUDIO]: [ParagraphWithIndex];
};
export interface ParagraphIndexChangedEvent {
  index: number;
  paragraph: ParagraphWithIndex | null;
}
export type PlayingStateChangedEvent = [PlayingState];

export interface ErrorsChangedEvent {
  errors: string[];
}

export const EventBusEvent = {
  ...PlayerControlEvent,
  ...PlayerEvent,
} as const;

export const eventBusAtom = atom(eventBus);
eventBusAtom.debugLabel = "eventBusAtom";
export const eventBusLogsAtom = atom((get) => get(eventBusAtom).logsBugger);
eventBusLogsAtom.debugLabel = "eventBusLogsAtom";
