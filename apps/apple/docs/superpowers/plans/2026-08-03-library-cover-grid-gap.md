# Library Cover Grid Gap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent book covers in adjacent library rows from overlapping and give each row a visible vertical gap.

**Architecture:** Keep the existing fixed 2:3 cover sizing contract in `LibraryGrid`. Re-enable the cell-level aspect-ratio constraint so loaded image intrinsic dimensions cannot escape the cell, and set explicit `LazyVGrid` row spacing using the existing spacing tokens.

**Tech Stack:** SwiftUI, Swift Testing, Xcode/iOS simulator.

---

## Files and responsibilities

- Modify `apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/LibraryGrid.swift`: constrain each cover cell to the existing 2:3 portrait ratio and add explicit vertical grid spacing.
- Verify `apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/BookCoverImageView.swift`: preserve its existing full-parent frame behavior; no changes required.
- Verify `apps/apple/rishi/rishiTests/PackageTests/RishiLibrary/RishiLibraryTests/LibraryCellAspectTests.swift`: confirm the existing aspect-ratio regression coverage remains relevant.

## Task 1: Restore safe cover-cell geometry and row separation

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/LibraryGrid.swift:42-45,84-87`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiLibrary/RishiLibraryTests/LibraryCellAspectTests.swift`

- [ ] **Step 1: Reproduce the current geometry regression**

Run:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/LibraryCellAspectTests
```

Expected: the aspect-related test or UI geometry check exposes the currently unconstrained grid-cell behavior, or the test suite provides the existing regression guard for the fix.

- [ ] **Step 2: Apply the minimal layout fix**

Update the grid to pass an explicit row spacing value and restore the existing aspect-ratio modifier:

```swift
LazyVGrid(columns: columns, spacing: RishiSpacing.m) {
    ForEach(books) { book in
        cell(for: book)
    }
}
```

Inside `cell(for:)`, keep the fixed frame and add:

```swift
.aspectRatio(2.0 / 3.0, contentMode: .fit)
```

Do not change cover dimensions, image scaling, deletion behavior, or unrelated library layout.

- [ ] **Step 3: Run focused verification**

Run:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/LibraryCellAspectTests -only-testing:rishiTests/LibraryGridSizingTests
```

Expected: exit code 0 with all selected tests passing.

- [ ] **Step 4: Inspect the final diff**

Run:

```bash
git diff -- apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/LibraryGrid.swift
```

Expected: only the explicit grid row spacing and the restored aspect-ratio modifier are present for the source change.

## Adversarial review loop

Each round: review → log findings → update the plan → re-review.

### Round 1 — Research review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | A fixed outer frame alone does not prevent a loaded cover's intrinsic height from escaping; the existing `BookCoverImageView` comments identify the missing cell-level aspect constraint. | Restore `.aspectRatio(2.0 / 3.0, contentMode: .fit)` in `LibraryGrid.cell`. |
| 2 | Medium | `LazyVGrid`'s `GridItem.spacing` controls inter-column spacing, not row spacing, so it cannot satisfy the requested vertical gap. | Pass `spacing: RishiSpacing.m` to `LazyVGrid`. |
| 3 | Low | `LibraryGridSizingTests` expects width 150 while production currently uses 145. | Keep out of scope; unrelated test drift is not needed to fix overlap. |

**Round 1 result:** Re-review required for the updated plan.

### Round 2 — Plan re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | None | The plan identifies the single behavioral call site, preserves the existing cover sizing contract, and includes focused verification. | No open issues. |

**Round 2 result:** PASS — 0 open Critical/High/Medium issues.

## Consumer / call-site audit

| Consumer | Relationship | Required change |
|---|---|---|
| `LibraryView.swift` | Hosts `LibraryGrid` inside the scroll view | None; grid owns its row geometry. |
| `ReadingNowShelf.swift` | Separate horizontal cover shelf | None; it does not use `LibraryGrid`. |
| `BookCoverImageView.swift` | Renders the cover inside each grid cell | Preserve existing full-parent frame behavior. |

## Implementation order

1. Run the focused regression test.
2. Update `LibraryGrid` geometry and row spacing.
3. Re-run focused tests.
4. Inspect the diff and, if available, confirm the simulator screenshot shows a gap between rows.

## Explicitly out of scope

- Changing cover width/height constants.
- Adjusting horizontal column spacing or screen padding.
- Refactoring `BookCoverImageView`.
- Updating the unrelated 145-vs-150 sizing-test drift.
