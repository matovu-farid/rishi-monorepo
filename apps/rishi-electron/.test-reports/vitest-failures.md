# Vitest Failures (baseline)

Total: 0 failed, 1835 passed, 0 skipped (217 test files)

## Failing tests

- None. All 1835 tests pass.

## Collection failures

- None.

## Notes

- Previous 35 `better-sqlite3` native-binding failures (queries.test.ts, sync-validation.test.ts, libraryWrite.test.ts) are fully resolved after manual `pnpm rebuild better-sqlite3 hnswlib-node`.
- Vitest was invoked directly via `pnpm exec vitest run` to skip the `pretest` rebuild hook (prebuild-install had SIGKILL'd previously).
- Non-failing stderr noise: a couple of `ECONNREFUSED ::1:3000 / 127.0.0.1:3000` AggregateErrors and one happy-dom `DOMException NotSupportedError` for `kindle:flow:0001?mime=text/css` (stylesheet fetch). Neither causes a test failure.
- Run duration ~19s.
