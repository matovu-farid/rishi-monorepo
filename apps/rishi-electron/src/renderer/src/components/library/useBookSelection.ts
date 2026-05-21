import { useCallback, useState } from 'react'

export interface BookSelection {
  selectMode: boolean
  selectedIds: Set<number>
  toggle: (id: number) => void
  clear: () => void
  exitSelectMode: () => void
}

export function useBookSelection(): BookSelection {
  const [selectMode, setSelectMode] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set())

  const toggle = useCallback((id: number) => {
    setSelectMode(true)
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (next.has(id)) {
        next.delete(id)
      } else {
        next.add(id)
      }
      return next
    })
  }, [])

  const clear = useCallback(() => {
    setSelectedIds(new Set())
  }, [])

  const exitSelectMode = useCallback(() => {
    setSelectMode(false)
    setSelectedIds(new Set())
  }, [])

  return { selectMode, selectedIds, toggle, clear, exitSelectMode }
}
