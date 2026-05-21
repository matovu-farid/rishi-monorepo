/** @type {import('jest').Config} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/__tests__'],
  setupFiles: ['<rootDir>/jest.setup.ts'],
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/$1',
    '^@rishi/shared/(.*)$': '<rootDir>/../../packages/shared/src/$1',
    '^@rishi/shared$': '<rootDir>/../../packages/shared/src',
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
