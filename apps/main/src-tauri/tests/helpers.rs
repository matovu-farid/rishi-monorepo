// Test helpers for a Vitest-like Rust testing experience
// Import this module in your test files to get all the nice testing utilities

// Use expectest for expect!() assertions (Jest/Vitest style)
pub use expectest::prelude::*;

// Use pretty_assertions for beautiful colored diffs (qualified to avoid conflict with std)
pub use pretty_assertions::{assert_eq as pretty_assert_eq, assert_ne as pretty_assert_ne};

// Use expect_test for snapshot testing (qualified to avoid conflict)
pub use expect_test::expect as expect_snapshot;
