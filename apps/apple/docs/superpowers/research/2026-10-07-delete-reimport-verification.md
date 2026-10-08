# Delete/reimport verification

This records native evidence separately from source review. The connected phone's production library must not be reset or used by hosted tests.

## Baseline evidence

Before the new delete/reimport and permanent-identity revision, the optimistic deletion suite passed 145 tests in 12 suites: `/tmp/rishi-optimistic-deletion-native-tests.log`. This is baseline evidence, not execution of the newly added regression cases. Earlier cover/TTS work has its own final evidence in `../plans/2026-10-06-import-cover-tts-implementation-review.md`.

## Previous installed revision

| Check | Evidence | Result |
|---|---|---|
| Initial integrated Simulator build | `/tmp/rishi-delete-reimport-app-build.log` | Failed due to disk exhaustion before app compilation. |
| Simulator build after cache reclamation | `/tmp/rishi-delete-reimport-simulator-test-build-reclaimed.log` | Failed on a test fixture calling a metadata factory API added concurrently after module compilation. Current source has the API. |
| Simulator retry | `/tmp/rishi-delete-reimport-simulator-test-build-retry.log` | Metadata factory mismatch resolved; app compilation failed on non-Sendable source lifetime captured by detached PDF narration task. Narrow repair pending. |
| Signed iPhone app before review corrections | `/tmp/rishi-delete-reimport-device-build.log` | Passed. |
| Signed iPhone app after first two corrections | `/tmp/rishi-delete-reimport-device-build-r2.log` | Passed, exit 0. |
| Cancellation cleanup revision | `/tmp/rishi-delete-reimport-device-build-r3.log` | Failed on a concurrent reader cancellation-closure Swift concurrency error. |
| First narrow compile repair | `/tmp/rishi-delete-reimport-device-build-r3-retry.log` | First diagnostic resolved; failed on a concurrent position persistence closure escaping-contract mismatch. |
| Native test target compile only | `/tmp/rishi-delete-reimport-device-test-compile.log` | TEST BUILD SUCCEEDED, exit 0. Production app and full native test target compiled signed for iPhone. No tests executed. |
| New regression execution | Simulator | Not executed; user subsequently requested to perform behavioral verification themselves. |
| Catalyst build | Native compiler | Not rerun; user requested focus on correction and manual verification. |
| Final signed production build | `/tmp/rishi-delete-reimport-device-final-build.log` | BUILD SUCCEEDED, exit 0. |
| Final phone install/launch | `devicectl` | Installed and launched, exit 0; PID 44968, container `90298D6B-C773-4B9D-8863-1E07B83430E2`. App data preserved. |

The two compiler repairs preserve the concurrent reader implementation and have separate one-line patches in `/tmp/rishi-reader-cancellation-compile.patch` and `/tmp/rishi-reader-position-closure-compile.patch`. Global isolation and reading engines are unchanged.

The passing compile-only build incorporates the cancellation cleanup correction and resolves both compiler diagnostics. Independent implementation round 3 passed with zero open Critical/High/Medium findings. `DeleteReimportPersistenceTests` now contains 26 cases, including six preparation/returned-token cancellation cases across live, deleted, and changed-account outcomes; compilation does not establish their runtime results.

The iPhone native build cache can compile test fixtures without running them. Physical hosted execution is unsuitable: normal app startup opens the real Documents database and performs normal bootstrap. Do not use account-reset or fake-account launch arguments. Actual regression execution belongs on Simulator.

## Device failure after installation

The user tested the installed revision and confirmed both failures persist. The new alert explicitly reports deletion in progress even after a minute, and The Kybalion returns after app restart. This supersedes any earlier source-review inference of a resolved deletion.

Read-only device snapshots were copied to `/private/tmp/rishi-device-delete-diagnostic`. For Kybalion `E9CF26D2-1724-5A03-A0FE-4E8BA3284456`, account generation 77:

- Documents database retains the canonical Book and a ready materialization; reading authorization is neither revoked nor tombstoned.
- App-group sync metadata retains Book dirty=1, tombstone=0.
- The actual deletion call chain awaits recovery/materialization/promotion/index/source effects and owner lifetime before `markBookDeleted`. The persisted evidence confirms the operation has not reached that durable commit; it does not identify the specific in-memory holder.

## Current correction and verification scope

Persist logical deletion before waiting on source lifetimes. Keep real drain barriers before deleting physical bytes. Retained old pending jobs must not block same-file imports under fresh IDs. Independent research/plan/implementation review and a fresh signed iPhone compile/install remain required. No forced source release or elapsed-time permission is used.

The user explicitly requested to focus on the fix and said they will perform behavioral verification. Broad Simulator/Catalyst and cross-device behavioral checks are no longer a pending handoff gate. Never execute hosted tests against the phone's real library or reset its data.

## Manual phone handoff

After the corrected app is installed, the user will check that deleting The Kybalion persists across app restart and that importing the same file succeeds while any old file cleanup is still draining. Compilation and installation establish delivery, not those runtime results.

## Durable-first correction delivery evidence

- Research and plan reviewed independently; plan partial-save High was fixed and re-reviewed.
- Initial fresh signed correction compiled after two narrow compiler repairs (Foundation import and explicit Sendable tombstone lookup), `/tmp/rishi-durable-first-signed-build-r3.log`, BUILD SUCCEEDED exit 0.
- Implementation review found three High gaps: prior-generation native authorization rejection, unrestricted canonical upsert ignoring retained deny, and non-local retirement/compatibility rollback overwriting or reopening local deletion. All fixed and independently re-reviewed; final report `2026-10-07-durable-first-deletion-review.md` PASS 0 open Critical/High/Medium.
- Final signed compiled input is isolated at `/private/tmp/rishi-durable-first-compile`; all 688 production input hashes remained unchanged during build. This preserves the exact previously compiled WorkerClient input while another chat refactors the live file; no live foreign source was reverted.
- Final signed build `/tmp/rishi-durable-first-final-signed-build-r2.log`: BUILD SUCCEEDED, exit 0, includes all three review corrections.
- Ready app `/private/tmp/rishi-durable-first-delivery/rishi.app` (170 MB), preserved separately from shared build products. Completed compiler intermediates were reclaimed only after compilation and process checks, signed products/source/logs retained.
- Added focused real-storage held-source regression `DeleteReimportPersistenceTests.logicalDeletionBeforeHeldSourceRelease`; syntax parsing passed. Optional native fixture compilation failed on concurrent WorkerClient helper refactoring before test compilation. No regression tests executed. User owns runtime verification.
- Device installation is pending: `devicectl` repeatedly reports iPhone `00008150-000A05363E52401C` unavailable. Async reconnect/unlock request is pending. No reset, uninstall, hosted execution, or app data deletion occurred.

## 2026-10-08 physical-device delivery

The user confirmed the iPhone was available. `devicectl` reported `00008150-000A05363E52401C` available (paired). Independent `codesign --verify --deep --strict` on the preserved reviewed app passed exit 0. Initial device connection reset was transient; a device-info handshake passed and retry installed successfully, exit 0.

- Installed bundle: `org.fidexa.rishi`, container `F47D7004-81FA-4591-9112-CD1F8B466C31`.
- Launch: `devicectl device process launch --terminate-existing org.fidexa.rishi`, exit 0.
- Authoritative process check: PID `1360` running that installed container's `rishi.app/rishi`.
- Delivery artifact: `/private/tmp/rishi-durable-first-delivery/rishi.app`, final independently reviewed signed snapshot. No rebuild, uninstall, reset, hosted tests, or manual modification of phone library data.

Assistant implementation/build/review/install/launch work is complete. The user explicitly owns deletion, same-file reimport, restart, cover and TTS behavioral verification; successful installation/launch does not establish those runtime results.

## 2026-10-08 user confirmation

After testing the installed update, the user reported “That works” and requested a commit. This supplies the manual behavioral confirmation for the deletion/reimport fix. No additional automated runtime results are claimed.
