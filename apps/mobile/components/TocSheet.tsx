import React, { useCallback, useEffect, useMemo, useRef } from 'react'
import { Text, TouchableOpacity, View } from 'react-native'
import BottomSheet, { BottomSheetFlatList } from '@gorhom/bottom-sheet'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { ReaderTheme } from '@/types/book'
import { useTheme } from '@/lib/theme'

interface TocItem {
  id?: string
  href: string
  label: string
  subitems?: TocItem[]
}

/**
 * RDR-020 — depth-tagged row used by the flattened renderer.
 *
 * The TOC API exposes nested `subitems`, but the rendered list is flat so
 * the BottomSheetFlatList can keyExtract / windowing cleanly. The
 * `depth` field drives indentation; `hasChildren` drives the chevron.
 */
interface FlatTocRow {
  depth: number
  hasChildren: boolean
  item: TocItem
}

/**
 * Flatten a nested TOC into a depth-tagged list. Parents come first, then
 * their children inline — matches the order users expect from Apple
 * Books / electron.
 */
function flattenToc(items: TocItem[], depth = 0): FlatTocRow[] {
  const out: FlatTocRow[] = []
  for (const item of items) {
    const hasChildren = (item.subitems?.length ?? 0) > 0
    out.push({ depth, hasChildren, item })
    if (hasChildren) {
      out.push(...flattenToc(item.subitems ?? [], depth + 1))
    }
  }
  return out
}

/**
 * TocSheet — dual-API during the Phase 3 reader-UI migration.
 *
 * New callers pass {isOpen, onClose}. Legacy callers still pass
 * {sheetRef, theme}. Both flows share the body.
 */
interface TocSheetProps {
  // New API
  isOpen?: boolean
  onClose?: () => void

  // Legacy API (deprecated)
  sheetRef?: React.RefObject<BottomSheet | null>
  theme?: ReaderTheme

  toc: TocItem[]
  currentHref: string | null
  onSelectChapter: (href: string) => void
}

export function TocSheet({
  isOpen,
  onClose,
  sheetRef: externalSheetRef,
  theme,
  toc,
  currentHref,
  onSelectChapter,
}: TocSheetProps) {
  const { colors } = useTheme()
  const internalRef = useRef<BottomSheet>(null)
  const sheetRef = externalSheetRef ?? internalRef

  useEffect(() => {
    if (typeof isOpen !== 'boolean') return
    if (isOpen) sheetRef.current?.snapToIndex(0)
    else sheetRef.current?.close()
  }, [isOpen, sheetRef])

  const sheetBg = theme?.background ?? colors.background.secondary
  const textColor = theme?.color ?? colors.label.primary
  const indicatorColor = theme?.color ?? colors.fill.tertiary
  const accent = colors.accent.primary

  // RDR-020 — flatten the nested TOC into a depth-tagged row list. The
  // `useMemo` keeps the flattener cheap as the user opens / closes the
  // sheet and re-derives currentHref.
  const rows = useMemo(() => flattenToc(toc), [toc])

  const renderItem = useCallback(
    ({ item: row }: { item: FlatTocRow }) => {
      const { item, depth, hasChildren } = row
      const isCurrent = currentHref !== null && item.href === currentHref
      // RDR-020 — indent by 16 + depth * 16 so children visually nest
      // under their parents; matches the PDF reader's OutlineList.
      const paddingLeft = 16 + depth * 16
      return (
        <TouchableOpacity
          className="h-12 flex-row items-center"
          style={[
            { paddingLeft, paddingRight: 16 },
            isCurrent ? { borderLeftWidth: 3, borderLeftColor: accent } : undefined,
          ]}
          onPress={() => onSelectChapter(item.href)}
          accessibilityRole="button"
          accessibilityLabel={item.label}
          accessibilityHint={hasChildren ? `Parent chapter, depth ${depth}` : undefined}
        >
          {hasChildren ? (
            <View style={{ marginRight: 8 }}>
              <IconSymbol name="chevron.down" size={12} color={textColor} />
            </View>
          ) : null}
          <Text
            style={{ color: textColor, flex: 1 }}
            className={`text-base ${isCurrent ? 'font-semibold' : 'font-normal'}`}
            numberOfLines={1}
          >
            {item.label}
          </Text>
        </TouchableOpacity>
      )
    },
    [currentHref, textColor, accent, onSelectChapter]
  )

  return (
    <BottomSheet
      ref={sheetRef}
      index={typeof isOpen === 'boolean' ? (isOpen ? 0 : -1) : -1}
      snapPoints={['50%', '90%']}
      enablePanDownToClose
      onChange={(index) => {
        if (index === -1) onClose?.()
      }}
      backgroundStyle={{ backgroundColor: sheetBg }}
      handleIndicatorStyle={{ backgroundColor: indicatorColor, width: 36, height: 4 }}
    >
      <View className="px-4 pb-2">
        <Text style={{ color: textColor }} className="text-lg font-semibold">
          Contents
        </Text>
      </View>
      <BottomSheetFlatList
        data={rows}
        keyExtractor={(row: FlatTocRow, i: number) =>
          row.item.id || `${row.item.href}-${i}`
        }
        renderItem={renderItem}
      />
    </BottomSheet>
  )
}
