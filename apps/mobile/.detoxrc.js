/**
 * Detox configuration for rishi-mobile.
 *
 * Scope: iOS Simulator only for now. Android is intentionally TODO.
 *
 * E2E test-mode flag:
 *   The app reads `process.env.EXPO_PUBLIC_E2E_TEST === 'true'` (see
 *   `app/_layout.tsx`) to skip real auth and use seeded data. Expo
 *   inlines `EXPO_PUBLIC_*` env vars at BUILD time, not runtime, so
 *   `launchArgs` cannot flip the flag for a release-style RN bundle.
 *   Therefore we set the var via the `build` script env below — the
 *   Metro bundler invoked by `expo run:ios` picks it up. We *also*
 *   pass it via `launchArgs` (as `EXPO_PUBLIC_E2E_TEST`) for
 *   completeness; tests can read it from `process.env` if needed
 *   during dev-mode runs.
 *
 * TODO(android): add an `android.emu.debug` configuration mirroring
 * this once Android parity work picks up.
 */
/** @type {Detox.DetoxConfig} */
module.exports = {
  testRunner: {
    args: {
      $0: 'jest',
      config: 'e2e/jest.config.js',
    },
    jest: {
      setupTimeout: 240000,
    },
  },
  apps: {
    'ios.debug': {
      type: 'ios.app',
      // We build to a project-local derived-data dir so the binary path
      // is stable (the default `~/Library/Developer/Xcode/DerivedData`
      // path has a per-workspace hash suffix that's awkward to encode).
      binaryPath:
        'ios/build/Build/Products/Release-iphonesimulator/rishimobile.app',
      bundleId: 'com.rishi.mobile',
      // Build Release so the JS bundle is baked into the .app and the
      // expo-dev-client launcher screen is skipped. We use `xcodebuild`
      // directly (rather than `expo run:ios`) because:
      //   1. We need to control `-derivedDataPath` for a predictable
      //      binaryPath.
      //   2. `expo run:ios --no-bundler` still launches the dev-launcher
      //      in Debug mode, which blocks Detox at the URL-input screen.
      // The `EXPO_PUBLIC_E2E_TEST=true` env var is inlined into the
      // bundle by Metro during the `Bundle React Native code and images`
      // build phase — this is the ONLY way to set it for a release
      // bundle (Expo evaluates EXPO_PUBLIC_* vars at bundle time, not
      // runtime).
      build:
        'SENTRY_DISABLE_AUTO_UPLOAD=true SENTRY_ALLOW_FAILURE=true EXPO_PUBLIC_E2E_TEST=true xcodebuild -workspace ios/rishimobile.xcworkspace -scheme rishimobile -configuration Release -sdk iphonesimulator -derivedDataPath ios/build -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO',
    },
  },
  devices: {
    simulator: {
      type: 'ios.simulator',
      device: {
        type: 'iPhone 17',
        os: 'iOS 26.2',
      },
    },
  },
  configurations: {
    'ios.sim.debug': {
      device: 'simulator',
      app: 'ios.debug',
      // launchArgs are forwarded to the app's process at launch time.
      // The `detox*` keys configure Detox itself (sync, etc.). Any
      // additional keys are appended to argv and exposed via
      // ProcessInfo.processInfo.environment + RCTConvert in RN.
      launchArgs: {
        detoxEnableSynchronization: 0,
        EXPO_PUBLIC_E2E_TEST: 'true',
      },
    },
  },
};
