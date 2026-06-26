
import Foundation


struct PaywallFeature: Identifiable, Equatable {
    let name: String
    var id: String { name }
}
