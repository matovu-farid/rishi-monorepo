import { beforeAll, describe, expect, it, vi } from "vitest";
import fs from "fs/promises";
import path from "path";
import { eventBus, EventBusEvent, PlayingState } from "@/utils/bus";
import { paragraphs } from "./fixtures";
import eventEmitter from "eventemitter3";
import { Player } from "./PlayerClass";
import { fileTypeFromFile } from "file-type";
const emitter = new eventEmitter();
// vi.mock("./audio", async () => {
//   const { default: Emitter }: { default: EventEmitter } =
//     await vi.importActual("eventemitter3");

//   const emitter = new Emitter();

//   setInterval(() => {
//     emitter.emit("canplaythrough");
//   }, 10);

//   return {
//     default: {
//       play: vi.fn(),
//       pause: vi.fn(),
//       currentTime: 0,
//       duration: 0,
//       src: "",
//       load: vi.fn(),
//       removeEventListener: emitter.removeListener.bind(emitter),
//       addEventListener: emitter.addListener.bind(emitter),
//       emit: emitter.emit.bind(emitter),
//     },
//   };
// });
// audio.ts is mocked

describe("Player", () => {
  beforeAll(async () => {
    vi.clearAllMocks();
    const appDataDir = "testAudioData";
    await fs.rmdir(appDataDir, { recursive: true });
    vi.mock("@tauri-apps/plugin-http", () => ({
      fetch: fetch,
    }));
    type Fs = typeof fs;
    vi.mock("@tauri-apps/plugin-fs", async () => {
      const fs: Fs = await vi.importActual("fs/promises");
      return {
        // fs: {
        writeFile: (path: string, data: Buffer) => fs.writeFile(path, data),
        exists: (path: string) =>
          fs
            .access(path)
            .then(() => true)
            .catch(() => false),
        mkdir: (dir: string, { recursive }: { recursive: boolean }) =>
          fs.mkdir(dir, { recursive }),
        stat: fs.stat.bind(fs),
        remove: fs.unlink.bind(fs),
        readDir: fs.readdir.bind(fs),
        // },
      };
    });
    type Path = typeof path;

    vi.mock("@tauri-apps/api", async () => {
      const nodePath: Path = await vi.importActual("path");
      return {
        path: {
          join: nodePath.join.bind(nodePath),
          appDataDir: () => "testAudioData",
        },
      };
    });
  });

  vi.mock("@tauri-apps/api/core", () => ({
    convertFileSrc: (path: string) => path,
  }));

  it("should play a paragraph", { timeout: 10000 }, async () => {
    const mockAudio = {
      addEventListener: emitter.addListener.bind(emitter),
      removeEventListener: emitter.removeListener.bind(emitter),
      emit: emitter.emit.bind(emitter),
      currentTime: 0,
      duration: 0,
      src: "",
      load: vi.fn(),
      pause: vi.fn(),
      play: vi.fn(),
    } as unknown as HTMLAudioElement;

    let timer = setInterval(() => {
      emitter.emit("canplaythrough");
    }, 10);
    const player = new Player(mockAudio);

    await player.initialize("1");

    eventBus.publish(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, paragraphs);

    expect(player.getPlayingState()).toBe(PlayingState.Stopped);
    expect(await player.getCurrentParagraphs()).toEqual(paragraphs);
    expect(await player.getNextPageParagraphs()).toEqual([]);
    expect(await player.getPreviousPageParagraphs()).toEqual([]);
    await player.play();

    expect(player.getPlayingState()).toBe(PlayingState.Playing);

    clearInterval(timer);
    const audioPath = player.audioElement.src;
    expect(audioPath).toBeDefined();
    await expect
      .poll(() => fs.readFile(audioPath), { timeout: 4000 })
      .toBeDefined();
    const audioData = await fs.readFile(audioPath);

    expect(audioData.length).toBeGreaterThan(0);

    //const buffer = await readChunk(audioPath, {length: 4100});
    const fileType = await fileTypeFromFile(audioPath);
    expect(fileType?.mime).toBe("audio/mpeg");
    expect(await player.getCurrentParagraph()).toEqual(paragraphs[0]);
  });
});
