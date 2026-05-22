import React, { useEffect, useRef } from 'react'
import { Text, TouchableOpacity, View } from 'react-native'
import BottomSheet from '@gorhom/bottom-sheet'
import {
  ReaderSettings,
  ReaderTheme,
  ThemeName,
} from '@/types/book'
import { READER_THEMES } from '@/constants/reader-themes'
import { useTheme } from '@/lib/theme'
import type { ReaderFormat } from '@/components/reader/ReaderShell'

/**
 * AppearanceSheet — dual-API during the Phase 3 reader-UI migration.
 *
 * New callers pass {isOpen, onClose, format}. Legacy callers still pass
 * {sheetRef, theme}; both branches render the same body. Once every
 * caller adopts the new shape (Phase 6), the legacy props can be removed.
 */
interface AppearanceSheetProps {
  // New API
  isOpen?: boolean
  onClose?: () => void
  format?: ReaderFormat

  // Legacy API (deprecated)
  sheetRef?: React.RefObject<BottomSheet | null>
  theme?: ReaderTheme

  // Always required
  settings: ReaderSettings
  onThemeChange: (name: ThemeName) => void
  onFontSizeChange: (size: number) => void
  onFontFamilyChange: (family: 'serif' | 'sans-serif') => void
}

const THEME_NAMES: ThemeName[] = ['white', 'dark', 'yellow']
const MIN_FONT_SIZE = 80
const MAX_FONT_SIZE = 150
const FONT_SIZE_STEP = 10

export function AppearanceSheet({
  isOpen,
  onClose,
  format,
  sheetRef: externalSheetRef,
  theme,
  settings,
  onThemeChange,
  onFontSizeChange,
  onFontFamilyChange,
}: AppearanceSheetProps) {
  const { colors } = useTheme()
  const internalRef = useRef<BottomSheet>(null)
  const sheetRef = externalSheetRef ?? internalRef

  // Sync new `isOpen` flag into the imperative sheet ref.
  useEffect(() => {
    if (typeof isOpen !== 'boolean') return
    if (isOpen) sheetRef.current?.snapToIndex(0)
    else sheetRef.current?.close()
  }, [isOpen, sheetRef])

  // Hide font family picker for non-EPUB formats per UI-SPEC §2.
  const showFontFamily = format == null || format === 'epub'

  const sheetBg = theme?.background ?? colors.background.secondary
  const textColor = theme?.color ?? colors.label.primary
  const indicatorColor = theme?.color ?? colors.fill.tertiary
  const buttonBg = theme?.toolbarBg ?? colors.fill.secondary

  return (
    <BottomSheet
      ref={sheetRef}
      index={typeof isOpen === 'boolean' ? (isOpen ? 0 : -1) : -1}
      snapPoints={[280]}
      enablePanDownToClose
      onChange={(index) => {
        if (index === -1) onClose?.()
      }}
      backgroundStyle={{ backgroundColor: sheetBg }}
      handleIndicatorStyle={{ backgroundColor: indicatorColor, width: 36, height: 4 }}
    >
      <View className="px-6 pt-2 pb-6">
        <Text style={{ color: textColor }} className="text-lg font-semibold mb-4">
          Appearance
        </Text>

        {/* Theme swatches */}
        <View className="flex-row justify-center gap-6 mb-6">
          {THEME_NAMES.map((name) => {
            const t = READER_THEMES[name]
            const isActive = settings.themeName === name
            return (
              <TouchableOpacity
                key={name}
                onPress={() => onThemeChange(name)}
                className="items-center"
                accessibilityRole="button"
                accessibilityLabel={`${t.label} theme`}
                accessibilityState={{ selected: isActive }}
              >
                <View
                  style={{
                    width: 40,
                    height: 40,
                    borderRadius: 20,
                    backgroundColor: t.swatchColor,
                    borderWidth: isActive ? 2 : 1,
                    borderColor: isActive ? colors.accent.primary : t.swatchBorder,
                  }}
                />
                <Text style={{ color: textColor }} className="text-xs mt-1">
                  {t.label}
                </Text>
              </TouchableOpacity>
            )
          })}
        </View>

        {/* Font size control */}
        <Text style={{ color: textColor }} className="text-sm font-semibold mb-2">
          Text Size
        </Text>
        <View className="flex-row items-center justify-center gap-4 mb-4">
          <TouchableOpacity
            className="w-11 h-11 rounded-lg items-center justify-center"
            style={{ backgroundColor: settings.fontSize <= MIN_FONT_SIZE ? 'transparent' : buttonBg }}
            onPress={() => {
              if (settings.fontSize > MIN_FONT_SIZE) {
                onFontSizeChange(settings.fontSize - FONT_SIZE_STEP)
              }
            }}
            disabled={settings.fontSize <= MIN_FONT_SIZE}
            accessibilityLabel="Decrease text size"
            accessibilityRole="button"
          >
            <Text style={{ color: textColor }} className="text-xl font-bold">-</Text>
          </TouchableOpacity>
          <Text style={{ color: textColor }} className="text-base font-semibold w-12 text-center">
            {settings.fontSize}%
          </Text>
          <TouchableOpacity
            className="w-11 h-11 rounded-lg items-center justify-center"
            style={{ backgroundColor: settings.fontSize >= MAX_FONT_SIZE ? 'transparent' : buttonBg }}
            onPress={() => {
              if (settings.fontSize < MAX_FONT_SIZE) {
                onFontSizeChange(settings.fontSize + FONT_SIZE_STEP)
              }
            }}
            disabled={settings.fontSize >= MAX_FONT_SIZE}
            accessibilityLabel="Increase text size"
            accessibilityRole="button"
          >
            <Text style={{ color: textColor }} className="text-xl font-bold">+</Text>
          </TouchableOpacity>
        </View>

        {showFontFamily ? (
          <View className="flex-row rounded-lg overflow-hidden h-11">
            <TouchableOpacity
              className="flex-1 items-center justify-center"
              style={{
                backgroundColor:
                  settings.fontFamily === 'serif' ? colors.accent.primary : 'transparent',
              }}
              onPress={() => onFontFamilyChange('serif')}
              accessibilityRole="button"
              accessibilityLabel="Serif font"
              accessibilityState={{ selected: settings.fontFamily === 'serif' }}
            >
              <Text
                style={{ color: settings.fontFamily === 'serif' ? '#FFFFFF' : textColor }}
                className="text-sm font-semibold"
              >
                Serif
              </Text>
            </TouchableOpacity>
            <TouchableOpacity
              className="flex-1 items-center justify-center"
              style={{
                backgroundColor:
                  settings.fontFamily === 'sans-serif' ? colors.accent.primary : 'transparent',
              }}
              onPress={() => onFontFamilyChange('sans-serif')}
              accessibilityRole="button"
              accessibilityLabel="Sans-serif font"
              accessibilityState={{ selected: settings.fontFamily === 'sans-serif' }}
            >
              <Text
                style={{ color: settings.fontFamily === 'sans-serif' ? '#FFFFFF' : textColor }}
                className="text-sm font-semibold"
              >
                Sans
              </Text>
            </TouchableOpacity>
          </View>
        ) : null}
      </View>
    </BottomSheet>
  )
}
