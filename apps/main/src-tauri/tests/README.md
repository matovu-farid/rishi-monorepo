# 🏆 Modern Rust Testing Setup

This project uses a modern Rust testing stack that provides a Vitest-like experience.

## Setup

### 1. Install Global Tools

```bash
# Install cargo-nextest (beautiful test runner)
cargo install cargo-nextest

# Install cargo-watch (watch mode)
cargo install cargo-watch
```

### 2. Dependencies

All testing dependencies are already added to `Cargo.toml`:
- `expectest` - `expect(...).to(...)` assertions
- `pretty_assertions` - colorful diffs
- `expect-test` - snapshot-style expectations
- `speculate` - optional Mocha/Jest-style `describe/it`

## Usage

### Import Helpers

In your test files, import the helpers:

```rust
mod helpers;
use helpers::*;
```

### Running Tests

**Normal run (recommended):**
```bash
cargo nextest run
```

**Watch mode (auto-rerun on changes):**
```bash
cargo watch -q -c -x "nextest run"
```

**Update snapshots:**
```bash
UPDATE_EXPECT=1 cargo nextest run
```

### Example Tests

See `example_test.rs` for examples of:
- `expect!(value).to(be_equal_to(expected))` - Jest-style assertions
- `expect!(condition).to(be_equal_to(true))` - Boolean checks
- `pretty_assert_eq!` - Beautiful colored diffs (use instead of std `assert_eq!`)
- Snapshot tests with `expect_snapshot!` - Inline snapshot testing

## Features

| Feature                          | Provided By       |
| -------------------------------- | ----------------- |
| Pretty terminal UI               | cargo-nextest     |
| Watch mode                       | cargo-watch       |
| expect() syntax                  | expectest         |
| Colored diffs                    | pretty_assertions |
| Snapshots                        | expect-test       |
| Mocha-style describes (optional) | speculate         |

