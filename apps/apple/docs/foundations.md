[Back to overview](./README.md)

# Foundations

Foundations are the horizontal Swift packages that user-facing features depend on. They contain no UI screens; they own shared types, persistence, networking, design tokens, logging, and test fakes. Knowing which foundation owns which concern is the fastest way around the codebase: if you need a `Book` type, RishiCore; if you need to read or write the local database, RishiDB; if you need to call the worker, RishiAPI.

## RishiCore

`apps/apple/Packages/RishiCore/` is the bedrock. It defines the domain models (`Book`, `User`, `Position`, `Highlight`, `Conversation`, `Message`, `Session`), strong-typed identifiers (`BookID`, `UserID`), the unified `RishiError` envelope, and the service protocols every feature codes against: `AuthService`, `BookStore`, `PositionStore`, `HighlightStore`, `ConversationStore`, `MessageStore`, `ChatService`, and the marker `WorkerAPI`. RishiCore imports only `Foundation` — no database driver, no networking, no Apple SDKs. Every other package imports it. The non-obvious rule: the protocols in `Protocols/` are the seams the whole codebase relies on. Adding a method here cascades a compile failure through every implementation (real and fake), so treat the protocol surface as a public API and edit it deliberately.

## RishiDB

`apps/apple/Packages/RishiDB/` owns the on-device database. It wraps GRDB (the Swift SQLite library) and exposes one factory, `RishiDB.makeDatabaseQueue(at:)`, plus a set of `GRDB*Store` classes that conform to the RishiCore store protocols. Migrations, the schema, and the column-name source of truth (`Tables.*`) all live inside the package — typos become compile errors instead of runtime SQL failures. Features never import GRDB directly; they import RishiDB and use the store protocols. The non-obvious rule: `PRAGMA foreign_keys = ON` is installed per connection, so foreign-key violations are real errors at runtime. If a test inserts an orphan row to exercise a code path, it must use a queue that disables foreign keys explicitly.

## RishiAPI

`apps/apple/Packages/RishiAPI/` is the worker client. It owns `WorkerClient` (a Swift actor wrapping URLSession), the `WorkerEndpoint` protocol every endpoint conforms to, the `TokenProvider` protocol that lets the auth package plug bearer-token reads in, and one `*Endpoint` type per worker route (`SignInSocialEndpoint`, `SpeechStreamEndpoint`, `VerifyReceiptEndpoint`, `GetSessionEndpoint`, conversation and message sync endpoints, and so on). Zero third-party networking dependencies — pure URLSession. The non-obvious rule: dates on the wire use the seconds-since-2001 reference (Apple's `Date.timeIntervalSinceReferenceDate`), not ISO 8601 or Unix epoch. The convention is locked in `JSONDecoder.deferredToDate`; the worker matches it. If a new endpoint stops decoding dates, check the wire format before changing the decoder.

## RishiUIKit

`apps/apple/Packages/RishiUIKit/` is the design system, not a UIKit wrapper. It contains the typed tokens (`RishiColor`, `RishiTypography`, `RishiSpacing`, `RishiRadius`, `RishiMotion`), accessibility modifiers, preview helpers, and the bundled image and font resources. Every feature view imports it for colour, spacing, font, and corner radius — there are no inline hex codes or `.font(.system(size:))` literals anywhere in the app's UI. The non-obvious rule: Sepia is shipped as Swift colour data on `RishiColor.sepia.*`, not as an Asset Catalog appearance variant. Apple's appearance system has light and dark but no built-in sepia luminosity key, and the reader needs to swap themes at runtime regardless. Anywhere the design system needs a non-system colour mode, follow the same pattern — a static set of `RishiColor` values, not an asset variant.

## RishiLogging

`apps/apple/Packages/RishiLogging/` is the logging facade. It exposes `Log.event(_:level:data:)` and `Log.error(_:error:)` plus a small set of `os.Logger` categories (`auth`, `persistence`, and so on). Internally it bridges to Sentry through a private `SentryBridge` — but every feature imports only RishiLogging, never Sentry directly. There is an init-once gate: `RishiLogging.start(dsn:)` flips the bridge to live mode, and calling `Log.event` before `start` is a no-op rather than a crash, so tests run safely. The non-obvious rule: Sentry is fenced behind RishiLogging on purpose. Swapping the vendor SDK is a one-file change inside `SentryBridge.swift` — do not let `import Sentry` leak into any feature package.

## RishiTesting

`apps/apple/Packages/RishiTesting/` is the test-support package. It owns the in-memory fakes for every RishiCore store (`InMemoryBookStore`, `InMemoryPositionStore`, and the rest), service fakes (`FakeAuthService`, `FakeChatService`, `MockWorkerClient`), book and message fixtures, and the conformance helpers (`assertBookStoreConformance`, and so on) that GRDB stores and in-memory stores both run against. The rule that catches people: RishiTesting has zero dependency on XCTest. The conformance helpers `throw RishiTestingError` rather than calling `XCTAssert`, because they are reused from Swift Testing targets (`@Test`, `#expect`). All tests in this project use Swift Testing — no XCTest. If you find yourself wanting to add `import XCTest`, stop and use `#expect` instead.
