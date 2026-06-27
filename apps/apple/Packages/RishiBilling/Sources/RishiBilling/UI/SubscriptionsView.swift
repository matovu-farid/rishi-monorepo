import SwiftUI
import StoreKit


// TODO: Change this before prod
#if DEBUG
let groupID = "rishi-pro-group"
#endif
public class GroupId {
    //var value:String = "22149819"
    public var value:String = groupID
    private init(_ value: String? = groupID) {
        if let value {self.value = value}
    }
    @MainActor public static  let shared:GroupId = .init()
    
}

public struct SubscriptionsView: View {
    var color: UIColor
    public init(color:UIColor) {
        self.color = color
    }

    private var groupId: GroupId = GroupId.shared
   public var body: some View {
        ZStack{
            Color(color)
                .opacity(0.1)
                .ignoresSafeArea()
            SubscriptionStoreView(groupID: groupId.value){
          
                VStack{
                    
                    Image("rishi")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(.rect(cornerRadius: 20))
                    Text("Rishi Reader")
                        .fontWeight(.semibold)
                        .font(.largeTitle)
                    VStack(spacing: 10){
                        Text("Bring every book to life")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text("Listen to books with natural voices, ask questions as you read, and pick up where you left off on any device")
                    }.padding(10)
                        .multilineTextAlignment(.center)
                    
                }
           
            
        }
            .subscriptionStoreButtonLabel(.multiline)
            .subscriptionStorePickerItemBackground(.thinMaterial)
            .subscriptionStorePolicyDestination(url: URL(string: "https://rishi.fidexa.org/privacy")!, for: .privacyPolicy)
            .subscriptionStorePolicyDestination(url: URL(string: "https://rishi.fidexa.org/terms")!, for: .termsOfService)
           
            

            .tint(Color(color))
            
        }
    }
}




