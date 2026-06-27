//import SwiftUI
//import RishiCore
//import RishiAuth
//import RishiBilling
//
//struct PaywallGateView: View {
//    let services: BootstrappedServices
//
//    @Environment(\.signOut) private var signOut
//
//    @Environment(\.rishiAuthService) private var auth
//    @State private var viewModel: PaywallViewModel?
//
//    var body: some View {
//        Group {
//            if let viewModel {
//                SubscriptionsView()
//                
//            } else {
//                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
//            }
//        }
//        .task {
//            if viewModel == nil {
//                viewModel = PaywallViewModel.make(services: services)
//            }
//        }
//    }
//}
