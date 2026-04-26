use rishi_dioxus::formats::{extract_paragraphs_from_html, BookFormat};

#[test]
fn test_extract_paragraphs_from_html() {
    let html = r#"
        <html><body>
            <h1>Chapter Title</h1>
            <p>First paragraph with <em>emphasis</em>.</p>
            <p>Second paragraph.</p>
            <p>   </p>
            <p>Third paragraph after empty.</p>
        </body></html>
    "#;

    let paragraphs = extract_paragraphs_from_html(html);

    assert_eq!(paragraphs.len(), 3, "empty paragraphs should be filtered");
    assert_eq!(paragraphs[0].text, "First paragraph with emphasis.");
    assert_eq!(paragraphs[0].index, 0);
    assert_eq!(paragraphs[1].text, "Second paragraph.");
    assert_eq!(paragraphs[2].text, "Third paragraph after empty.");
}

#[test]
fn test_book_format_detection() {
    assert_eq!(
        BookFormat::from_path("/books/novel.epub"),
        Some(BookFormat::Epub)
    );
    assert_eq!(
        BookFormat::from_path("/books/paper.pdf"),
        Some(BookFormat::Pdf)
    );
    assert_eq!(
        BookFormat::from_path("/books/old.mobi"),
        Some(BookFormat::Mobi)
    );
    assert_eq!(
        BookFormat::from_path("/books/old.azw3"),
        Some(BookFormat::Mobi)
    );
    assert_eq!(
        BookFormat::from_path("/books/scan.djvu"),
        Some(BookFormat::Djvu)
    );
    assert_eq!(
        BookFormat::from_path("/books/scan.djv"),
        Some(BookFormat::Djvu)
    );
    assert_eq!(BookFormat::from_path("/books/notes.txt"), None);
    // Case insensitive
    assert_eq!(
        BookFormat::from_path("/books/NOVEL.EPUB"),
        Some(BookFormat::Epub)
    );
}

#[test]
fn test_book_format_as_str() {
    assert_eq!(BookFormat::Epub.as_str(), "epub");
    assert_eq!(BookFormat::Pdf.as_str(), "pdf");
    assert_eq!(BookFormat::Mobi.as_str(), "mobi");
    assert_eq!(BookFormat::Djvu.as_str(), "djvu");
}
