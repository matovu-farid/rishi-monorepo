import { CircleHelp } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
} from "@components/components/ui/dropdown-menu";
import { useTutorialStore } from "@/stores/tutorialStore";

export function HelpMenu() {
  const resetTour = useTutorialStore((s) => s.resetTour);
  const startTour = useTutorialStore((s) => s.startTour);

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        aria-label="Help"
        className="p-2 rounded-md hover:bg-black/10 text-black"
      >
        <CircleHelp size={20} />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuItem
          onClick={() => {
            resetTour();
            startTour();
          }}
        >
          Replay tutorial
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
