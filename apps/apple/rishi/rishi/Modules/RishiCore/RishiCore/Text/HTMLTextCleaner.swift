//
//  HTMLTextCleaner.swift
//  RishiCore
//
//  Extracted from ParagraphChunker (plan 34-12 SRP split). One job: turn HTML /
//  XHTML markup into spoken-text paragraph blocks. Drops non-spoken element
//  bodies (`<head>`/`<style>`/`<script>`), normalises block-element edges into
//  blank-line boundaries, splits on `<p>` boundaries, and strips inline tags +
//  decodes entities. ParagraphChunker.chunk(_:) drives this when markup is
//  present; behavior is byte-for-byte identical to the prior inline code.
//
//  The blank-line splitter lives in ParagraphChunker (it is also the markup-free
//  chunking path), so callers inject it via `blankLineSplit` to keep this type
//  self-contained without duplicating the scanner.
//

import Foundation

/// HTML/XHTML → spoken-text cleanup helpers used by `ParagraphChunker`.
public nonisolated enum HTMLTextCleaner {

    /// Produce the cleaned, block-boundary-normalised markup that the chunker
    /// splits into paragraphs. Mirrors the prior
    /// `insertBlockBoundaries(removeNonSpokenElements(text))` composition.
    nonisolated static func prepare(_ text: String) -> String {
        insertBlockBoundaries(removeNonSpokenElements(text))
    }

    /// Split `<p ...>...</p>` boundaries. Tolerates attributes on the open tag,
    /// case-insensitive. Anything outside `<p>` regions is treated as one more
    /// blank-line-separated block (so mixed `<p>` + raw blank-line input both
    /// work). `blankLineSplit` is the caller's blank-line scanner.
    nonisolated static func splitByPTags(
        _ text: String,
        blankLineSplit: (String) -> [String]
    ) -> [String] {
        let pattern = "<p[^>]*>([\\s\\S]*?)</p>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return blankLineSplit(text)
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)

        var paragraphs: [String] = []
        var cursor = 0
        for match in matches {
            let outside = NSRange(location: cursor, length: match.range.location - cursor)
            if outside.length > 0 {
                let chunk = nsText.substring(with: outside)
                paragraphs.append(contentsOf: splitOutsideRegion(chunk, blankLineSplit: blankLineSplit))
            }
            let inside = nsText.substring(with: match.range(at: 1))
            paragraphs.append(stripTags(inside))
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            let tail = nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor))
            paragraphs.append(contentsOf: splitOutsideRegion(tail, blankLineSplit: blankLineSplit))
        }
        return paragraphs
    }

    /// Handle a region that sits OUTSIDE any `<p>...</p>` (document scaffold,
    /// headings, list items, raw blank-line blocks). Inline / block tags here
    /// (`<h1>`, `<body>`, `<div>`, doctype, closing tags) MUST be stripped so
    /// markup is never spoken — the prior implementation forwarded these
    /// straight to `splitByBlankLines`, which leaked the raw XHTML scaffold
    /// into the TTS chunks (reader-tts-xml-and-loading symptom 1). We strip
    /// tags first, THEN split the resulting plain text on blank lines.
    nonisolated static func splitOutsideRegion(
        _ region: String,
        blankLineSplit: (String) -> [String]
    ) -> [String] {
        // Split on blank-line boundaries FIRST (so raw blank-line-separated
        // paragraphs survive as distinct chunks), THEN strip tags per block.
        // `stripTags` collapses internal whitespace, so doing it before the
        // blank-line split would merge separate paragraphs into one chunk.
        return blankLineSplit(region)
            .map { stripTags($0) }
            .filter { !$0.isEmpty }
    }

    /// Block-level HTML elements whose edges should start a new chunk even
    /// when no blank line separates them. EPUB/XHTML expresses paragraph
    /// structure with tags (headings, list items, divs) rather than blank
    /// lines, so the `<p>`-only + blank-line splitters lump a heading, an
    /// intro paragraph and a `<ul>` list into one chunk. Normalising these
    /// boundaries into blank lines up front lets the existing splitters break
    /// on them. Runs of inserted newlines collapse in `scanByBlankLines`, so
    /// emitting `\n\n` on both sides of every boundary tag is safe.
    nonisolated static func insertBlockBoundaries(_ html: String) -> String {
        let blockTags = "p|div|li|ul|ol|h[1-6]|blockquote|section|article|aside"
            + "|header|footer|figure|figcaption|table|thead|tbody|tr|pre|hr"
        let pattern = "</?(?:\(blockTags))\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "\n\n$0\n\n")
    }

    /// Remove element bodies that are never spoken: `<head>...</head>`,
    /// `<style>...</style>`, `<script>...</script>`. Without this the CSS /
    /// JS / `<title>` / `<meta>` text inside those elements survives tag
    /// stripping (it is character data, not markup) and gets read aloud.
    nonisolated static func removeNonSpokenElements(_ html: String) -> String {
        var result = html
        for tag in ["head", "style", "script"] {
            let pattern = "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
            }
        }
        return result
    }

    /// Inside-`<p>` content may still contain inline tags (`<em>`, `<a>`, `<br>`).
    /// Strip them to bare text for TTS, then decode the common HTML entities.
    nonisolated static func stripTags(_ html: String) -> String {
        let pattern = "<[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        let stripped = regex.stringByReplacingMatches(in: html, range: range, withTemplate: " ")
        let collapsed = stripped.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
