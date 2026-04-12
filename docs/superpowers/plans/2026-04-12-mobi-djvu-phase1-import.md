# MOBI/DJVU Phase 1: Import Pipeline

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Users can import `.mobi`, `.azw3`, and `.djvu` files into the app, with metadata extracted and books stored in the database — ready for Phase 2 viewers.

**Architecture:** Rust backend extracts metadata for each format via the existing `Extractable` trait. Frontend adds file type detection and import mutations mirroring the existing EPUB/PDF pattern. Books open to a placeholder "viewer coming soon" until Phase 2.

**Tech Stack:** Rust `mobi` crate (MOBI/AZW3), Rust `djvulibre` C FFI (DJVU), TypeScript/React frontend

---

### Task 1: Add `mobi` crate dependency

**Files:**
- Modify: `apps/main/src-tauri/Cargo.toml:25-65` (dependencies section)

- [ ] **Step 1: Add mobi crate to Cargo.toml**

Add to the `[dependencies]` section in `apps/main/src-tauri/Cargo.toml`:

```toml
mobi = "0.8"
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src-tauri/Cargo.toml apps/main/src-tauri/Cargo.lock
git commit -m "chore: add mobi crate dependency"
```

---

### Task 2: Add BookKind variants for Mobi and Djvu

**Files:**
- Modify: `apps/main/src-tauri/src/shared/types.rs:1-56`

- [ ] **Step 1: Add Mobi and Djvu to BookKind enum**

In `apps/main/src-tauri/src/shared/types.rs`, update the `BookKind` enum and its `to_string` impl:

```rust
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
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src-tauri/src/shared/types.rs
git commit -m "feat: add Mobi and Djvu BookKind variants"
```

---

### Task 3: Create MOBI metadata extractor

**Files:**
- Create: `apps/main/src-tauri/src/mobi.rs`
- Modify: `apps/main/src-tauri/src/lib.rs:1-6` (add module declaration)

- [ ] **Step 1: Create mobi.rs with Extractable implementation**

Create `apps/main/src-tauri/src/mobi.rs`:

```rust
use crate::shared::{
    books::Extractable,
    types::{BookData, BookKind},
};
use mobi::Mobi as MobiDoc;
use std::path::{Path, PathBuf};

pub struct Mobi {
    pub path: PathBuf,
}

impl Mobi {
    pub fn new(path: &Path) -> Self {
        Mobi {
            path: path.to_path_buf(),
        }
    }
}

impl Extractable for Mobi {
    fn extract(&self) -> Result<BookData, Box<dyn std::error::Error>> {
        let mobi_path = &self.path;
        let doc = MobiDoc::from_path(mobi_path)?;

        let title = Some(doc.title().to_string()).filter(|s| !s.is_empty());
        let author = doc.author().map(|s| s.to_string()).filter(|s| !s.is_empty());
        let publisher = doc.publisher().map(|s| s.to_string()).filter(|s| !s.is_empty());

        // Extract cover image from MOBI records if available
        let cover = extract_mobi_cover(&doc).unwrap_or_else(|| create_mobi_placeholder_cover());

        let digest = md5::compute(mobi_path.to_string_lossy().to_string());
        let id = format!("{:x}", digest);
        let file_path = mobi_path.to_string_lossy().to_string();
        let kind = BookKind::Mobi.to_string();
        // MOBI location is chapter-based, start at chapter 0
        let current_location = "0".to_string();

        let cover_kind = if cover.len() > 100 {
            None // Real cover extracted
        } else {
            Some("fallback".to_string())
        };

        Ok(BookData::new(
            id,
            kind,
            cover,
            title,
            author,
            publisher,
            file_path,
            current_location,
            cover_kind,
        ))
    }
}

/// Try to extract the cover image from MOBI EXTH records.
fn extract_mobi_cover(doc: &MobiDoc) -> Option<Vec<u8>> {
    // The mobi crate provides raw content; try to find an image record
    // referenced by EXTH CoverOffset header
    let raw_content = doc.image_records();
    raw_content.first().map(|img| img.content.clone())
}

/// Generate a placeholder cover for MOBI files (same pattern as PDF placeholder).
fn create_mobi_placeholder_cover() -> Vec<u8> {
    use image::{ImageFormat, Rgba, RgbaImage};
    use std::io::Cursor;

    let width = 400u32;
    let height = 600u32;
    let mut img = RgbaImage::new(width, height);

    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let gradient_y = (y as f32 / height as f32).min(1.0);
        let noise = ((x + y) % 7) as u8 * 3;
        let edge_darken = if x < 20 || x > width - 20 || y < 20 || y > height - 20 {
            20
        } else {
            0
        };
        // Warm brown tones for MOBI
        *pixel = Rgba([
            (65 + (gradient_y * 30.0) as u8 + noise).saturating_sub(edge_darken),
            (45 + (gradient_y * 25.0) as u8 + noise).saturating_sub(edge_darken),
            (35 + (gradient_y * 20.0) as u8 + noise).saturating_sub(edge_darken),
            255,
        ]);
    }

    let mut buffer = Vec::new();
    let mut cursor = Cursor::new(&mut buffer);
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut cursor, ImageFormat::Png)
        .unwrap_or_default();
    buffer
}
```

- [ ] **Step 2: Register the module in lib.rs**

In `apps/main/src-tauri/src/lib.rs`, add after the `mod pdf;` line:

```rust
mod mobi;
```

- [ ] **Step 3: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles without errors. The `mobi` crate API may differ from what's shown — adjust `author()`, `publisher()`, `image_records()` calls to match the actual crate API. Check `cargo doc --open -p mobi` if needed.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src-tauri/src/mobi.rs apps/main/src-tauri/src/lib.rs
git commit -m "feat: add MOBI metadata extractor with Extractable trait"
```

---

### Task 4: Add get_mobi_data Tauri command

**Files:**
- Modify: `apps/main/src-tauri/src/commands.rs:1-13` (add import) and after line 79 (add command)
- Modify: `apps/main/src-tauri/src/lib.rs:69-98` (register command)

- [ ] **Step 1: Add Mobi import to commands.rs**

In `apps/main/src-tauri/src/commands.rs`, add to the existing imports at the top (around line 9):

```rust
use crate::mobi::Mobi;
```

- [ ] **Step 2: Add get_mobi_data command**

Add after the `get_book_data` function (after line 79) in `commands.rs`:

```rust
#[tauri::command]
pub fn get_mobi_data(app: tauri::AppHandle, path: &Path) -> Result<BookData, String> {
    let data = Mobi::new(path);
    store_book_data(app, &data).map_err(|e| e.to_string())?;
    data.extract().map_err(|e| e.to_string())
}
```

- [ ] **Step 3: Register in invoke_handler**

In `apps/main/src-tauri/src/lib.rs`, add `commands::get_mobi_data,` to the `invoke_handler` list, after `commands::get_pdf_data,` (around line 73):

```rust
commands::get_mobi_data,
```

- [ ] **Step 4: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles without errors.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src-tauri/src/commands.rs apps/main/src-tauri/src/lib.rs
git commit -m "feat: add get_mobi_data Tauri command"
```

---

### Task 5: Create DJVU metadata extractor (stub with placeholder)

**Files:**
- Create: `apps/main/src-tauri/src/djvu.rs`
- Modify: `apps/main/src-tauri/src/lib.rs` (add module declaration)

Note: Full djvulibre FFI integration requires the C library and cmake. For Phase 1, we create a stub extractor that reads basic file info and generates a placeholder cover. The full page-rendering FFI is added in Phase 2. This keeps Phase 1 shippable without the C build dependency.

- [ ] **Step 1: Create djvu.rs with stub Extractable implementation**

Create `apps/main/src-tauri/src/djvu.rs`:

```rust
use crate::shared::{
    books::Extractable,
    types::{BookData, BookKind},
};
use std::fs;
use std::path::{Path, PathBuf};

pub struct Djvu {
    pub path: PathBuf,
}

impl Djvu {
    pub fn new(path: &Path) -> Self {
        Djvu {
            path: path.to_path_buf(),
        }
    }
}

impl Extractable for Djvu {
    fn extract(&self) -> Result<BookData, Box<dyn std::error::Error>> {
        let djvu_path = &self.path;

        if !djvu_path.exists() {
            return Err(format!("File not found: {}", djvu_path.display()).into());
        }

        // Validate DJVU magic bytes: "AT&TFORM"
        let header = fs::read(djvu_path)?;
        if header.len() < 8 || &header[0..4] != b"AT&T" {
            return Err("Not a valid DJVU file".into());
        }

        // DJVU metadata is sparse — derive title from filename
        let title = djvu_path
            .file_stem()
            .and_then(|s| s.to_str())
            .map(|s| s.to_string());

        let cover = create_djvu_placeholder_cover();

        let digest = md5::compute(djvu_path.to_string_lossy().to_string());
        let id = format!("{:x}", digest);
        let file_path = djvu_path.to_string_lossy().to_string();
        let kind = BookKind::Djvu.to_string();
        // DJVU location is page-based, start at page 1
        let current_location = "1".to_string();

        Ok(BookData::new(
            id,
            kind,
            cover,
            title,
            None,     // author — not available without djvulibre
            None,     // publisher — not available without djvulibre
            file_path,
            current_location,
            Some("fallback".to_string()),
        ))
    }
}

/// Generate a placeholder cover for DJVU files.
fn create_djvu_placeholder_cover() -> Vec<u8> {
    use image::{ImageFormat, Rgba, RgbaImage};
    use std::io::Cursor;

    let width = 400u32;
    let height = 600u32;
    let mut img = RgbaImage::new(width, height);

    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let gradient_y = (y as f32 / height as f32).min(1.0);
        let noise = ((x + y) % 7) as u8 * 3;
        let edge_darken = if x < 20 || x > width - 20 || y < 20 || y > height - 20 {
            20
        } else {
            0
        };
        // Cool grey-blue tones for DJVU (scanned doc feel)
        *pixel = Rgba([
            (50 + (gradient_y * 25.0) as u8 + noise).saturating_sub(edge_darken),
            (55 + (gradient_y * 30.0) as u8 + noise).saturating_sub(edge_darken),
            (70 + (gradient_y * 35.0) as u8 + noise).saturating_sub(edge_darken),
            255,
        ]);
    }

    let mut buffer = Vec::new();
    let mut cursor = Cursor::new(&mut buffer);
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut cursor, ImageFormat::Png)
        .unwrap_or_default();
    buffer
}
```

- [ ] **Step 2: Register the module in lib.rs**

In `apps/main/src-tauri/src/lib.rs`, add after the `mod mobi;` line:

```rust
mod djvu;
```

- [ ] **Step 3: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles without errors.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src-tauri/src/djvu.rs apps/main/src-tauri/src/lib.rs
git commit -m "feat: add DJVU metadata extractor with placeholder cover"
```

---

### Task 6: Add get_djvu_data Tauri command

**Files:**
- Modify: `apps/main/src-tauri/src/commands.rs` (add import and command)
- Modify: `apps/main/src-tauri/src/lib.rs` (register command)

- [ ] **Step 1: Add Djvu import to commands.rs**

In `apps/main/src-tauri/src/commands.rs`, add to the imports at the top:

```rust
use crate::djvu::Djvu;
```

- [ ] **Step 2: Add get_djvu_data command**

Add after the `get_mobi_data` function in `commands.rs`:

```rust
#[tauri::command]
pub fn get_djvu_data(app: tauri::AppHandle, path: &Path) -> Result<BookData, String> {
    let data = Djvu::new(path);
    store_book_data(app, &data).map_err(|e| e.to_string())?;
    data.extract().map_err(|e| e.to_string())
}
```

- [ ] **Step 3: Register in invoke_handler**

In `apps/main/src-tauri/src/lib.rs`, add `commands::get_djvu_data,` to the `invoke_handler` list, after `commands::get_mobi_data,`:

```rust
commands::get_djvu_data,
```

- [ ] **Step 4: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles without errors.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src-tauri/src/commands.rs apps/main/src-tauri/src/lib.rs
git commit -m "feat: add get_djvu_data Tauri command"
```

---

### Task 7: Add TypeScript command bindings for new formats

**Files:**
- Modify: `apps/main/src/generated/types.ts` (add param types)
- Modify: `apps/main/src/generated/commands.ts` (add command functions)

Note: These files say "do not edit manually" but since they're generated from Rust types, we add our bindings to match the new commands. If the project has a codegen step (`cargo tauri-typegen generate`), run that instead and skip the manual edits.

- [ ] **Step 1: Add param types to types.ts**

Add at the end of `apps/main/src/generated/types.ts` (before the closing):

```typescript
export interface GetMobiDataParams {
  path: Path;
  [key: string]: unknown;
}

export interface GetDjvuDataParams {
  path: Path;
  [key: string]: unknown;
}
```

- [ ] **Step 2: Add command functions to commands.ts**

Add at the end of `apps/main/src/generated/commands.ts` (before the closing):

```typescript
export async function getMobiData(params: types.GetMobiDataParams): Promise<types.BookData> {
  return invoke('get_mobi_data', params);
}

export async function getDjvuData(params: types.GetDjvuDataParams): Promise<types.BookData> {
  return invoke('get_djvu_data', params);
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/generated/types.ts apps/main/src/generated/commands.ts
git commit -m "feat: add TypeScript bindings for MOBI and DJVU commands"
```

---

### Task 8: Update file picker to accept new formats

**Files:**
- Modify: `apps/main/src/modules/chooseFiles.ts:1-11`

- [ ] **Step 1: Add MOBI and DJVU filters**

Replace the contents of `apps/main/src/modules/chooseFiles.ts`:

```typescript
import { open } from "@tauri-apps/plugin-dialog";

export async function chooseFiles() {
  const filePaths = await open({
    multiple: true,
    directory: false,
    filters: [
      { name: "EPUB Books", extensions: ["epub"] },
      { name: "PDF Files", extensions: ["pdf"] },
      { name: "MOBI Books", extensions: ["mobi", "azw3"] },
      { name: "DJVU Documents", extensions: ["djvu"] },
    ],
  });

  return filePaths || []; // Returns real absolute paths
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/modules/chooseFiles.ts
git commit -m "feat: add MOBI/AZW3/DJVU to file picker filters"
```

---

### Task 9: Add MOBI and DJVU import mutations to FileComponent

**Files:**
- Modify: `apps/main/src/components/FileComponent.tsx`

- [ ] **Step 1: Add getMobiData and getDjvuData imports**

In `apps/main/src/components/FileComponent.tsx`, update the import from `@/generated` (line 9-16) to include the new commands:

```typescript
import {
  Book,
  deleteBook,
  getBookData,
  getBooks,
  getMobiData,
  getDjvuData,
  getPdfData,
  saveBook,
} from "@/generated";
```

- [ ] **Step 2: Add storeMobiMutation**

Add after the `storePdfMutation` block (after line 277) in `FileComponent.tsx`:

```typescript
  const storeMobiMutation = useMutation({
    mutationKey: ["getMobiData"],
    mutationFn: async ({ filePath }: { filePath: string }) => {
      const mobiPath = await copyBookToAppData(filePath);
      const bookData = await getMobiData({ path: mobiPath });
      const book = await saveBook({
        book: {
          coverKind: bookData.coverKind || "",
          title: bookData.title || "",
          author: bookData.author || "",
          publisher: bookData.publisher || "",
          filepath: mobiPath,
          location: "0",
          version: 0,
          kind: bookData.kind,
          cover: bookData.cover,
        },
      });

      try {
        const fileHash = await hashBookFile(mobiPath);
        const { r2Key } = await uploadBookFile(mobiPath, fileHash, 'mobi');
        await db.updateTable('books')
          .set({
            file_hash: fileHash,
            file_r2_key: r2Key,
            is_dirty: 1,
          })
          .where('id', '=', book.id)
          .execute();
      } catch (err) {
        console.warn('[file-sync] Failed to hash/upload mobi file, will retry on next sync:', err);
      }

      return book;
    },
    onError(error) {
      console.error("Error storing MOBI:", error);
      toast.error("Can't upload book");
    },
    onSuccess(bookData) {
      void queryClient.invalidateQueries({ queryKey: ["books"] });
      setNewBookId(null);
      setTimeout(() => {
        setNewBookId(bookData.id.toString());
      }, 0);
    },
  });

  const storeDjvuMutation = useMutation({
    mutationKey: ["getDjvuData"],
    mutationFn: async ({ filePath }: { filePath: string }) => {
      const djvuPath = await copyBookToAppData(filePath);
      const bookData = await getDjvuData({ path: djvuPath });
      const book = await saveBook({
        book: {
          coverKind: bookData.coverKind || "",
          title: bookData.title || "",
          author: bookData.author || "",
          publisher: bookData.publisher || "",
          filepath: djvuPath,
          location: "1",
          version: 0,
          kind: bookData.kind,
          cover: bookData.cover,
        },
      });

      try {
        const fileHash = await hashBookFile(djvuPath);
        const { r2Key } = await uploadBookFile(djvuPath, fileHash, 'djvu');
        await db.updateTable('books')
          .set({
            file_hash: fileHash,
            file_r2_key: r2Key,
            is_dirty: 1,
          })
          .where('id', '=', book.id)
          .execute();
      } catch (err) {
        console.warn('[file-sync] Failed to hash/upload djvu file, will retry on next sync:', err);
      }

      return book;
    },
    onError(error) {
      console.error("Error storing DJVU:", error);
      toast.error("Can't upload book");
    },
    onSuccess(bookData) {
      void queryClient.invalidateQueries({ queryKey: ["books"] });
      setNewBookId(null);
      setTimeout(() => {
        setNewBookId(bookData.id.toString());
      }, 0);
    },
  });
```

- [ ] **Step 3: Update processFilePaths to handle new extensions**

Replace the `processFilePaths` function (around line 280-290):

```typescript
  const processFilePaths = (filePaths: string[]) => {
    if (filePaths.length > 0) {
      filePaths.forEach((filePath) => {
        if (filePath.endsWith(".epub")) {
          storeBookDataMutation.mutate({ filePath });
        } else if (filePath.endsWith(".pdf")) {
          storePdfMutation.mutate({ filePath });
        } else if (filePath.endsWith(".mobi") || filePath.endsWith(".azw3")) {
          storeMobiMutation.mutate({ filePath });
        } else if (filePath.endsWith(".djvu")) {
          storeDjvuMutation.mutate({ filePath });
        }
      });
    }
  };
```

- [ ] **Step 4: Update allowed drag-drop extensions**

Update the `allowedExtensions` array in the `useTauriDragDrop` call (around line 305):

```typescript
    allowedExtensions: [".epub", ".pdf", ".mobi", ".azw3", ".djvu"],
```

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/FileComponent.tsx
git commit -m "feat: add MOBI and DJVU import mutations and drag-drop support"
```

---

### Task 10: Add placeholder viewer routes for new formats

**Files:**
- Modify: `apps/main/src/routes/books.$id.lazy.tsx`

- [ ] **Step 1: Add placeholder rendering for mobi and djvu kinds**

In `apps/main/src/routes/books.$id.lazy.tsx`, update the return JSX (lines 79-91) to handle the new book kinds:

```typescript
  return (
    <motion.div layout className="">
      {book?.kind === "pdf" && (
        <PdfView
          filepath={convertFileSrc(book.filepath)}
          key={book.id.toString()}
          book={book}
        />
      )}
      {book?.kind === "epub" && <EpubView key={book.id} book={book} />}
      {book?.kind === "mobi" && (
        <div className="w-full h-screen flex items-center justify-center">
          <div className="text-center">
            <h2 className="text-xl font-semibold mb-2">{book.title}</h2>
            <p className="text-muted-foreground">MOBI viewer coming in Phase 2</p>
          </div>
        </div>
      )}
      {book?.kind === "djvu" && (
        <div className="w-full h-screen flex items-center justify-center">
          <div className="text-center">
            <h2 className="text-xl font-semibold mb-2">{book.title}</h2>
            <p className="text-muted-foreground">DJVU viewer coming in Phase 2</p>
          </div>
        </div>
      )}
    </motion.div>
  );
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/routes/books.$id.lazy.tsx
git commit -m "feat: add placeholder routes for MOBI and DJVU book kinds"
```

---

### Task 11: End-to-end smoke test

**Files:** None (manual testing)

- [ ] **Step 1: Build the app**

Run:
```bash
cd apps/main && npm run tauri dev
```
Expected: App launches without errors.

- [ ] **Step 2: Test MOBI import**

1. Click "Add Book" and select a `.mobi` file
2. Verify the book appears in the library grid with a cover image (real or placeholder)
3. Click the book — verify the placeholder "MOBI viewer coming in Phase 2" message shows
4. Repeat with a `.azw3` file

- [ ] **Step 3: Test DJVU import**

1. Click "Add Book" and select a `.djvu` file
2. Verify the book appears in the library grid with the placeholder cover
3. Click the book — verify the placeholder "DJVU viewer coming in Phase 2" message shows

- [ ] **Step 4: Test drag-and-drop**

1. Drag a `.mobi` file onto the app window — verify it imports
2. Drag a `.djvu` file onto the app window — verify it imports

- [ ] **Step 5: Verify existing formats still work**

1. Import an EPUB — verify it opens in the EPUB reader
2. Import a PDF — verify it opens in the PDF viewer

- [ ] **Step 6: Commit any fixes**

If any issues were found and fixed during testing, commit them:
```bash
git add -A
git commit -m "fix: address issues found during MOBI/DJVU import smoke test"
```
