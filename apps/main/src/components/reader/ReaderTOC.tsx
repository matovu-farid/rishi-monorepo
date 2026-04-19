import React from "react";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from "@components/components/ui/sheet";
import { BookmarksList } from "@/components/bookmarks/BookmarksList";
import { cn } from "@components/lib/utils";

interface ReaderTOCProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** The TOC content - either a list of items or custom content */
  tocContent: React.ReactNode;
  /** Book sync ID for bookmarks */
  bookSyncId: string;
  /** Called when navigating to a bookmark location */
  onBookmarkNavigate: (location: string) => void;
  /** Title shown in header */
  title?: string;
}

export function ReaderTOC({
  open,
  onOpenChange,
  tocContent,
  bookSyncId,
  onBookmarkNavigate,
  title = "Table of Contents",
}: ReaderTOCProps) {
  const [activeTab, setActiveTab] = React.useState<"contents" | "bookmarks">(
    "contents"
  );

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        side="left"
        className={cn("w-[300px] sm:w-[400px] p-0 bg-white border-gray-200")}
      >
        <SheetHeader
          className={cn(
            "p-4 border-b sticky top-0 z-10 border-gray-200 bg-white"
          )}
        >
          <SheetTitle>{title}</SheetTitle>
        </SheetHeader>
        <div className="flex border-b border-gray-200">
          <button
            onClick={() => setActiveTab("contents")}
            className={cn(
              "flex-1 px-4 py-2 text-sm font-medium transition-colors",
              activeTab === "contents"
                ? "border-b-2 border-blue-500 text-blue-600"
                : "text-gray-500 hover:text-gray-700"
            )}
          >
            Contents
          </button>
          <button
            onClick={() => setActiveTab("bookmarks")}
            className={cn(
              "flex-1 px-4 py-2 text-sm font-medium transition-colors",
              activeTab === "bookmarks"
                ? "border-b-2 border-red-500 text-red-600"
                : "text-gray-500 hover:text-gray-700"
            )}
          >
            Bookmarks
          </button>
        </div>
        {activeTab === "contents" ? (
          <div className="overflow-y-auto h-[calc(100vh-73px)]">
            {tocContent}
          </div>
        ) : (
          <BookmarksList
            bookSyncId={bookSyncId}
            onNavigate={onBookmarkNavigate}
          />
        )}
      </SheetContent>
    </Sheet>
  );
}
