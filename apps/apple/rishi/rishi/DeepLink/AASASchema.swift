

import Foundation

struct AASA: Codable, Equatable, Sendable {

    let applinks: AppLinks
    let webcredentials: WebCredentials?

    struct AppLinks: Codable, Equatable, Sendable {
        let details: [Detail]

        struct Detail: Codable, Equatable, Sendable {
            let appIDs: [String]
            let components: [Component]

    
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
