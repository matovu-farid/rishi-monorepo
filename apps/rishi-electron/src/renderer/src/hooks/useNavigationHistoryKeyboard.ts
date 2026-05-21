import { useEffect } from 'react'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'

export function useNavigationHistoryKeyboard(): void {
  useEffect(() => {
    const handler = (e: KeyboardEvent): void => {
      if (e.key !== '[') return
      if (!(e.metaKey || e.ctrlKey)) return
      e.preventDefault()
      navigationHistoryActor.send({ type: 'POP_BACK' })
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [])
}
