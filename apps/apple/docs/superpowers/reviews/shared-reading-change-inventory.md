# Shared Reading Change Inventory

Recorded: 2026-09-16 (Africa/Kampala)

## Immutable identities

- Feature HEAD: `a091cf1e3fe033395e855e15a3fa5a940dcb291e`
- Refreshed `origin/main`: `70557b0631bff63e495d2dd3244b1da5950a5cc1`
- Merge base: `70557b0631bff63e495d2dd3244b1da5950a5cc1`
- Scope-cleanup commit: `a091cf1e3`
- Recovery backup branch: `codex/backup-shared-reading-pre-main-merge`
- Full restored-work backup: `stash@{0}` at inventory time

The merge base exactly equals refreshed `origin/main`. Electron is explicitly outside this feature. The committed feature range was narrowed from 245 paths to the reviewed shared-reading boundary before this inventory.

## Classification rules

- **ADOPT_AND_REPAIR**: required implementation or focused verification work, not yet accepted as correct.
- **REPLACE_ON_PARITY**: Node MCP deletion and Swift MCP replacement; commit only after tool-contract parity, registration, and live Codex evidence.
- **QUARANTINE**: preserve but do not commit until the named plan establishes its constrained role.
- **EXCLUDE**: never stage or commit on this branch.

Every current dirty or untracked path appears exactly once below.

## ADOPT_AND_REPAIR

- `apps/apple/rishi/rishi/Account/AccountDeletionCoordinator.swift`
- `apps/apple/rishi/rishi/Auth/SignedOutView.swift`
- `apps/apple/rishi/rishi/Auth/SignedOutViewModel.swift`
- `apps/apple/rishi/rishi/Library/LibraryRootView.swift`
- `apps/apple/rishi/rishi/Library/LibraryTabView.swift`
- `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Endpoints/AuthAPI.swift`
- `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/RishiAPI/WorkerClient.swift`
- `apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/LibraryGrid.swift`
- `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift`
- `apps/apple/rishi/rishi/Reader/ReaderDestination.swift`
- `apps/apple/rishi/rishi/Reader/ReaderDestinationView.swift`
- `apps/apple/rishi/rishi/RootView.swift`
- `apps/apple/rishi/rishi/ServiceGraphFactory.swift`
- `apps/apple/rishi/rishi/SharedReading/ActiveReadingSessionsView.swift`
- `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionView.swift`
- `apps/apple/rishi/rishi/SharedReading/SharedReadingShareComposerView.swift`
- `apps/apple/rishi/rishi/SystemIntegration/RishiAppIntentRuntime.swift`
- `apps/apple/rishi/rishi/rishiApp.swift`
- `apps/apple/rishi/rishiTests/PackageTests/RishiAPI/RishiAPITests/EndpointCodableTests.swift`
- `apps/apple/rishi/rishiTests/PackageTests/RishiAuth/RishiAuthTests/DerivedUserIDTests.swift`
- `apps/apple/rishi/rishiTests/PackageTests/RishiLibrary/RishiLibraryTests/ImportCoordinatorTests.swift`
- `apps/apple/rishi/rishiTests/SignedOutViewModelTests.swift`
- `apps/apple/rishi/rishiUITests/MCPControlUITests.swift`
- `apps/apple/rishi/rishiUITests/SharedReadingInviteURLTests.swift`
- `apps/apple/rishi/rishiUITests/SharedReadingOwnerUITests.swift`
- `apps/apple/rishi/rishiUITests/SharedReadingParticipantUITests.swift`
- `apps/apple/rishi/rishiUITests/SharedReadingTestSupport.swift`
- `workers/sharing-worker/package.json`
- `workers/sharing-worker/src/AppleSessionRoom.ts`
- `workers/sharing-worker/src/auth.ts`
- `workers/sharing-worker/src/hmac.ts`
- `workers/sharing-worker/src/index.ts`
- `workers/sharing-worker/test/versioned-apple-route.test.ts`
- `workers/sharing-worker/tsconfig.json`
- `workers/worker/package.json`
- `workers/worker/src/account-deletion.integration.test.ts`
- `workers/worker/src/account-deletion.ts`
- `workers/worker/src/auth.test.ts`
- `workers/worker/src/auth.ts`
- `workers/worker/src/durable-objects/user-usage-ledger/ledger.ts`
- `workers/worker/src/index.ts`
- `workers/worker/src/routes/test-auth.test.ts`
- `workers/worker/src/session-sharing-service.test.ts`
- `workers/worker/src/session-sharing-service.ts`
- `workers/worker/wrangler.jsonc`

## REPLACE_ON_PARITY

- `apps/apple/rishi-mcp/Package.swift`
- `apps/apple/rishi-mcp/README.md`
- `apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift`
- `apps/apple/rishi-mcp/Sources/RishiAppleMCP/InstanceRegistry.swift`
- `apps/apple/rishi-mcp/Sources/RishiAppleMCP/MCPProtocol.swift`
- `apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift`
- `apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourcePreflight.swift`
- `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift`
- `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XcodeToolchain.swift`
- `apps/apple/rishi-mcp/Sources/RishiAppleMCP/main.swift`
- `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift`
- `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/InstanceRegistryTests.swift`
- `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift`
- `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift`
- `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ResourcePreflightTests.swift`
- `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift`
- `apps/apple/rishi-mcp/package.json`
- `apps/apple/rishi-mcp/src/app-tools.mjs`
- `apps/apple/rishi-mcp/src/index.mjs`
- `apps/apple/rishi-mcp/src/instance-registry.mjs`
- `apps/apple/rishi-mcp/src/memory.mjs`
- `apps/apple/rishi-mcp/src/protocol.mjs`
- `apps/apple/rishi-mcp/src/xcode-toolchain.mjs`
- `apps/apple/rishi-mcp/src/xctest-driver.mjs`
- `apps/apple/rishi-mcp/test/app-tools.test.mjs`
- `apps/apple/rishi-mcp/test/instance-registry.test.mjs`
- `apps/apple/rishi-mcp/test/protocol.test.mjs`
- `apps/apple/rishi-mcp/test/server.test.mjs`
- `apps/apple/rishi-mcp/test/xcode-toolchain.test.mjs`
- `apps/apple/rishi-mcp/test/xctest-driver.test.mjs`

Parity gate: one Swift stdio entrypoint, Node tool-contract parity, Swift tests, real Codex registration test, and successful read-only plus semantic tool calls. Until then the tracked Node deletion is not committable.

## QUARANTINE

- `apps/apple/rishi-e2e-host/Package.swift`
- `apps/apple/rishi-e2e-host/README.md`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/FixtureBookProvisioner.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ProcessRunner.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/RealBookFixtures.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/RendezvousManifest.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/RendezvousRelay.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourcePreflight.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingHost.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/TestAccountClient.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHostCLI/main.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/FixtureBookProvisionerTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ProcessRunnerTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/RealBookFixturesTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/RendezvousRelayTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourcePreflightTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingHostTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/TestAccountClientTests.swift`
- `workers/sharing-worker/pnpm-lock.yaml`
- `workers/sharing-worker/pnpm-workspace.yaml`

The E2E host may move to ADOPT_AND_REPAIR only after M2/M4 make it preparation/evidence-only and MCP remains the sole process/action owner. Sharing lock/workspace churn remains excluded from commits unless a reviewed package-manager decision requires it.

## EXCLUDE

- `apps/apple/marketing/iphone-preview/capture_simulator.sh`
- `apps/rishi-electron/.test-reports/playwright-baseline.txt`
- `apps/rishi-electron/.test-reports/vitest-baseline.txt`
- `rishi-catalyst-after-auth-fix.png`
- `rishi-catalyst-auth-context.png`
- `rishi-catalyst-auth-context2.png`
- `rishi-catalyst-auth-context3.png`
- `rishi-catalyst-auth-context4.png`
- `rishi-catalyst-auth-context5.png`
- `rishi-catalyst-auth-context6.png`
- `rishi-catalyst-auth-context7.png`
- `rishi-catalyst-auth-front.png`
- `rishi-catalyst-auth-front2.png`
- `rishi-catalyst-auth-front3.png`
- `rishi-catalyst-context-correct.png`
- `rishi-catalyst-context-final.png`
- `rishi-catalyst-context-hid.png`
- `rishi-catalyst-context-original.png`
- `rishi-catalyst-context-test.png`
- `rishi-catalyst-control-test.png`
- `rishi-catalyst-current.png`
- `rishi-catalyst-current2.png`
- `rishi-catalyst-error.png`
- `rishi-catalyst-final-menu.png`
- `rishi-catalyst-final-menu2.png`
- `rishi-catalyst-fresh-only.png`
- `rishi-catalyst-menu-now.png`
- `rishi-catalyst-reopened.png`
- `rishi-catalyst-reopened2.png`
- `rishi-iphone-auth-join.png`
- `rishi-iphone-current.png`
- `rishi-iphone-final-join.png`
- `rishi-iphone-final-join2.png`
- `rishi-iphone-rishi-url.png`
- `rishi-iphone-session.png`

## Adversarial review record

- Terra scope review: **BLOCK** on the original 245-path range; it identified the unfinished MCP replacement, second E2E control plane, broad 145-file Apple repair, Watch hunk, package-manager churn, and excluded evidence.
- Luna cleanup review: **BLOCK** on the first narrowing pass; it found missing shared reader position, book repair, verified import hash, upload hash/size, two endpoint-centralization regressions, and leftover local-Worker companion files.
- Corrections verified directly: all four shared-reading/book contracts are present, the two fallback endpoint paths are absent, and the local-Worker companion paths are absent from the resulting `origin/main` diff.
- Luna’s independent final re-review could not run because its usage limit was exhausted. No PASS is claimed; the next lane must begin with a fresh independent re-review when capacity is available.

## Staging rule

Only exact paths promoted through their W/A/M plan lane may be staged. Excluded and quarantined paths stay unstaged. The manifest is an allowlist, not evidence that implementation is correct.

