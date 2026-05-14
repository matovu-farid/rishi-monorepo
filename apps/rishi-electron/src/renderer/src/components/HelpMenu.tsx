import { useEffect, useState } from 'react'
import { HelpCircle, BookOpen, Globe, MessageCircle } from 'lucide-react'
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuLabel
} from '@/components/ui/dropdown-menu'
import { useTutorialStore } from '@/stores/tutorialStore'

const SUPPORT_URL = 'https://rishi.fidexa.org/support'
const WEBSITE_URL = 'https://rishi.fidexa.org'

export function HelpMenu() {
  const resetTour = useTutorialStore((s) => s.resetTour)
  const startTour = useTutorialStore((s) => s.startTour)
  const [version, setVersion] = useState('')

  useEffect(() => {
    window.electron
      .getAppVersion()
      .then(setVersion)
      .catch(() => {})
  }, [])

  const open = (url: string): void => {
    void window.electron.openExternal(url)
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        aria-label="Help"
        title="Help & support"
        className="p-2 hover:bg-gray-100 active:bg-gray-200 rounded-lg transition-colors"
      >
        <HelpCircle size={18} />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="min-w-[12rem]">
        <DropdownMenuItem
          onClick={() => {
            resetTour()
            startTour()
          }}
        >
          <BookOpen size={14} className="mr-2" />
          Replay tutorial
        </DropdownMenuItem>
        <DropdownMenuItem onClick={() => open(WEBSITE_URL)}>
          <Globe size={14} className="mr-2" />
          Visit website
        </DropdownMenuItem>
        <DropdownMenuItem onClick={() => open(SUPPORT_URL)}>
          <MessageCircle size={14} className="mr-2" />
          Contact support
        </DropdownMenuItem>
        {version ? (
          <>
            <DropdownMenuSeparator />
            <DropdownMenuLabel className="text-xs text-gray-500 font-normal">
              Rishi v{version}
            </DropdownMenuLabel>
          </>
        ) : null}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
