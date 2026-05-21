/**
 * Citation chip for chat messages — mobile equivalent of electron's
 * `SourceChip` (`apps/rishi-electron/.../components/chat/SourceChip.tsx`).
 *
 * Pure label/hint formatting lives in `lib/chat/source-label.ts` so the
 * unit tests can run without the RN runtime.
 */
import { Pressable, Text } from 'react-native'
import { IconSymbol } from '@/components/ui/icon-symbol'
import type { SourceChunk } from '@/types/conversation'
import { formatSourceLabel, formatSourceHint } from '@/lib/chat/source-label'

export { formatSourceLabel, formatSourceHint }

interface SourceReferenceProps {
  source: SourceChunk
  onPress: () => void
}

export function SourceReference({ source, onPress }: SourceReferenceProps) {
  const label = formatSourceLabel(source)
  const hint = formatSourceHint(source)

  return (
    <Pressable
      onPress={onPress}
      className="flex-row items-center bg-gray-200 dark:bg-gray-700 rounded-full px-2 py-1"
      style={({ pressed }) => ({ opacity: pressed ? 0.7 : 1 })}
      accessibilityLabel={label}
      accessibilityHint={hint}
      accessibilityRole="button"
    >
      <IconSymbol name="book.fill" size={12} color="#687076" />
      <Text className="text-xs text-gray-700 dark:text-gray-300 ml-1">{label}</Text>
    </Pressable>
  )
}
