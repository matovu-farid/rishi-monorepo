import { useEffect, useState, useCallback } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import type { Event } from "@tauri-apps/api/event";

interface UseTauriDragDropOptions {
  allowedExtensions: string[];
  onFilesDropped: (filePaths: string[]) => void;
  onDragOver?: (position: { x: number; y: number }) => void;
}

/**
 * Custom hook for handling Tauri native drag and drop events
 * @param allowedExtensions - Array of allowed file extensions (e.g., ['.epub', '.pdf'])
 * @param onFilesDropped - Callback function called when files are dropped
 * @param onDragOver - Optional callback function called when files are dragged over the window
 * @returns isDragging - Boolean indicating if files are currently being dragged over the window
 */
export function useTauriDragDrop({
  allowedExtensions,
  onFilesDropped,
  onDragOver,
}: UseTauriDragDropOptions): { isDragging: boolean } {
  const [isDragging, setIsDragging] = useState(false);

  // Normalize extensions to lowercase for case-insensitive comparison
  const normalizedExtensions = allowedExtensions.map((ext) =>
    ext.toLowerCase().startsWith(".")
      ? ext.toLowerCase()
      : `.${ext.toLowerCase()}`
  );

  // Filter files by allowed extensions
  const filterFilesByExtension = useCallback(
    (filePaths: string[]): string[] => {
      return filePaths.filter((filePath) => {
        const lowerPath = filePath.toLowerCase();
        return normalizedExtensions.some((ext) => lowerPath.endsWith(ext));
      });
    },
    [normalizedExtensions]
  );

  useEffect(() => {
    let unlistenPromise: Promise<() => void> | null = null;

    const setupListener = async () => {
      try {
        const window = getCurrentWindow();
        unlistenPromise = window.onDragDropEvent(
          (
            event: Event<{
              type: "enter" | "over" | "drop" | "leave" | "cancelled";
              paths?: string[];
              position?: { x: number; y: number };
            }>
          ) => {
            const payload = event.payload;
            if (payload.type === "over" || payload.type === "enter") {
              setIsDragging(true);
              if (onDragOver && payload.position) {
                onDragOver(payload.position);
              }
            } else if (payload.type === "drop" && payload.paths) {
              setIsDragging(false);
              const filteredPaths = filterFilesByExtension(payload.paths);
              if (filteredPaths.length > 0) {
                onFilesDropped(filteredPaths);
              }
            } else {
              // Cancelled, leave, or other event types
              setIsDragging(false);
            }
          }
        );
      } catch (error) {
        console.error("Failed to set up drag and drop listener:", error);
      }
    };

    void setupListener();

    // Cleanup function
    return () => {
      if (unlistenPromise) {
        unlistenPromise
          .then((unlisten) => {
            unlisten();
          })
          .catch((error) => {
            console.error("Failed to unlisten drag and drop event:", error);
          });
      }
    };
  }, [onFilesDropped, onDragOver, filterFilesByExtension]);

  return { isDragging };
}
