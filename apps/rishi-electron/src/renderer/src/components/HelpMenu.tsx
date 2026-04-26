import { HelpCircle } from 'lucide-react'
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem
} from '@/components/ui/dropdown-menu'
import { useTutorialStore } from '@/stores/tutorialStore'

export function HelpMenu() {
  const resetTour = useTutorialStore((s) => s.resetTour)
  const startTour = useTutorialStore((s) => s.startTour)

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        aria-label="Help"
        className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
      >
        <HelpCircle size={18} />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuItem
          onClick={() => {
            resetTour()
            startTour()
          }}
        >
          Replay tutorial
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
