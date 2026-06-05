/** @type {import('jest').Config} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  // `__mocks__` is in roots so Jest auto-loads the node-module stubs that
  // live there (#60 added one for `react-native-reanimated` — see
  // `__mocks__/react-native-reanimated.js` for the rationale).
  roots: ['<rootDir>/__tests__', '<rootDir>/__mocks__'],
  setupFiles: ['<rootDir>/jest.setup.ts'],
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/$1',
    '^@rishi/shared/(.*)$': '<rootDir>/../../packages/shared/src/$1',
    '^@rishi/shared$': '<rootDir>/../../packages/shared/src',
    '^rishi-pdf-extractor$': '<rootDir>/__mocks__/rishi-pdf-extractor.ts',
  },
  transform: {
    // `tsconfig.jest.json` sets `jsx: 'react'` so JSX in source files
    // is lowered into `React.createElement` calls for the test VM.
    // The main `tsconfig.json` still uses `jsx: 'react-native'` for
    // Metro / app code.
    '^.+\\.tsx?$': [
      'ts-jest',
      {
        tsconfig: '<rootDir>/tsconfig.jest.json',
        diagnostics: false,
      },
    ],
  },
}
