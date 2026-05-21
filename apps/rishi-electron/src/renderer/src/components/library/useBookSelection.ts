import { useCallback, useState } from 'react'

export interface BookSelection {
  selectMode: boolean
  selectedIds: Set<number>
  toggle: (id: number) => void
  selectAll: (books: ReadonlyArray<{ id: number }>) => void
  extendTo: (targetId: number, displayOrder: ReadonlyArray<number>) => void
  enterSelectMode: (initialId?: number) => void
  clear: () => void
  exitSelectMode: () => void
}

export function useBookSelection(): BookSelection {
  const [selectMode, setSelectMode] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set())
  const [lastClickedId, setLastClickedId] = useState<number | null>(null)

  const toggle = useCallback((id: number) => {
    setSelectMode(true)
    setLastClickedId(id)
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

  const selectAll = useCallback((books: ReadonlyArray<{ id: number }>) => {
    setSelectMode(true)
    setSelectedIds(new Set(books.map((b) => b.id)))
  }, [])

  const extendTo = useCallback(
    (targetId: number, displayOrder: ReadonlyArray<number>) => {
      setSelectMode(true)
      setSelectedIds((prev) => {
        const next = new Set(prev)
        const targetIdx = displayOrder.indexOf(targetId)
        const anchorIdx = lastClickedId == null ? -1 : displayOrder.indexOf(lastClickedId)
        if (targetIdx === -1 || anchorIdx === -1) {
          next.add(targetId)
          return next
        }
        const [from, to] = anchorIdx <= targetIdx ? [anchorIdx, targetIdx] : [targetIdx, anchorIdx]
        for (let i = from; i <= to; i++) next.add(displayOrder[i])
        return next
      })
      setLastClickedId(targetId)
    },
    [lastClickedId]
  )

  const enterSelectMode = useCallback((initialId?: number) => {
    setSelectMode(true)
    if (initialId !== undefined) {
      setLastClickedId(initialId)
      setSelectedIds(new Set([initialId]))
    }
  }, [])

  const clear = useCallback(() => {
    setSelectedIds(new Set())
  }, [])

  const exitSelectMode = useCallback(() => {
    setSelectMode(false)
    setSelectedIds(new Set())
    setLastClickedId(null)
  }, [])

  return {
    selectMode,
    selectedIds,
    toggle,
    selectAll,
    extendTo,
    enterSelectMode,
    clear,
    exitSelectMode
  }
}
