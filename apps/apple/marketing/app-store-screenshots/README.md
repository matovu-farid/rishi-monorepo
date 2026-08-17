# Rishi iPhone App Store screenshots

This folder contains the reproducible renderer for the first iPhone-only App Store screenshot set.

## Output

The renderer writes four portrait screenshots to `apps/apple/fastlane/screenshots/en-US/iphone_6_9/`:

1. Library — “Your whole library, finally in one place”
2. Reader controls — “Make every page feel yours”
3. Read Aloud — “Natural voices, hands free”
4. Highlights — “Highlight ideas in one tap”

Each PNG is `1320×2868`, the current accepted portrait size for the iPhone 17 Pro Max / 6.9-inch App Store screenshot family. The source plates are the validated `1206×2622` iPhone 17 Pro simulator captures under `/private/tmp`.

## Render

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple/marketing/app-store-screenshots
swift render.swift
```

The composition preserves the app UI as the proof layer and adds a restrained editorial card using the app’s existing warm tan brand accent (`#A58163`) and paper surface. It does not add unsupported claims, competitor imagery, or fake product UI.
