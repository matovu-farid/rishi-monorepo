import { useEffect, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";

import {
  isDualPageAtom,
  nextPageAtom,
  pageCountAtom,
  previousPageAtom,
} from "@components/pdf/atoms/paragraph-atoms";
import { useAtom, useAtomValue, useSetAtom } from "jotai";

export function usePdfNavigation() {
  const [numPages, setNumPages] = useAtom(pageCountAtom);

  const [windowSize, setWindowSize] = useState({
    width: typeof window !== "undefined" ? window.innerWidth : 1024,
    height: typeof window !== "undefined" ? window.innerHeight : 768,
  });
  const [isFullscreen, setIsFullscreen] = useState(false);

  // Determine if we should show dual-page view
  const isDualPage = useAtomValue(isDualPageAtom);

  const pdfHeight = windowSize.height - 10; // 60px top + 60px bottom
  const pdfWidth = windowSize.width - 10;
  // Calculate page dimensions: in dual-page mode, each page gets half the width
  const dualPageWidth = isDualPage ? (windowSize.width - 10) / 2 - 6 : pdfWidth; // 6px for gap between pages

  // Configure PDF.js options with CDN fallback for better font and image support

  // Track window resize and fullscreen changes
  useEffect(() => {
    const handleResize = () => {
      setWindowSize({
        width: window.innerWidth,
        height: window.innerHeight,
      });
    };

    const checkFullscreen = async () => {
      try {
        const appWindow = getCurrentWindow();
        const isCurrentlyFullscreen = await appWindow.isFullscreen();
        setIsFullscreen(isCurrentlyFullscreen);
      } catch (e) {
        console.error("Error checking fullscreen:", e);
        // Fallback to browser detection
        setIsFullscreen(document.fullscreenElement !== null);
      }
    };

    window.addEventListener("resize", handleResize);

    // Check fullscreen on resize as well
    const handleResizeAndFullscreen = async () => {
      handleResize();
      await checkFullscreen();
    };

    window.addEventListener("resize", handleResizeAndFullscreen);

    // Initial check
    void checkFullscreen();

    // Poll for fullscreen changes (Tauri doesn't have an event for this)
    const fullscreenCheckInterval = setInterval(checkFullscreen, 500);

    return () => {
      window.removeEventListener("resize", handleResizeAndFullscreen);
      clearInterval(fullscreenCheckInterval);
    };
  }, []);

  const previousPageSetter = useSetAtom(previousPageAtom);
  const previousPage = () => {
    void previousPageSetter();
  };
  const nextPageSetter = useSetAtom(nextPageAtom);
  const nextPage = () => {
    void nextPageSetter();
  };

  return {
    previousPage,
    nextPage,
    setNumPages,
    numPages,
    isDualPage,
    pdfHeight,
    pdfWidth,
    dualPageWidth,
    isFullscreen,
  };
}
