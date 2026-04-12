import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useAtom } from "jotai";
import { useMutation } from "@tanstack/react-query";
import { toast } from "react-toastify";

import {
  getMobiChapter,
  getMobiChapterCount,
  updateBookLocation,
} from "@/generated";
import type { Book } from "@/generated";
import { BackButton } from "@components/BackButton";
import TTSControls from "@components/TTSControls";
import { IconButton } from "@components/ui/IconButton";
import { Menu } from "@components/ui/Menu";
import { Radio, RadioGroup } from "@components/ui/Radio";
import { ChevronLeft, ChevronRight, Palette } from "lucide-react";
import { themeAtom } from "@/stores/epub_atoms";
import { themes } from "@/themes/themes";
import { ThemeType } from "@/themes/common";

export function MobiView({ book }: { book: Book }): React.JSX.Element {
  const [theme, setTheme] = useAtom(themeAtom);
  const [menuOpen, setMenuOpen] = useState(false);
  const [chapterIndex, setChapterIndex] = useState(() => {
    const parsed = Number(book.location);
    return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : 0;
  });
  const [chapterCount, setChapterCount] = useState(0);
  const [chapterHtml, setChapterHtml] = useState("");
  const [loading, setLoading] = useState(true);
  const iframeRef = useRef<HTMLIFrameElement>(null);

  // Fetch total chapter count on mount
  useEffect(() => {
    getMobiChapterCount({ path: book.filepath })
      .then((count) => setChapterCount(count))
      .catch((err) => {
        console.error("[MobiView] failed to get chapter count:", err);
        toast.error("Failed to load MOBI chapter count");
      });
  }, [book.filepath]);

  // Fetch chapter HTML when index changes
  useEffect(() => {
    if (chapterCount === 0) return;
    setLoading(true);
    getMobiChapter({ path: book.filepath, chapterIndex })
      .then((html) => {
        setChapterHtml(html);
        setLoading(false);
      })
      .catch((err) => {
        console.error("[MobiView] failed to get chapter:", err);
        toast.error("Failed to load chapter");
        setLoading(false);
      });
  }, [book.filepath, chapterIndex, chapterCount]);

  // Persist reading position
  const updateLocationMutation = useMutation({
    mutationFn: async (index: number) => {
      await updateBookLocation({
        bookId: book.id,
        newLocation: String(index),
      });
    },
    onError() {
      toast.error("Failed to save reading position");
    },
  });

  useEffect(() => {
    updateLocationMutation.mutate(chapterIndex);
  }, [chapterIndex]);

  // Navigation helpers
  const goNext = useCallback(() => {
    setChapterIndex((prev) => Math.min(prev + 1, chapterCount - 1));
  }, [chapterCount]);

  const goPrev = useCallback(() => {
    setChapterIndex((prev) => Math.max(prev - 1, 0));
  }, []);

  // Keyboard navigation
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "ArrowRight") {
        goNext();
      } else if (e.key === "ArrowLeft") {
        goPrev();
      }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [goNext, goPrev]);

  // Build themed srcdoc
  const srcdoc = useMemo(() => {
    const t = themes[theme];
    return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<style>
  * { box-sizing: border-box; }
  body {
    background: ${t.background};
    color: ${t.color};
    font-family: Georgia, 'Times New Roman', serif;
    font-size: 1.2em;
    line-height: 1.8;
    padding: 2rem 3rem;
    max-width: 800px;
    margin: 0 auto;
  }
  img { max-width: 100%; height: auto; }
  a { color: inherit; }
</style>
</head>
<body>${chapterHtml}</body>
</html>`;
  }, [chapterHtml, theme]);

  const handleThemeChange = (newTheme: ThemeType) => {
    setTheme(newTheme);
    setMenuOpen(false);
  };

  function getTextColor() {
    switch (theme) {
      case ThemeType.Dark:
        return "text-white hover:bg-white/10 hover:text-white";
      default:
        return "text-black hover:bg-black/10 hover:text-black";
    }
  }

  return (
    <div
      className="relative h-screen flex flex-col"
      style={{ background: themes[theme].background }}
    >
      {/* Top bar */}
      <div className="absolute right-2 top-2 z-10 flex items-center gap-2">
        <BackButton />
        <Menu
          trigger={
            <IconButton className="hover:bg-transparent border-none">
              <Palette size={20} className={getTextColor()} />
            </IconButton>
          }
          open={menuOpen}
          onOpen={() => setMenuOpen(true)}
          onClose={() => setMenuOpen(false)}
          anchorOrigin={{ vertical: "bottom", horizontal: "right" }}
          theme={themes[theme]}
        >
          <div className="p-3">
            <RadioGroup
              value={theme}
              onChange={(value) => handleThemeChange(value as ThemeType)}
              name="theme-selector"
              theme={themes[theme]}
            >
              {(Object.keys(themes) as Array<keyof typeof themes>).map(
                (themeKey) => (
                  <Radio
                    key={themeKey}
                    value={themeKey}
                    label={themeKey}
                    theme={themes[theme]}
                  />
                )
              )}
            </RadioGroup>
          </div>
        </Menu>
      </div>

      {/* Main content area */}
      <div className="flex-1 overflow-hidden">
        {loading ? (
          <div className="flex items-center justify-center h-full">
            <div
              className="animate-spin rounded-full h-8 w-8 border-2 border-current border-t-transparent"
              style={{ color: themes[theme].color }}
            />
          </div>
        ) : (
          <iframe
            ref={iframeRef}
            srcDoc={srcdoc}
            className="w-full h-full border-none"
            title={book.title}
            sandbox="allow-same-origin"
          />
        )}
      </div>

      {/* Chapter navigation bar */}
      <div className="fixed bottom-20 left-1/2 -translate-x-1/2 z-10">
        <div className="flex items-center gap-3 px-4 py-2 bg-black/60 rounded-2xl backdrop-blur-lg">
          <button
            onClick={goPrev}
            disabled={chapterIndex <= 0}
            className="p-1 text-white disabled:opacity-30 hover:opacity-80 transition-opacity"
            aria-label="Previous chapter"
          >
            <ChevronLeft size={20} />
          </button>
          <span className="text-white text-sm font-medium min-w-[4rem] text-center">
            {chapterCount > 0
              ? `${chapterIndex + 1} / ${chapterCount}`
              : "..."}
          </span>
          <button
            onClick={goNext}
            disabled={chapterIndex >= chapterCount - 1}
            className="p-1 text-white disabled:opacity-30 hover:opacity-80 transition-opacity"
            aria-label="Next chapter"
          >
            <ChevronRight size={20} />
          </button>
        </div>
      </div>

      {/* TTS Controls */}
      <TTSControls bookId={book.id.toString()} />
    </div>
  );
}
