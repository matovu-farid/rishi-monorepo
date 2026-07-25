# Rishi Google AI Lab Pitch Deck Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Apply the approved Bright Product Brief visual system to the existing editable Google Slides pitch deck and verify the rendered result.

**Architecture:** Google Drive/Slides remains the source of truth. Use Slides batch updates for repeatable typography, colors, backgrounds, shapes, and text; use the in-app browser for visual inspection and any image positioning that needs direct manipulation. Preserve the existing embedded demo and Drive-backed screenshots.

**Tech Stack:** Google Slides API through the connected Google Drive tool; Codex in-app browser; existing presentation ID `1WT_cbOeyWhsLhFoWh4trsuFUuvGs0ZNeE3t_ywBjrLI`.

---

### Task 1: Establish the Bright Product Brief visual system

**Files:** Existing Google Slides presentation only.

- [ ] Set slide backgrounds to warm paper `#F4F1EA` for narrative slides and deep navy `#0E1C2B` for the cover and Product Demo slide.
- [ ] Set primary text to navy `#142131`, secondary text to slate `#496174`, and accent rules/kickers to cobalt `#376F8D`.
- [ ] Use Aptos Display or Georgia for large headlines, Aptos for body copy, and consistent text sizes: 28–32 pt headlines, 16–18 pt body, 9–11 pt kicker/footer.
- [ ] Apply the same footer treatment on every slide: `RISHI  •  GOOGLE AI LAB  •  FIRST DRAFT`, using slate or muted blue with enough contrast against the background.

### Task 2: Tighten slide hierarchy and copy layout

**Files:** Existing Google Slides presentation, slides 1–12 as currently ordered.

- [ ] Keep one clear headline per slide and shorten supporting copy so no paragraph crosses into the screenshot/video area.
- [ ] Replace dense technical lists with compact benefit-led groups: contextual conversations, grounded explanations, search/revisit, and multimodal reading/listening.
- [ ] Maintain the factual boundaries: launch-stage, pre-revenue, no fabricated metrics, and placeholders only for App Store status/date and founder details.
- [ ] Make the cover a single strong promise with a small logo and one-line supporting statement.
- [ ] Keep Product Demo focused on the embedded video and a three-step line: open a book → read/listen → ask in context.

### Task 3: Improve evidence slide composition

**Files:** Existing Google Slides presentation.

- [ ] Align the library, text-to-speech, and reader screenshots to a consistent right-side device column with equal visual scale.
- [ ] Add subtle navy/cobalt framing or captions around screenshots without obscuring product UI.
- [ ] Keep the embedded demo video on the Product Demo slide and ensure its thumbnail does not collide with text.
- [ ] Use small rounded cards for the Apple-first go-to-market and launch-measurement slides so those slides scan quickly.

### Task 4: Browser verification and final cleanup

**Files:** Existing Google Slides presentation.

- [ ] Inspect the cover, problem, product screenshot, TTS screenshot, Product Demo, Apple-first, Measurement, and Ask slides in the signed-in browser.
- [ ] Check for clipped text, low contrast, inconsistent margins, accidental placeholders, and overlaps with media.
- [ ] Confirm the document status is saved to Drive and the presentation still has the embedded video and three product screenshots.
- [ ] Retrieve the final presentation text and confirm no unsupported metrics or stale placeholder wording was introduced.

## Verification

- The deck uses the approved warm-canvas/navy/cobalt palette.
- The visual hierarchy is consistent across the full deck.
- Product evidence remains prominent and legible.
- The embedded demo remains playable.
- The deck remains editable and saved to Drive.
