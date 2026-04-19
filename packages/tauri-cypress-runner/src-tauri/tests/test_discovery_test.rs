use tauri_cypress_runner::test_discovery::discover_tests;
use std::fs;

#[test]
fn test_discovers_cy_ts_files() {
    let dir = tempfile::tempdir().unwrap();
    let cypress_dir = dir.path().join("cypress").join("e2e");
    fs::create_dir_all(&cypress_dir).unwrap();
    fs::write(cypress_dir.join("auth.cy.ts"), "// test").unwrap();
    fs::write(cypress_dir.join("books.cy.ts"), "// test").unwrap();
    fs::write(cypress_dir.join("helper.ts"), "// not a test").unwrap();

    let files = discover_tests("cypress/**/*.cy.ts", dir.path().to_str().unwrap()).unwrap();
    assert_eq!(files.len(), 2);
    let names: Vec<&str> = files.iter().map(|f| f.name.as_str()).collect();
    assert!(names.contains(&"auth.cy"));
    assert!(names.contains(&"books.cy"));
}

#[test]
fn test_discovers_cy_js_files() {
    let dir = tempfile::tempdir().unwrap();
    let cypress_dir = dir.path().join("cypress").join("e2e");
    fs::create_dir_all(&cypress_dir).unwrap();
    fs::write(cypress_dir.join("login.cy.js"), "// test").unwrap();

    let files = discover_tests("cypress/**/*.cy.js", dir.path().to_str().unwrap()).unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].name, "login.cy");
}

#[test]
fn test_returns_empty_for_no_matches() {
    let dir = tempfile::tempdir().unwrap();
    let files = discover_tests("cypress/**/*.cy.ts", dir.path().to_str().unwrap()).unwrap();
    assert!(files.is_empty());
}

#[test]
fn test_returns_relative_paths() {
    let dir = tempfile::tempdir().unwrap();
    let cypress_dir = dir.path().join("cypress").join("e2e");
    fs::create_dir_all(&cypress_dir).unwrap();
    fs::write(cypress_dir.join("test.cy.ts"), "// test").unwrap();

    let files = discover_tests("cypress/**/*.cy.ts", dir.path().to_str().unwrap()).unwrap();
    assert!(files[0].path.starts_with("cypress"));
    assert!(!files[0].path.starts_with("/"));
}
