import { Bookmark } from "lucide-react";
import { IconButton } from "@components/ui/IconButton";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { getBookmarksForBook, toggleBookmark, locationsMatch } from "@/modules/bookmark-storage";

interface BookmarkButtonProps {
  bookSyncId: string;
  location: string;
  label?: string;
  className?: string;
}

export function BookmarkButton({ bookSyncId, location, label, className }: BookmarkButtonProps) {
  const queryClient = useQueryClient();

  // Single query for ALL bookmarks of this book — shared with BookmarksList
  const { data: bookmarks = [] } = useQuery({
    queryKey: ["bookmarks", bookSyncId],
    queryFn: () => getBookmarksForBook(bookSyncId),
    enabled: !!bookSyncId,
  });

  // Derive bookmarked state from the full list using fuzzy location matching
  const isBookmarked = bookmarks.some(b => locationsMatch(b.location, location));

  const toggleMutation = useMutation({
    mutationFn: () => toggleBookmark({ bookSyncId, location, label }),
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: ["bookmarks", bookSyncId] });
    },
  });

  return (
    <IconButton
      color="inherit"
      onClick={() => toggleMutation.mutate()}
      disabled={toggleMutation.isPending}
      className={className}
      aria-label={isBookmarked ? "Remove bookmark" : "Add bookmark"}
    >
      <Bookmark
        size={20}
        fill={isBookmarked ? "#ef4444" : "none"}
        stroke={isBookmarked ? "#ef4444" : "currentColor"}
      />
    </IconButton>
  );
}
