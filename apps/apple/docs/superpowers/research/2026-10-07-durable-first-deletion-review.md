# Durable-first imported-book deletion — independent review

> Status: Research and plan review PASS; implementation review PASS (3 rounds, 0 open Critical/High/Medium findings). Behavioral verification remains with the user.

Scope: the follow-up correction after the installed app still blocked Kybalion reimport for over a minute and restored the book on restart. This does not reopen unrelated reader or architecture changes.

## Research round 1

Build evidence checked first: `/tmp/rishi-delete-reimport-device-final-build.log` contains `BUILD SUCCEEDED`. This establishes the preceding installed revision only; implementation review of the new correction requires a fresh signed build.

Confirmed call chain: `LibraryViewModel+Make.swift:63` awaits `drainBookForDeletion`; `LibraryViewModel.swift:671–674` persists the sync tombstone only after that returns. `BookImportLifecycle.swift:418–425` waits materialization, promotion, source retirement, indexing and source owners/effects. The reported typed retirement alert plus copied native/sync data (Kybalion generation 77, ready materialization, live canonical row, reading authorization not revoked/tombstoned, sync Book dirty but not tombstoned) corroborate a stalled precommit drain. They do not identify a specific retained source owner.

**Research result: PASS — 0 open findings.** The bounded conclusion is that durable deletion currently depends on a potentially unbounded source lifetime. Publish permanent logical deletion before waiting for physical source cleanup; preserve actual effect/source lifetime drain before removing bytes. Do not claim a particular source leak has been proven.

## Plan round 1 — Revision 2

Reviewed `../plans/2026-10-07-durable-first-book-deletion.md`, Revision 2. Required call-chain audit:

- Persist sync identity closure and native canonical deletion/reading authorization closure before close-reader or source-drain waits.
- Preserve old identity fences and actual entered work; defer filesystem deletion until that work ends.
- Skip permanently closed/orphan same-hash pending candidates inside native reservation, allowing a new UUID to commit.
- Hide/reconcile persisted sync tombstones on restart across the metadata/native-store crash window.
- Recover cleanup without relying solely on canonical rows, and keep old UUID cleanup separate from fresh UUID reimport.
- Handle account replacement, failure before/after tombstone, echoed inbound deletes and cleanup retry without reopening permanently deleted identities.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | High / Important | Plan lines 30–42 save the metadata tombstone before an ordinary throwing native mutation, but expose only a throwing combined callback returning a cleanup action. The VM cannot distinguish a durable partial deletion from failure before persistence. Existing `LibraryViewModel.swift:674,694–705` marks `tombstonePersisted` after successful callback return and otherwise restores a failed presentation. A native-store error after metadata save would therefore run the wrong presentation branch; retained live same-hash pending state also blocks reimport until explicit canonical reconciliation. | Specify a durable partial outcome/error or a throwing durable-state classification in the VM catch. Saved tombstones must bypass rollback/failed-visible overlays and schedule finite canonical reconciliation in the current session as well as restart. Communicated to author and root; open pending revised artifact. |

**Round 1 result: Re-review required — 1 High finding.** No other open findings. Restricting restart artifact cleanup to retained pending imports is accepted for the affected scope; no broad directory sweep is required.

## Plan round 2 — Revision 3

The revised artifact adds an exact typed saved boundary inside `applyLocalBookTombstone`: only errors after the native metadata save become `SyncBookDeletionCommitError.savedTombstone`. The combined callback maps that state to `DeletionCommitOutcome.savedNeedsReconciliation`, so both saved outcomes clear pending UI state without rollback or a failed-visible overlay. Finite current-session reconciliation and metadata-closed reservation exclusions address the native-store partial window; the native reservation retains permanent authorization denial and skips closed/orphan pending contenders.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | High / Important | Prior ordinary-error partial-save ambiguity | Closed by Revision 3’s exact saved boundary, explicit VM outcome, reconciliation action and closed-ID reservation exclusions. |

**Plan result: PASS — 2 designated review rounds, 0 open Critical/High/Medium findings.** Genuine source/effect/ARC drain remains required for physical cleanup, never for saved logical deletion. The unchanged broad build/test plan is superseded by the user’s manual behavioral verification instruction.

## Implementation review

### Round 1 — signed revision R3

Build-first evidence: root’s `/tmp/rishi-durable-first-signed-build-r3.log` reports `BUILD SUCCEEDED`, exit 0. Reviewed the frozen durable correction represented by `/tmp/rishi-durable-first-native.patch` and `/tmp/rishi-durable-first-import-sync.patch` against `/tmp/rishi-durable-deletion-baseline`; root’s exact compiled input hashes exclude a later unrelated, unfinished `WorkerClient.swift` edit. No claim that the subsequently changing live checkout builds.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | High / Important | `SwiftDataBookStore.swift:159–160` rejects logical deletion unless the existing reading authorization is already tombstoned or has the current account generation. `AppDependencies.replaceUserId` advances account generation; `authorizeAccount` updates account authorization, not every Book’s reading row. A same-owner unopened Book can therefore retain an earlier reading generation. The current authorized owner cannot reconcile its saved deletion on restart, and an inbound tombstone for that Book fails before native deletion/acknowledgement. Confidence 95%. | In the serialized permanent-deletion turn, retain the current account-generation check and expected canonical owner/CAS, but permit same-owner prior-generation reading authorization to become permanently revoked/tombstoned. Do not grant fresh reading authority to delete. Sent to native author; open. |
| 2 | High / Important | `SwiftDataBookStore.swift:58–65` still updates/inserts canonical Books without checking the new retained permanent authorization deny record. The inbound path first permanently deletes natively, then saves sync tombstone acknowledgement (`ChangeApplier.swift:805`, `SwiftDataSyncMetadataStore.swift:160`). If the latter save fails or the process stops between stores, native denial survives while sync metadata can remain live. A later live payload without a file download passes the metadata-only gate and `commitLiveBook` upserts the old UUID at `ChangeApplier.swift:646`, restoring a library row despite the permanent native closure. Confidence 95%. | Reject a canonical upsert when its retained reading authorization is tombstoned, in the same native DB turn before update/insert. Keep fresh-UUID imports and explicit full-account reset unaffected. Sent to native author; open. |
| 3 | High / Important | `ServiceGraphFactory.swift:542` invokes `retireBookForDeletion`, whose `BookImportLifecycle.swift:216–220` always replaces the exact witness. A remote echo/recovery stamp can therefore invalidate a local operation’s rollback proof. Additionally, compatibility restoration at `BookImportLifecycle.swift:532–556` waits the old source before checking retirement and can reopen Book admission without checking whether a local witness owns it. An inbound CAS/error recovery during an active pre-save local deletion can stall behind that local holder or reopen/consume another operation’s retirement. Confidence 95%; implementation author confirmed both omissions. | Give remote/recovery entry a preserve-or-create retirement seam, leaving ordinary new local operation semantics unchanged. Compatibility restoration must refuse a locally witnessed retirement before any source-drain wait and recheck ownership after suspensions; another operation cannot reopen it. Wire the new remote/recovery seam through the factory. Open pending targeted correction. |

**Round 1 result: Re-review required — 3 High findings.** Root owns subsequent fresh compilation and installation. User performs behavioral verification; no native tests were executed by this reviewer.

### Round 2 — two native corrections

Fresh build-first evidence: `/tmp/rishi-durable-first-final-signed-build.log` reports `BUILD SUCCEEDED`, exit 0. Re-reviewed only the changed native guards from its exact source snapshot `/private/tmp/rishi-durable-first-compile/apps/apple/rishi/rishi/Modules/RishiDB/RishiDB/Stores/SwiftDataBookStore.swift`.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | High / Important | Prior-generation reading authorization blocked deletion | Closed. The exact current account-generation authorization and canonical owner/CAS remain checked; same-owner reading authorization is advanced only while becoming revoked+tombstoned, granting no reading authority. |
| 2 | High / Important | Canonical upsert bypassed permanent native deny | Closed. The serialized upsert reads retained authorization and throws for a tombstoned identity before either insertion or update. A fresh UUID has no old deny record. |
| 3 | High / Important | Remote/recovery could replace/reopen a local witness | Targeted correction underway; pending frozen source and fresh compile before re-review. |

**Round 2 result: Re-review required — 1 High remains open.**

### Round 3 — remote/recovery retirement correction

Fresh build-first evidence: `/tmp/rishi-durable-first-final-signed-build-r2.log` reports `BUILD SUCCEEDED`, exit 0. Root confirms its 688 production input hashes remained unchanged during this build. Re-reviewed only the changed lifecycle, recovery and factory wiring from `/private/tmp/rishi-durable-first-compile`; the already reviewed native guards are unchanged. Those four files also match live source at review time.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 3 | High / Important | Remote/recovery could replace/reopen a local witness | Closed. `retireBookForNonLocalDeletion` preserves an existing local witness under the lifecycle lock; a new non-local drain witness is not inserted into the local rollback map. Factory remote deletion and restart recovery use this distinct seam. Compatibility rollback refuses a local witness before promotion drain, checks again before source drain, and checks/activates source and promotion admission in one final synchronous lifecycle lock. Ordinary local operation witness creation remains unchanged. |

**Implementation result: PASS — 3 rounds, 0 open Critical/High/Medium findings.** The reviewed correction saves logical deletion before reader/source lifetime waits, retains permanent native identity denial, permits fresh-UUID reimport despite deferred old-attempt cleanup, and filters/reconciles durable tombstones across restart. This is source and signed-build evidence, not a claim that the user’s physical-device behavior has been verified. No native tests were executed by this reviewer.

## 2026-10-08 commit isolation review

The user confirmed the installed correction works and requested a commit. The cumulative deletion changes were reconstructed against HEAD in temporary files, preserving unrelated live auth, billing, onboarding, position and factory extraction work. Required import authority, source lifetime and cover prerequisites were included; native permit/acceptance implementations and existing affected test callers were aligned with those interfaces.

Independent review identified missing native authority implementations, source/cover interfaces and obsolete test initializer labels. Each finding was corrected in the temporary reconstruction and re-reviewed. Final finite source/provenance/dependency review: **PASS, 0 open Critical/High findings**. All 59 proposed Swift files parse and the cumulative patch applies cleanly to the HEAD index. No new native build or runtime test result is claimed for this reconstructed commit; the signed delivery build and user confirmation remain the prior verification evidence.
