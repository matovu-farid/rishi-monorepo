import StoreKit
import SwiftUI
import RishiAPI

// TODO: Change this before prod

public struct SubscriptionsView: View {
    var color: UIColor
    public init(color: UIColor, groupId:GroupId) {
        self.color = color
        self.groupId = groupId
    }
    

    private var groupId: GroupId
    public var body: some View {
        ZStack {
            Color(color)
                .opacity(0.1)
                .ignoresSafeArea()
            SubscriptionStoreView(groupID: groupId.value) {

                VStack {

                    Image("rishi")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(.rect(cornerRadius: 20))
                    Text("Rishi Reader")
                        .fontWeight(.semibold)
                        .font(.largeTitle)
                    VStack(spacing: 10) {
                        Text("Bring every book to life")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text(
                            "Listen to books with natural voices, ask questions as you read, and pick up where you left off on any device"
                        )
                    }.padding(10)
                        .multilineTextAlignment(.center)

                }

            }
            .subscriptionStoreButtonLabel(.multiline)
            .subscriptionStorePickerItemBackground(.thinMaterial)
            .subscriptionStorePolicyDestination(
                url: URL(string: "https://rishi.fidexa.org/privacy")!,
                for: .privacyPolicy
            )
            .subscriptionStorePolicyDestination(
                url: URL(string: "https://rishi.fidexa.org/terms")!,
                for: .termsOfService
            )

            .tint(Color(color))

        }
    }
}
