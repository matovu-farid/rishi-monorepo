import { useRef, useEffect } from "react";
import { Thumbnail } from "react-pdf";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useAtomValue } from "jotai";
import {
  pageCountAtom,
  pageNumberAtom,
  pdfDocumentProxyAtom,
} from "../atoms/paragraph-atoms";
import { cn } from "@components/lib/utils";

const THUMBNAIL_WIDTH = 120;
const THUMBNAIL_HEIGHT = 170;
const GAP = 8;

export function ThumbnailSidebar({
  onClose,
  onNavigate,
}: {
  onClose: () => void;
  onNavigate: (pageNumber: number) => void;
}) {
  const numPages = useAtomValue(pageCountAtom);
  const currentPage = useAtomValue(pageNumberAtom);
  const pdfProxy = useAtomValue(pdfDocumentProxyAtom);
  const containerRef = useRef<HTMLDivElement>(null);

  const thumbVirtualizer = useVirtualizer({
    count: numPages,
    getScrollElement: () => containerRef.current,
    estimateSize: () => THUMBNAIL_HEIGHT + GAP,
    overscan: 3,
  });

  useEffect(() => {
    if (currentPage > 0) {
      thumbVirtualizer.scrollToIndex(currentPage - 1, { align: "center" });
    }
  }, []);

  const handleClick = (pageNum: number) => {
    onNavigate(pageNum);
    onClose();
  };

  return (
    <div ref={containerRef} className="overflow-y-auto h-full p-2">
      <div
        style={{
          height: thumbVirtualizer.getTotalSize(),
          position: "relative",
          width: "100%",
        }}
      >
        {thumbVirtualizer.getVirtualItems().map((item) => {
          const pageNum = item.index + 1;
          return (
            <div
              key={item.key}
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                width: "100%",
                height: `${item.size}px`,
                transform: `translateY(${item.start}px)`,
              }}
              className="flex flex-col items-center"
            >
              <Thumbnail
                pageNumber={pageNum}
                width={THUMBNAIL_WIDTH}
                pdf={pdfProxy ?? undefined}
                onItemClick={() => handleClick(pageNum)}
                className={cn(
                  "cursor-pointer border-2 rounded transition-colors",
                  currentPage === pageNum
                    ? "border-blue-500 shadow-md"
                    : "border-transparent hover:border-gray-300"
                )}
              />
              <span className="text-xs text-gray-500 mt-1">{pageNum}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
