import { Text, TouchableOpacity, View } from 'react-native'
import BottomSheet from '@gorhom/bottom-sheet'
import { ReaderSettings, ReaderTheme, ThemeName } from '@/types/book'
import { READER_THEMES } from '@/constants/reader-themes'

interface AppearanceSheetProps {
  sheetRef: React.RefObject<BottomSheet | null>
  settings: ReaderSettings
  theme: ReaderTheme
  onThemeChange: (name: ThemeName) => void
  onFontSizeChange: (size: number) => void
  onFontFamilyChange: (family: 'serif' | 'sans-serif') => void
}

const THEME_NAMES: ThemeName[] = ['white', 'dark', 'yellow']
const MIN_FONT_SIZE = 80
const MAX_FONT_SIZE = 150
const FONT_SIZE_STEP = 10

export function AppearanceSheet({
  sheetRef,
  settings,
  theme,
  onThemeChange,
  onFontSizeChange,
  onFontFamilyChange,
}: AppearanceSheetProps) {
  return (
    <BottomSheet
      ref={sheetRef}
      index={-1}
      snapPoints={[280]}
      enablePanDownToClose
      backgroundStyle={{ backgroundColor: theme.background }}
      handleIndicatorStyle={{ backgroundColor: theme.color, width: 36, height: 4 }}
    >
      <View className="px-6 pt-2 pb-6">
        <Text style={{ color: theme.color }} className="text-lg font-semibold mb-4">
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
                    borderColor: isActive ? '#0a7ea4' : t.swatchBorder,
                  }}
                />
                <Text style={{ color: theme.color }} className="text-xs mt-1">
                  {t.label}
                </Text>
              </TouchableOpacity>
            )
          })}
        </View>

        {/* Font size control */}
        <Text style={{ color: theme.color }} className="text-sm font-semibold mb-2">
          Text Size
        </Text>
        <View className="flex-row items-center justify-center gap-4 mb-4">
          <TouchableOpacity
            className="w-11 h-11 rounded-lg items-center justify-center"
            style={{ backgroundColor: settings.fontSize <= MIN_FONT_SIZE ? 'transparent' : theme.toolbarBg }}
            onPress={() => {
              if (settings.fontSize > MIN_FONT_SIZE) {
                onFontSizeChange(settings.fontSize - FONT_SIZE_STEP)
              }
            }}
            disabled={settings.fontSize <= MIN_FONT_SIZE}
            accessibilityLabel="Decrease text size"
            accessibilityRole="button"
          >
            <Text style={{ color: theme.color }} className="text-xl font-bold">-</Text>
          </TouchableOpacity>
          <Text style={{ color: theme.color }} className="text-base font-semibold w-12 text-center">
            {settings.fontSize}%
          </Text>
          <TouchableOpacity
            className="w-11 h-11 rounded-lg items-center justify-center"
            style={{ backgroundColor: settings.fontSize >= MAX_FONT_SIZE ? 'transparent' : theme.toolbarBg }}
            onPress={() => {
              if (settings.fontSize < MAX_FONT_SIZE) {
                onFontSizeChange(settings.fontSize + FONT_SIZE_STEP)
              }
            }}
            disabled={settings.fontSize >= MAX_FONT_SIZE}
            accessibilityLabel="Increase text size"
            accessibilityRole="button"
          >
            <Text style={{ color: theme.color }} className="text-xl font-bold">+</Text>
          </TouchableOpacity>
        </View>

        {/* Font family toggle */}
        <View className="flex-row rounded-lg overflow-hidden h-11">
          <TouchableOpacity
            className="flex-1 items-center justify-center"
            style={{
              backgroundColor: settings.fontFamily === 'serif' ? '#0a7ea4' : 'transparent',
            }}
            onPress={() => onFontFamilyChange('serif')}
            accessibilityRole="button"
            accessibilityLabel="Serif font"
            accessibilityState={{ selected: settings.fontFamily === 'serif' }}
          >
            <Text
              style={{ color: settings.fontFamily === 'serif' ? '#FFFFFF' : theme.color }}
              className="text-sm font-semibold"
            >
              Serif
            </Text>
          </TouchableOpacity>
          <TouchableOpacity
            className="flex-1 items-center justify-center"
            style={{
              backgroundColor: settings.fontFamily === 'sans-serif' ? '#0a7ea4' : 'transparent',
            }}
            onPress={() => onFontFamilyChange('sans-serif')}
            accessibilityRole="button"
            accessibilityLabel="Sans-serif font"
            accessibilityState={{ selected: settings.fontFamily === 'sans-serif' }}
          >
            <Text
              style={{ color: settings.fontFamily === 'sans-serif' ? '#FFFFFF' : theme.color }}
              className="text-sm font-semibold"
            >
              Sans
            </Text>
          </TouchableOpacity>
        </View>
      </View>
    </BottomSheet>
  )
}
