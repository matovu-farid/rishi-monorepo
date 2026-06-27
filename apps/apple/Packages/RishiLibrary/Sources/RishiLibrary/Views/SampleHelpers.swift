//
//  SampleHelpers.swift
//  RishiLibrary
//
//  Created by Farid Matovu on 27/06/2026.
//

import Foundation


public  func makeRoot() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("Sample-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

public  func makeDefaults() -> UserDefaults {
    let suite = "rishi.sample.tests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

import RishiCore

public actor InMemoryBookStore: BookStore {
    private var storage: [BookID: Book] = [:]
    
    public init(initial: [Book] = []) {
        for b in initial { storage[b.id] = b }
    }
    
    public func books(for userId: UserID) async throws -> [Book] {
        storage.values
            .filter { $0.userId == userId }
            .sorted { $0.addedAt < $1.addedAt }
    }
    
    public func book(_ id: BookID) async throws -> Book? {
        storage[id]
    }
    
    public func upsert(_ book: Book) async throws {
        storage[book.id] = book
    }
    
    public func delete(_ id: BookID) async throws {
        storage.removeValue(forKey: id)
    }
    
    /// Test affordance: snapshot the current storage map.
    public func snapshot() -> [Book] {
        Array(storage.values)
    }
}

public  func makeBook()async ->Book? {
    let root = makeRoot()
    let store = InMemoryBookStore()
    let storage = BookFileStorage(rootURL: root, bookStore: store,
                                  coverExtractors: ["epub": EpubCoverExtractor()])
    let defaults = makeDefaults()
    let installer = SampleBookInstaller(storage: storage, defaults: defaults)
    
    let userId = UUID()
    let book = await installer.installIfNeeded(ownerId: userId)
    return book
}

