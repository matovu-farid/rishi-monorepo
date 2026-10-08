import Foundation

struct PaywallFeature: Identifiable, Equatable {
    let request: PaywallRequest
    var name: String { request.name }
    var id: String { name }
}
