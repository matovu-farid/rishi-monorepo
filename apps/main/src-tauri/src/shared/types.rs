use serde::{Deserialize, Serialize};

pub enum BookKind {
    Epub = 0,
    Pdf = 1,
    Mobi = 2,
    Djvu = 3,
}

impl BookKind {
    pub fn to_string(self) -> String {
        match self {
            BookKind::Epub => "epub".to_string(),
            BookKind::Pdf => "pdf".to_string(),
            BookKind::Mobi => "mobi".to_string(),
            BookKind::Djvu => "djvu".to_string(),
        }
    }
}
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BookData {
    pub id: String,
    pub(crate) kind: String,
    pub(crate) cover: Vec<u8>,
    pub(crate) title: Option<String>,
    pub(crate) author: Option<String>,
    pub(crate) publisher: Option<String>,
    pub(crate) filepath: String,
    pub(crate) location: String,
    pub(crate) cover_kind: Option<String>,
    version: u32,
}

impl BookData {
    pub fn new(
        id: String,
        kind: String,
        cover: Vec<u8>,
        title: Option<String>,
        author: Option<String>,
        publisher: Option<String>,
        filepath: String,
        current_location: String,
        cover_kind: Option<String>,
    ) -> Self {
        Self {
            id,
            kind,
            cover,
            title,
            author,
            cover_kind,
            publisher,
            filepath,
            location: current_location,
            version: 0,
        }
    }
}
