import { Bookmark, Trash2 } from "lucide-react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { getBookmarksForBook, deleteBookmark } from "@/modules/bookmark-storage";

interface BookmarksListProps {
  bookSyncId: string;
  onNavigate: (location: string) => void;
}

export function BookmarksList({ bookSyncId, onNavigate }: BookmarksListProps) {
  const queryClient = useQueryClient();

  const { data: bookmarks = [] } = useQuery({
    queryKey: ["bookmarks", bookSyncId],
    queryFn: () => getBookmarksForBook(bookSyncId),
    enabled: !!bookSyncId,
  });

  const handleDelete = async (id: string) => {
    await deleteBookmark(id);
    void queryClient.invalidateQueries({ queryKey: ["bookmarks", bookSyncId] });
  };

  if (bookmarks.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center py-12 text-gray-400">
        <Bookmark size={32} className="mb-2 opacity-50" />
        <p className="text-sm">No bookmarks yet</p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-1 p-2">
      {bookmarks.map((bm) => (
        <div
          key={bm.id}
          className="flex items-center gap-3 px-3 py-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-800 cursor-pointer group"
          onClick={() => onNavigate(bm.location)}
        >
          <Bookmark size={16} fill="#ef4444" stroke="#ef4444" className="shrink-0" />
          <div className="flex-1 min-w-0">
            <div className="text-sm font-medium truncate">
              {bm.label || bm.location}
            </div>
            <div className="text-xs text-gray-400">
              {new Date(bm.created_at).toLocaleDateString()}
            </div>
          </div>
          <button
            onClick={(e) => {
              e.stopPropagation();
              void handleDelete(bm.id);
            }}
            className="opacity-0 group-hover:opacity-100 p-1 hover:text-red-500 transition-opacity"
            aria-label="Delete bookmark"
          >
            <Trash2 size={14} />
          </button>
        </div>
      ))}
    </div>
  );
}
