// AIChatOrb status → color map. Shared by electron (source of truth) and
// mobile Phase 4. Values transcribed verbatim from
// apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx L30-41.
export const ORB_COLORS = {
    idle: 'rgba(88, 86, 214, 0.70)',
    connecting: 'rgba(59, 130, 246, 0.80)',
    thinking: 'rgba(251, 191, 36, 0.80)',
    speaking: 'rgba(34, 197, 94, 0.80)',
};
// WGT-013 — disk-tint companion map. The orb's glass disk is tinted with the
// same hue as the bars but at 0.24 alpha so the disk reads as "the dimmer,
// muted backdrop". Previously this lived as a local `ORB_TINTS` constant in
// `apps/mobile/components/chat/AIChatOrb.tsx`, which meant electron and
// mobile could drift independently. Surfacing it here gives both platforms a
// single source of truth, and the orb-colors test pins that the RGB triplet
// is identical to `ORB_COLORS[status]` for every status.
export const ORB_DISK_TINTS = {
    idle: 'rgba(88, 86, 214, 0.24)',
    connecting: 'rgba(59, 130, 246, 0.24)',
    thinking: 'rgba(251, 191, 36, 0.24)',
    speaking: 'rgba(34, 197, 94, 0.24)',
};
