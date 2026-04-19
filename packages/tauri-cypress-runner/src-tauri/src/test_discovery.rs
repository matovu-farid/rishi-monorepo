use crate::types::TestFile;
use std::path::Path;
use walkdir::WalkDir;

pub fn discover_tests(spec_pattern: &str, base_dir: &str) -> Result<Vec<TestFile>, String> {
    let base = Path::new(base_dir);
    let (dir_prefix, extensions) = parse_pattern(spec_pattern);
    let search_dir = base.join(&dir_prefix);

    if !search_dir.exists() {
        return Ok(vec![]);
    }

    let mut files = Vec::new();

    for entry in WalkDir::new(&search_dir).into_iter().filter_map(|e| e.ok()) {
        if !entry.file_type().is_file() {
            continue;
        }

        let path = entry.path();
        let file_name = path.file_name().unwrap_or_default().to_string_lossy();

        if !extensions.iter().any(|ext| file_name.ends_with(ext)) {
            continue;
        }

        let relative = path
            .strip_prefix(base)
            .map_err(|e| e.to_string())?
            .to_string_lossy()
            .to_string();
        let name = path
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        let metadata = entry.metadata().map_err(|e| e.to_string())?;
        let last_modified = metadata
            .modified()
            .map(|t| {
                t.duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs()
            })
            .unwrap_or(0);

        files.push(TestFile {
            path: relative,
            name,
            last_modified,
        });
    }

    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

fn parse_pattern(pattern: &str) -> (String, Vec<String>) {
    let parts: Vec<&str> = pattern.splitn(2, "/**/").collect();
    let dir_prefix = if parts.len() == 2 {
        parts[0].to_string()
    } else {
        ".".to_string()
    };
    let file_glob = if parts.len() == 2 { parts[1] } else { parts[0] };

    let extensions = if let Some(start) = file_glob.find('{') {
        let end = file_glob.find('}').unwrap_or(file_glob.len());
        let prefix = &file_glob[..start];
        let variants = &file_glob[start + 1..end];
        variants
            .split(',')
            .map(|v| format!("{}{}", prefix, v.trim()))
            .collect()
    } else {
        vec![file_glob[1..].to_string()]
    };

    (dir_prefix, extensions)
}
