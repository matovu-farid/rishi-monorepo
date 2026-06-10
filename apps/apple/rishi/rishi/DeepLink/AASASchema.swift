//
//  AASASchema.swift
//  rishi
//
//  Phase 12 Plan 12-03 — Codable mirror of the worker-hosted
//  apple-app-site-association JSON contract (WORKER-TICKETS Ticket 2).
//
//  Used to unit-validate the contract on the iOS side so the schema can
//  drift-detect from `rishi.fidexa.org/.well-known/apple-app-site-association`
//  the moment either end changes shape.
//
//  Apple's on-device AASA validator does NOT follow redirects and expects
//  Content-Type: application/json. Those transport-level checks belong on
//  the worker integration test (out of scope here) — this struct is pure
//  shape.
//

import Foundation

struct AASA: Codable, Equatable, Sendable {

    let applinks: AppLinks
    let webcredentials: WebCredentials?

    struct AppLinks: Codable, Equatable, Sendable {
        let details: [Detail]

        struct Detail: Codable, Equatable, Sendable {
            let appIDs: [String]
            let components: [Component]

            /// One element in the `components` array. Apple uses `"/"` as
            /// the path key, so we map it onto a Swift-safe `path` while
            /// preserving the optional `comment` field worker uses for
            /// readability.
            struct Component: Codable, Equatable, Sendable {
                let path: String
                let comment: String?

                enum CodingKeys: String, CodingKey {
                    case path    = "/"
                    case comment
                }
            }
        }
    }

    struct WebCredentials: Codable, Equatable, Sendable {
        let apps: [String]
    }
}
