// apps/electron/src/renderer/src/hooks/usePlayerMachine.ts
//
// Composition layer. Each concern lives in its own focused hook under ./player/.
// After Phase 3.5 the only top-level responsibilities are:
//   1. start the actor with optional per-format viewLogic
//   2. wire it to: machine→store sync, store→machine paragraph sync, navStore
//      bridge, PDF seed-on-mount, resume-write
//   3. return a stable send for callers
import { usePlayerActor, type UsePlayerActorOptions } from '@/hooks/player/usePlayerActor'
import { useMachineToStoreSync } from '@/hooks/player/useMachineToStoreSync'
import { useParagraphSubscriptions } from '@/hooks/player/useParagraphSubscriptions'
import { useNavBridge } from '@/hooks/player/useNavBridge'
import { usePdfSeed } from '@/hooks/player/usePdfSeed'
import { useResumeWrite } from '@/hooks/player/useResumeWrite'
import { audioElement } from '@/actors/audioActor'

// Re-exported for existing consumers (E2E testing helpers, services that
// inject the singleton). The actual ownership lives in actors/audioActor.
export { audioElement }
// Re-export for the existing writePath test path.
export { startResumeWriteSubscription } from '@/hooks/player/useResumeWrite'

export type UsePlayerMachineOptions = UsePlayerActorOptions

export function usePlayerMachine(bookId: string, options?: UsePlayerMachineOptions) {
  const { actor, send } = usePlayerActor(bookId, options)
  useMachineToStoreSync(actor)
  useParagraphSubscriptions(actor, bookId)
  useNavBridge(actor)
  usePdfSeed(actor)
  useResumeWrite(bookId)
  return { send }
}
