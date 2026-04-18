import { Link } from "@tanstack/react-router";
import { Button } from "./ui/Button";
import { useEpubStore } from "@/stores/epubStore";
import { ThemeType } from "@/themes/common";
import { useChatStore } from "@/stores/chatStore";
import { ChevronLeft } from "lucide-react";

function cn(...classes: string[]) {
  return classes.filter(Boolean).join(" ");
}
export function BackButton() {
  const theme = useEpubStore((s) => s.theme);
  const stopConversation = useChatStore((s) => s.stopConversation);

  function getTextColor() {
    switch (theme) {
      case ThemeType.White:
        return "text-black hover:bg-black/10 hover:text-black";
      case ThemeType.Dark:
        return "text-white hover:bg-white/10 hover:text-white";
      default:
        return "text-black hover:bg-black/10 hover:text-black";
    }
  }
  function onBackClick() {
    stopConversation();
    // Save current book as last-read so the library shows "Reading Now"
    const bookId = window.location.pathname.match(/\/books\/(\d+)/)?.[1];
    if (bookId) {
      localStorage.setItem("lastReadBookId", bookId);
      window.dispatchEvent(new Event("lastReadBookChanged"));
    }
  }

  return (
    <Link to="/">
      <Button
        onClick={onBackClick}
        variant="ghost"
        size="small"
        startIcon={<ChevronLeft size={18} />}
        className={cn("disabled:invisible cursor-pointer", getTextColor())}
      >
        Library
      </Button>
    </Link>
  );
}
