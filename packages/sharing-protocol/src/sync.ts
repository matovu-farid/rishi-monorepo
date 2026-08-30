import { z } from "zod";

export const MAX_SYNC_FRAME_BYTES = 16 * 1024;

const Version = z.literal(1);
const BookId = z.string().min(1).max(128);
const BoundedString = z.string().min(1).max(4096);
const Cfi = BoundedString;
const Page = z.number().int().nonnegative().max(1_000_000);
const FiniteNumber = z.number().finite();
const Timestamp = FiniteNumber.nonnegative().max(Number.MAX_SAFE_INTEGER);
const Sequence = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const ContentHash = z.string().regex(/^[0-9a-f]{64}$/);

const PositionBase = {
  ts: Timestamp,
} as const;

/**
 * Reader position is format-native: EPUB uses a bounded CFI and PDF uses a
 * bounded page number plus an offset within that page.
 */
export const ReaderPosition = z.discriminatedUnion("format", [
  z.object({
    format: z.literal("pdf"),
    page: Page,
    offsetY: FiniteNumber.max(10_000_000),
    ...PositionBase,
  }).strict(),
  z.object({
    format: z.literal("epub"),
    cfi: Cfi,
    ...PositionBase,
  }).strict(),
]);
export type ReaderPosition = z.infer<typeof ReaderPosition>;

const LegacyTtsState = z.object({
  isPlaying: z.boolean(),
  position: z.object({
    sentenceIdx: z.number().int().nonnegative().max(10_000_000),
    charOffset: z.number().int().nonnegative().max(10_000_000),
  }).strict(),
  voiceId: z.string().max(256),
  rate: z.number().finite().min(0.25).max(4),
}).strict();
export const SnapshotTts = LegacyTtsState;
export type SnapshotTts = z.infer<typeof SnapshotTts>;

const AnnotationRect = z.object({
  x: FiniteNumber,
  y: FiniteNumber,
  width: FiniteNumber.nonnegative().max(10_000_000),
  height: FiniteNumber.nonnegative().max(10_000_000),
}).strict();

/** Explicit, bounded annotation locations; no renderer-owned objects cross the wire. */
export const AnnotationRange = z.discriminatedUnion("format", [
  z.object({ format: z.literal("epub"), cfi: Cfi }).strict(),
  z.object({ format: z.literal("pdf"), page: Page, rect: AnnotationRect }).strict(),
]).or(z.object({ format: z.literal("epub"), cfiRange: Cfi }).strict());
export type AnnotationRange = z.infer<typeof AnnotationRange>;

/**
 * Legacy annotation ranges were renderer-owned JSON objects. Keep accepting
 * those objects, including `{}`, while bounding keys and serialized size.
 */
const LegacyAnnotationRange = z.record(z.string().max(128), z.json()).superRefine((value, ctx) => {
  const encoded = JSON.stringify(value);
  if (encoded === undefined || new TextEncoder().encode(encoded).byteLength > 8 * 1024) {
    ctx.addIssue({ code: "custom", message: "legacy annotation range exceeds the 8 KiB maximum" });
  }
});

const LegacyBase = {
  v: Version,
  ts: Timestamp,
} as const;

const legacyMessage = <T extends z.ZodRawShape>(shape: T) =>
  z.object({ ...LegacyBase, ...shape }).strict();

/** Existing reader/voice protocol retained for the Electron rollout. */
export const SyncMsg = z.discriminatedUnion("t", [
  legacyMessage({
    t: z.literal("reader.position"),
    bookId: BookId,
    position: ReaderPosition,
  }),
  legacyMessage({
    t: z.literal("tts.state"),
    ...LegacyTtsState.shape,
  }),
  legacyMessage({
    t: z.literal("annotation.add"),
    id: BoundedString,
    range: LegacyAnnotationRange,
    color: z.string().min(1).max(64),
  }),
  legacyMessage({ t: z.literal("annotation.remove"), id: BoundedString }),
  legacyMessage({
    t: z.literal("cursor"),
    x: FiniteNumber,
    y: FiniteNumber,
  }),
  legacyMessage({
    t: z.literal("snapshot"),
    bookId: BookId,
    position: ReaderPosition.optional(),
    tts: SnapshotTts.optional(),
  }),
]);
export type SyncMsg = z.infer<typeof SyncMsg>;

const Format = z.enum(["epub", "pdf"]);
const AuthoritativePosition = z.union([
  z.object({ format: z.literal("epub"), cfi: Cfi }).strict(),
  z.object({ format: z.literal("pdf"), page: Page, offsetY: FiniteNumber.max(10_000_000) }).strict(),
]);

const authoritativeFields = {
  v: Version,
  format: Format,
  bookId: BookId,
  contentHash: ContentHash,
  position: AuthoritativePosition,
  isPlaying: z.boolean(),
  ttsRate: z.number().finite().min(0.25).max(4),
} as const;

const controllerFields = {
  roomEpoch: Sequence.optional(),
  controllerGeneration: Sequence.optional(),
  sequence: Sequence.optional(),
  source: z.enum(["controller", "local"]),
} as const;

const authoritativeMessage = (
  t: "play" | "pause" | "position" | "floor",
 ) => z.object({
  ...authoritativeFields,
  t: z.literal(t),
  ...controllerFields,
}).strict().superRefine((value, ctx) => {
  if (value.format !== value.position.format) {
    ctx.addIssue({ code: "custom", path: ["position", "format"], message: "position format must match format" });
  }
  if (value.source === "controller") {
    for (const field of ["roomEpoch", "controllerGeneration", "sequence"] as const) {
      if (value[field] === undefined) {
        ctx.addIssue({ code: "custom", path: [field], message: `${field} is required for controller messages` });
      }
    }
  } else if (value.roomEpoch !== undefined || value.controllerGeneration !== undefined || value.sequence !== undefined) {
    ctx.addIssue({ code: "custom", path: ["source"], message: "local messages cannot carry controller ordering fields" });
  }
});

/**
 * v1 controller-authoritative reader state. Controller generations and
 * sequences are required only for controller-originated messages; local
 * reader actions remain valid without controller authority.
 */
export const AuthoritativeSync = z.discriminatedUnion("t", [
  authoritativeMessage("play"),
  authoritativeMessage("pause"),
  authoritativeMessage("position"),
  authoritativeMessage("floor"),
]);
export type AuthoritativeSync = z.infer<typeof AuthoritativeSync>;

const SnapshotBase = {
  v: Version,
  t: z.literal("snapshot"),
  roomEpoch: Sequence,
  controllerGeneration: Sequence,
  sequence: Sequence,
  bookId: BookId,
  contentHash: ContentHash,
  format: Format.optional(),
  position: AuthoritativePosition.optional(),
  isPlaying: z.boolean().optional(),
  ttsRate: z.number().finite().min(0.25).max(4).optional(),
  source: z.literal("controller").optional(),
} as const;

/** A controller snapshot used for replay/freshness fencing. */
export const ControllerSnapshot = z.object(SnapshotBase).strict().superRefine((value, ctx) => {
  if (value.format !== undefined && value.position !== undefined && value.format !== value.position.format) {
    ctx.addIssue({ code: "custom", path: ["position", "format"], message: "position format must match format" });
  }
});
export type ControllerSnapshot = z.infer<typeof ControllerSnapshot>;

const SyncFrameShape = z.union([SyncMsg, AuthoritativeSync, ControllerSnapshot]);

/** All accepted sync payloads, including the legacy reader protocol. */
export const SyncFrame = z.preprocess((value, ctx) => {
  let encoded: string | undefined;
  try {
    encoded = JSON.stringify(value);
  } catch {
    ctx.addIssue({ code: "custom", message: "sync frame must be JSON-serializable" });
    return z.NEVER;
  }
  if (encoded === undefined) {
    ctx.addIssue({ code: "custom", message: "sync frame must be JSON-serializable" });
    return z.NEVER;
  }
  if (new TextEncoder().encode(encoded).byteLength > MAX_SYNC_FRAME_BYTES) {
    ctx.addIssue({ code: "custom", message: "sync frame exceeds the 16 KiB maximum" });
    return z.NEVER;
  }
  return value;
}, SyncFrameShape);
export type SyncFrame = z.infer<typeof SyncFrame>;

/** Check parsed sync payload size before schema work or dispatch. */
export function parseSyncFrame(frame: unknown): SyncFrame {
  let encoded: string;
  try {
    encoded = JSON.stringify(frame);
  } catch {
    throw new TypeError("sync frame must be JSON-serializable");
  }
  if (encoded === undefined) {
    throw new TypeError("sync frame must be JSON-serializable");
  }
  if (new TextEncoder().encode(encoded).byteLength > MAX_SYNC_FRAME_BYTES) {
    throw new RangeError("sync frame exceeds the 16 KiB maximum");
  }
  return SyncFrame.parse(frame);
}

/** Pure lexicographic freshness check for controller snapshots. */
export function isStaleSnapshot(
  incoming: Pick<ControllerSnapshot, "roomEpoch" | "controllerGeneration" | "sequence">,
  current: Pick<ControllerSnapshot, "roomEpoch" | "controllerGeneration" | "sequence">,
): boolean {
  if (incoming.roomEpoch !== current.roomEpoch) return incoming.roomEpoch < current.roomEpoch;
  if (incoming.controllerGeneration !== current.controllerGeneration) {
    return incoming.controllerGeneration < current.controllerGeneration;
  }
  return incoming.sequence <= current.sequence;
}

/** Pure book identity check for a controller snapshot. */
export function isSnapshotForBook(
  snapshot: Pick<ControllerSnapshot, "bookId" | "contentHash">,
  bookId: string,
  contentHash: string,
): boolean {
  return snapshot.bookId === bookId && snapshot.contentHash === contentHash;
}

export const isSyncForBook = isSnapshotForBook;
