import { beforeAll, describe, expect, it, vi } from "vitest";
import { ttsService } from "./ttsService";
import fs from "fs/promises";
import path from "path";

import { fileTypeFromFile } from "file-type";

describe("TTS Service", () => {
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

  it(
    "should request audio and return audio path with audio data",
    { timeout: 10000 },
    async () => {
      const text = "The quick brown fox jumps over the lazy dog.";

      const audioPath = await ttsService.requestAudio("1", "1", text);
      expect(audioPath).toBeDefined();

      await expect
        .poll(() => fs.readFile(audioPath), { timeout: 4000 })
        .toBeDefined();
      const audioData = await fs.readFile(audioPath);

      expect(audioData.length).toBeGreaterThan(0);

      //const buffer = await readChunk(audioPath, {length: 4100});
      const fileType = await fileTypeFromFile(audioPath);
      expect(fileType?.mime).toBe("audio/mpeg");
    }
  );
});
