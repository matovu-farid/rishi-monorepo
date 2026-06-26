






import SwiftUI
import StoreKit


@Observable
class GroupId {
    //var value:String = "22149819"
    var value:String = "AB6C54E6"
    
}

struct SubscriptionsView: View {

    @Environment(GroupId.self) private var groupId
    var body: some View {
        ZStack{
            Color("rishiBrown")
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
           
            

            .tint(Color("rishiBrown"))
            
        }
    }
}




