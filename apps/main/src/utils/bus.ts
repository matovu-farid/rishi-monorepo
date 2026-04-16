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
// PlayerControlEvent previously held paragraph-lifecycle events
// (NEW_PARAGRAPHS_AVAILABLE, NEXT/PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE,
// NEXT/PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, PAGE_CHANGED,
// PARAGRAPH_HIGHLIGHTED, PARAGRAPH_UNHIGHLIGHTED) that were removed in
// Task 39 because the ReaderShell cutover made them all dead code.
// The enum and its type map are kept as empty stubs so that the
// EventBusEvent spread below still type-checks without changes to callers.
export enum PlayerControlEvent {}
export type PlayerControlEventMap = Record<never, never>;

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
