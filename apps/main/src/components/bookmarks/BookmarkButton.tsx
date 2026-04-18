import { Bookmark } from "lucide-react";
import { IconButton } from "@components/ui/IconButton";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { getBookmarkAtLocation, toggleBookmark } from "@/modules/bookmark-storage";

interface BookmarkButtonProps {
  bookSyncId: string;
  location: string;
  label?: string;
  className?: string;
}

export function BookmarkButton({ bookSyncId, location, label, className }: BookmarkButtonProps) {
  const queryClient = useQueryClient();

  const { data: existingBookmark } = useQuery({
    queryKey: ["bookmark", bookSyncId, location],
    queryFn: () => getBookmarkAtLocation(bookSyncId, location),
    enabled: !!bookSyncId && !!location,
  });

  const isBookmarked = !!existingBookmark;

  const handleToggle = async () => {
    if (!bookSyncId || !location) return;
    await toggleBookmark({ bookSyncId, location, label });
    void queryClient.invalidateQueries({ queryKey: ["bookmark", bookSyncId, location] });
    void queryClient.invalidateQueries({ queryKey: ["bookmarks", bookSyncId] });
  };

  return (
    <IconButton
      onClick={handleToggle}
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
