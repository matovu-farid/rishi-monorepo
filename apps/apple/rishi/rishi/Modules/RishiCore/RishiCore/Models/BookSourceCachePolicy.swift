import Foundation

/// Describes how a reader may reuse source-derived caches for one immutable
/// readable source. Transient originals never inherit a BookID from their
/// directory name; only a verified managed source may address the book cache.
public enum BookSourceCachePolicy: Sendable, Equatable {
    case transient
    case managed(bookID: BookID, version: ManagedFileVersion)
}
