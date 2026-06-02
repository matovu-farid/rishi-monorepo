import { defineConfig } from 'eslint/config'
import tseslint from '@electron-toolkit/eslint-config-ts'
import eslintConfigPrettier from '@electron-toolkit/eslint-config-prettier'
import eslintPluginReact from 'eslint-plugin-react'
import eslintPluginReactHooks from 'eslint-plugin-react-hooks'
import eslintPluginReactRefresh from 'eslint-plugin-react-refresh'
import pluginQuery from '@tanstack/eslint-plugin-query'
import pluginRouter from '@tanstack/eslint-plugin-router'

export default defineConfig(
  {
    ignores: [
      '**/node_modules',
      '**/dist',
      '**/out',
      '**/build',
      '**/*.gen.ts',
      'src/renderer/src/routeTree.gen.ts'
    ]
  },

  // Enable type-aware linting for source TS/TSX. The `projectService` opt-in
  // wires ESLint to the TypeScript program so rules like
  // `no-floating-promises` (unhandled async work — a huge IPC footgun in
  // this app) can actually run.
  {
    files: ['src/**/*.{ts,tsx}'],
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname
      }
    }
  },

  tseslint.configs.recommended,
  eslintPluginReact.configs.flat.recommended,
  eslintPluginReact.configs.flat['jsx-runtime'],
  ...pluginQuery.configs['flat/recommended'],
  ...pluginRouter.configs['flat/recommended'],
  {
    settings: {
      react: {
        version: 'detect'
      }
    }
  },
  {
    files: ['**/*.{ts,tsx}'],
    plugins: {
      'react-hooks': eslintPluginReactHooks,
      'react-refresh': eslintPluginReactRefresh
    },
    rules: {
      ...eslintPluginReactHooks.configs.recommended.rules,
      ...eslintPluginReactRefresh.configs.vite.rules,
      // React Compiler family — backlog cleared, enforce as errors so new
      // violations block CI instead of decaying back into warnings.
      'react-refresh/only-export-components': 'error',
      'react-hooks/refs': 'error',
      'react-hooks/set-state-in-effect': 'error',
      'react-hooks/immutability': 'error',
      'react-hooks/purity': 'error'
    }
  },
  {
    files: ['**/*.{ts,tsx,js,cjs,mjs}'],
    rules: {
      // `explicit-function-return-type` produces 300+ warnings of pure noise
      // and never catches bugs — TS inference + `noImplicitReturns` already
      // cover real cases. Disabling lets the high-signal rules below stand
      // out.
      '@typescript-eslint/explicit-function-return-type': 'off',

      // Backlog cleared — these are now enforced as errors. Add new
      // violations only with explicit justification (eslint-disable-next-line
      // with a `--` rationale).
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_', caughtErrorsIgnorePattern: '^_' }
      ],
      '@typescript-eslint/no-unused-expressions': 'error',
      '@typescript-eslint/no-require-imports': 'error',
      '@typescript-eslint/no-unsafe-function-type': 'error',
      '@typescript-eslint/no-empty-function': 'error',
      'no-empty': 'error',
      'prefer-const': 'error',
      'react/no-unescaped-entities': 'error',

      // Real-bug catchers — non-type-aware, so safe in all files.
      eqeqeq: ['error', 'always', { null: 'ignore' }],
      'no-throw-literal': 'error',
      'no-var': 'error',
      'no-fallthrough': 'error',
      'no-self-compare': 'error',
      'no-unreachable-loop': 'error',
      'no-constant-binary-expression': 'error',
      // `no-promise-executor-return` flags the canonical
      // `new Promise((r) => setTimeout(r, ms))` sleep idiom (the arrow
      // returns the timer handle). Real bugs from reading the executor
      // return value are rare, so keep as a warning rather than blocking
      // CI on the sleep pattern.
      'no-promise-executor-return': 'warn',
      // High false-positive rate on async closures captured by Refs/state
      // setters. Keep visible as a warning.
      'require-atomic-updates': 'warn',
      'no-return-assign': 'error',
      'no-implicit-coercion': ['error', { boolean: false }],

      // Tier 1 — non-type-aware footgun catchers.
      // `arr.map(x => { doThing(x) })` returns undefined[] — easy to miss.
      'array-callback-return': ['error', { checkForEach: false }],
      // `"hello ${name}"` (regular string with `${}` typo) — silent bug in
      // dynamic strings (IPC channel names, query keys, cache keys).
      'no-template-curly-in-string': 'error',

      // Tier 1 — React-specific footguns.
      // `{count && <Foo/>}` renders the literal "0" when `count === 0`.
      // Forces `count > 0 && <Foo/>` or `Boolean(count) && <Foo/>`.
      'react/jsx-no-leaked-render': ['error', { validStrategies: ['ternary', 'coerce'] }],
      // Components defined inside other components are recreated every render
      // — destroys child state and causes visible re-mounts.
      'react/no-unstable-nested-components': ['error', { allowAsProps: true }],

      // Tier 2 — useful with low noise.
      // `arr[i]` keys cause stale state across reorders. Warn-only because
      // many static lists legitimately use index keys.
      'react/no-array-index-key': 'warn',
      // Serial awaits in loops are usually intentional in IPC flows but
      // worth surfacing so the choice is deliberate.
      'no-await-in-loop': 'warn'
    }
  },

  // Type-aware footgun rules — only run where `projectService` is enabled.
  // Errors here should stay at zero; each is a real bug class.
  {
    files: ['src/**/*.{ts,tsx}'],
    ignores: ['src/**/*.test.{ts,tsx}', 'src/**/__tests__/**/*.{ts,tsx}'],
    rules: {
      // Single biggest IPC footgun: an unhandled invoke() rejection bubbles
      // up to the renderer or main process loop and crashes the window.
      '@typescript-eslint/no-floating-promises': 'error',
      // Async functions silently used in places that expect sync — e.g.
      // passing `async () => {…}` to `addEventListener` swallows rejections.
      '@typescript-eslint/no-misused-promises': [
        'error',
        // React/DOM event handlers may legitimately be async, so allow the
        // attribute form. Logical-or returns and conditionals stay checked.
        { checksVoidReturn: { attributes: false } }
      ],
      // `await` on a non-Promise is dead code (we hit one such warning in
      // books.ts after the IPC refactor — this rule catches them at lint
      // time instead of leaving silent style warnings).
      '@typescript-eslint/await-thenable': 'error',
      '@typescript-eslint/no-unnecessary-type-assertion': 'error',
      // Catches `${obj}` producing "[object Object]" — every occurrence is
      // a real bug.
      '@typescript-eslint/no-base-to-string': 'error',
      '@typescript-eslint/restrict-template-expressions': [
        'error',
        { allowNumber: true, allowBoolean: true, allowNullish: true, allowRegExp: true }
      ],
      '@typescript-eslint/restrict-plus-operands': 'error',
      '@typescript-eslint/no-for-in-array': 'error',
      '@typescript-eslint/prefer-promise-reject-errors': 'error',
      '@typescript-eslint/require-await': 'error',
      '@typescript-eslint/no-redundant-type-constituents': 'error',

      // Tier 1 — type-aware footgun catchers.
      // Catches "X is always truthy/falsy" — dead branches, unreachable code,
      // conditions that fire on stale post-refactor assumptions.
      '@typescript-eslint/no-unnecessary-condition': [
        'error',
        { allowConstantLoopConditions: true }
      ],
      // Forces every case in a discriminated-union switch. When a new book
      // format is added, every switch fails the build until updated.
      '@typescript-eslint/switch-exhaustiveness-check': [
        'error',
        { considerDefaultExhaustiveForUnions: true }
      ],
      // `value || default` masks `0`, `''`, `false`. Forces `??`.
      '@typescript-eslint/prefer-nullish-coalescing': 'error',
      // `.catch((err) => ...)` types `err` as `any` — forces `unknown` so
      // narrowing is required before use.
      '@typescript-eslint/use-unknown-in-catch-callback-variable': 'error',

      // Tier 2 — useful with low noise.
      // The `!` post-fix silently bypasses null checks. Warn-only because
      // some legitimate uses exist after assertions.
      '@typescript-eslint/no-non-null-assertion': 'warn',
      // `a && a.b && a.b.c` → `a?.b?.c`. Autofixable.
      '@typescript-eslint/prefer-optional-chain': 'error',
      // Splits type-only imports out — helps Vite tree-shake and prevents
      // accidental side-effect imports.
      '@typescript-eslint/consistent-type-imports': [
        'error',
        { prefer: 'type-imports', fixStyle: 'separate-type-imports' }
      ],
      '@typescript-eslint/no-import-type-side-effects': 'error',
      // Catches `onClick={() => doVoidThing()}` patterns where the void
      // return is genuinely confusing (vs intentional event-handler usage).
      '@typescript-eslint/no-confusing-void-expression': [
        'error',
        { ignoreArrowShorthand: true, ignoreVoidOperator: true }
      ]
    }
  },

  // CommonJS helper scripts (`scripts/*.cjs`) are loaded by Node directly via
  // `node scripts/foo.cjs` from package.json — `require()` is the native
  // module syntax for `.cjs`, not an opt-in. Relax the ESM-only require rule
  // for that surface rather than wrapping every line in inline disables.
  {
    files: ['**/*.cjs'],
    rules: {
      '@typescript-eslint/no-require-imports': 'off'
    }
  },

  // Tests legitimately float promises (vitest `expect(...).resolves...`
  // patterns), use `any` for partial mocks, and may shadow types. Relax
  // there rather than peppering files with eslint-disable comments.
  {
    files: ['**/*.test.{ts,tsx}', '**/__tests__/**/*.{ts,tsx}', 'e2e/**/*.{ts,tsx}'],
    rules: {
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/no-floating-promises': 'off',
      '@typescript-eslint/no-misused-promises': 'off',
      '@typescript-eslint/no-unnecessary-type-assertion': 'off',
      '@typescript-eslint/no-base-to-string': 'off',
      '@typescript-eslint/restrict-template-expressions': 'off',
      '@typescript-eslint/require-await': 'off',
      '@typescript-eslint/no-unnecessary-condition': 'off',
      '@typescript-eslint/no-non-null-assertion': 'off',
      '@typescript-eslint/no-confusing-void-expression': 'off',
      '@typescript-eslint/use-unknown-in-catch-callback-variable': 'off'
    }
  },

  eslintConfigPrettier
)
