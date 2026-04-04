// @ts-ignore

import { ParagraphWithIndex } from "./player_control";
import { PlayingState } from "@/utils/bus";
import { isHighlightingAtom } from "@components/pdf/atoms/paragraph-atoms";
import { customStore } from "@/stores/jotai";
import audio from "@/models/audio";
import { Player } from "./PlayerClass";

export enum Direction {
  Forward = "forward",
  Backward = "backward",
}
export enum PlayerEvent {
  PARAGRAPH_INDEX_CHANGED = "paragraphIndexChanged",
  PLAYING_STATE_CHANGED = "playingStateChanged",
  ERRORS_CHANGED = "errorsChanged",
}
export type PlayerEventMap = {
  [PlayerEvent.PARAGRAPH_INDEX_CHANGED]: [ParagraphIndexChangedEvent];
  [PlayerEvent.PLAYING_STATE_CHANGED]: [PlayingState];
  [PlayerEvent.ERRORS_CHANGED]: [ErrorsChangedEvent];
};

export interface ParagraphIndexChangedEvent {
  index: number;
  paragraph: ParagraphWithIndex | null;
}
export type PlayingStateChangedEvent = [PlayingState];

export interface ErrorsChangedEvent {
  errors: string[];
}

/**
 * Singleton instance of the Player class
 * Must be initialized with a player control and book id
 * @example
 * void player.initialize( bookId);
 */
export const player = new Player(audio);
player.on(PlayerEvent.PLAYING_STATE_CHANGED, (state) => {
  if (state === PlayingState.Playing) {
    customStore.set(isHighlightingAtom, true);
  } else {
    customStore.set(isHighlightingAtom, false);
  }
});
export default player;
