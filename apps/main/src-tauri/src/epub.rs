use crate::shared::{
    books::Extractable,
    types::{BookData, BookKind},
};
use epub::doc::EpubDoc;

use std::path::{Path, PathBuf};

pub struct Epub {
    pub path: PathBuf,
}
impl Epub {
    pub fn new(path: &Path) -> Self {
        Epub {
            path: path.to_path_buf(),
        }
    }
}
impl Extractable for Epub {
    fn extract(&self) -> Result<BookData, Box<dyn std::error::Error>> {
        let epub_path = &self.path;
        let mut doc = EpubDoc::new(epub_path).map_err(|e| e.to_string())?;
        let cover_data = doc.get_cover().ok_or("No cover found")?;
        let cover = cover_data.0;
        let title = doc.get_title();

        let author = doc.mdata("creator").map(|data| data.value.clone());
        let publisher = doc.mdata("publisher").map(|data| data.value.clone());
        // create a unique id by hashing the path
        let digest = md5::compute(epub_path.to_string_lossy().to_string());
        let id = format!("{:x}", digest);
        let file_path = epub_path.to_string_lossy().to_string();
        let kind = BookKind::Epub.to_string();
        let current_location = "".to_string();

        Ok(BookData::new(
            id,
            kind,
            cover,
            title,
            author,
            publisher,
            file_path,
            current_location,
            None,
        ))
    }
}
