import React, { useCallback, useEffect, useMemo, useRef } from 'react'
import { View, Text, StyleSheet } from 'react-native'
import BottomSheet, {
  BottomSheetBackdrop,
  BottomSheetScrollView,
  BottomSheetView,
  type BottomSheetBackdropProps,
} from '@gorhom/bottom-sheet'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { useTheme } from '@/lib/theme'
import { Hairline } from './Hairline'

export type SheetProps = {
  isOpen: boolean
  onClose: () => void
  snapPoints?: Array<string | number>
  enableDynamicSizing?: boolean
  children: React.ReactNode
  title?: string
  accessibilityLabel?: string
  showGrabber?: boolean
  scrollable?: boolean
  detent?: 'compact' | 'medium' | 'large'
}

const DETENT_SNAP: Record<NonNullable<SheetProps['detent']>, string[]> = {
  compact: ['35%'],
  medium: ['60%'],
  large: ['90%'],
}

export function Sheet({
  isOpen,
  onClose,
  snapPoints,
  enableDynamicSizing,
  children,
  title,
  accessibilityLabel,
  showGrabber = true,
  scrollable = false,
  detent,
}: SheetProps): React.JSX.Element {
  const { colors, spacing, typography, radius } = useTheme()
  const insets = useSafeAreaInsets()
  const sheetRef = useRef<BottomSheet>(null)

  const resolvedSnapPoints = useMemo(() => {
    if (snapPoints) return snapPoints
    if (detent) return DETENT_SNAP[detent]
    return undefined
  }, [snapPoints, detent])

  const dynamicSizing =
    enableDynamicSizing ?? resolvedSnapPoints === undefined

  useEffect(() => {
    if (isOpen) {
      sheetRef.current?.expand()
    } else {
      sheetRef.current?.close()
    }
  }, [isOpen])

  const handleChange = useCallback(
    (index: number) => {
      if (index === -1) onClose()
    },
    [onClose],
  )

  const renderBackdrop = useCallback(
    (props: BottomSheetBackdropProps) => (
      <BottomSheetBackdrop
        {...props}
        appearsOnIndex={0}
        disappearsOnIndex={-1}
        pressBehavior="close"
      />
    ),
    [],
  )

  const Container = scrollable ? BottomSheetScrollView : BottomSheetView
  const titleStyle = typography.scale.title

  return (
    <BottomSheet
      ref={sheetRef}
      index={isOpen ? 0 : -1}
      enablePanDownToClose
      enableDynamicSizing={dynamicSizing}
      snapPoints={resolvedSnapPoints}
      onChange={handleChange}
      backdropComponent={renderBackdrop}
      handleIndicatorStyle={{
        // VIS-009: native iOS grabber is 36pt × 5pt at quaternaryLabel —
        // crisper than `fill.tertiary` (~12% gray) and matches UIKit.
        backgroundColor: colors.label.quaternary,
        width: 36,
        height: 5,
        ...(showGrabber ? null : { height: 0, opacity: 0 }),
      }}
      backgroundStyle={{
        // VIS-009: Apple sheets land on `systemBackground` (white in light
        // mode) with the canonical 22pt top corner radius. The previous
        // value (`background.secondary` ≈ grouped grey) read as a panel.
        backgroundColor: colors.background.primary,
        borderTopLeftRadius: radius.sheet,
        borderTopRightRadius: radius.sheet,
      }}
      accessibilityLabel={accessibilityLabel ?? title}
      accessibilityViewIsModal
    >
      <Container
        style={{
          paddingHorizontal: spacing.lg,
          paddingBottom: insets.bottom + spacing.lg,
        }}
      >
        {title ? (
          <View style={styles.titleRow}>
            <Text
              accessibilityRole="header"
              style={{
                fontSize: titleStyle.fontSize,
                lineHeight: titleStyle.lineHeight,
                fontWeight: titleStyle.fontWeight,
                color: colors.label.primary,
                textAlign: 'center',
              }}
            >
              {title}
            </Text>
            <Hairline style={{ marginTop: spacing.md }} />
          </View>
        ) : null}
        {children}
      </Container>
    </BottomSheet>
  )
}

const styles = StyleSheet.create({
  titleRow: {
    paddingVertical: 16,
  },
})
