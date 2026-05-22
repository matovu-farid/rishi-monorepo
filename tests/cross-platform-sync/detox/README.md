# Detox half of the cross-platform sync test

The actual Detox spec lives at:

    apps/mobile/e2e/cross-platform-sync.test.ts

It is colocated there (not here) because Detox's jest config in
`apps/mobile/e2e/jest.config.js` hard-codes its `testMatch` to
`<rootDir>/e2e/**/*.test.ts`. Moving the spec out of that tree would require a
parallel Detox jest config and a separate `apps` block in `.detoxrc.js` — not
worth the duplication.

The orchestrator (`../src/run.ts`) invokes Detox from the mobile app cwd:

    cd apps/mobile
    EXPO_PUBLIC_E2E_TEST=true \
      EXPO_PUBLIC_WORKER_URL=<test worker> \
      pnpm e2e:build

    TEST_TOKEN=<bearer> \
      TEST_USER_ID=<id> \
      FIXTURE_TITLE=<...> \
      pnpm exec detox test --configuration ios.sim.debug \
        e2e/cross-platform-sync.test.ts
