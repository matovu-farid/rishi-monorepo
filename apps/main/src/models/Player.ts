// @ts-ignore

import { ParagraphWithIndex } from "./player_control";
import { PlayingState } from "@/utils/bus";
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
// NOTE: PLAYING_STATE_CHANGED → isHighlighting is now managed inside PdfView's
// scoped useEffect (pdf.tsx) so it only fires when a PDF is the active format.
export default player;
