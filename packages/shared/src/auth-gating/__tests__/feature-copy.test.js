/**
 * Phase 1 — FEATURE_COPY contract.
 *
 * `FEATURE_COPY` is the single source of truth for premium-gate prompt
 * copy across electron and mobile. The shape (title / body / cta) is
 * platform-agnostic; per-platform additions (icons on electron, Ionicons
 * name on mobile) live in platform shims.
 *
 * Copy rules — kept restrained per the UI spec (Apple Books philosophy):
 *   - Every title begins with "Sign in to …" so the verb tells the user
 *     exactly what tapping the CTA will do.
 *   - Every body is a single sentence ending with a period.
 *   - No body contains the standalone token " AI " — copy stays plain.
 */
import { describe, it, expect } from 'vitest';
import { FEATURE_COPY } from '../featureCopy';
const ALL_FEATURES = [
    'tts',
    'ai-chat',
    'voice-chat',
    'voice-input',
    'sync',
    'ai-generic',
];
describe('FEATURE_COPY (shared/auth-gating)', () => {
    it('has an entry for every PremiumFeature key', () => {
        for (const feature of ALL_FEATURES) {
            expect(FEATURE_COPY[feature]).toBeDefined();
        }
    });
    it('every entry has non-empty title, body, cta strings', () => {
        for (const feature of ALL_FEATURES) {
            const entry = FEATURE_COPY[feature];
            expect(typeof entry.title).toBe('string');
            expect(entry.title.length).toBeGreaterThan(0);
            expect(typeof entry.body).toBe('string');
            expect(entry.body.length).toBeGreaterThan(0);
            expect(typeof entry.cta).toBe('string');
            expect(entry.cta.length).toBeGreaterThan(0);
        }
    });
    it("every title starts with 'Sign in to '", () => {
        for (const feature of ALL_FEATURES) {
            expect(FEATURE_COPY[feature].title.startsWith('Sign in to ')).toBe(true);
        }
    });
    it("every body ends with '.'", () => {
        for (const feature of ALL_FEATURES) {
            expect(FEATURE_COPY[feature].body.endsWith('.')).toBe(true);
        }
    });
    it("no body contains the standalone token ' AI '", () => {
        // Plain copy — Apple Books philosophy. We allow "ai-chat" key, but
        // marketing-y " AI " spans inside the body are forbidden.
        for (const feature of ALL_FEATURES) {
            expect(FEATURE_COPY[feature].body).not.toContain(' AI ');
        }
    });
    it("tts.title is the sentinel string 'Sign in to listen'", () => {
        // Sentinel — catches accidental copy edits.
        expect(FEATURE_COPY.tts.title).toBe('Sign in to listen');
    });
    it("voice-input copy is differentiated from voice-chat (P1-S)", () => {
        // P1-S: voice-input (dictation into chat) is a distinct feature from
        // voice-chat (full realtime conversation). Copy must reflect the
        // difference so signed-out users understand what they are unlocking.
        expect(FEATURE_COPY['voice-input'].title).not.toBe(FEATURE_COPY['voice-chat'].title);
        expect(FEATURE_COPY['voice-input'].body).not.toBe(FEATURE_COPY['voice-chat'].body);
    });
    it("voice-input title is the sentinel string 'Sign in to dictate' (P1-S)", () => {
        expect(FEATURE_COPY['voice-input'].title).toBe('Sign in to dictate');
    });
});
