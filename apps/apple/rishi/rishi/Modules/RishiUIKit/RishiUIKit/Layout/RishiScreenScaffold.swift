import SwiftUI

public enum RishiScreenLayout: Equatable {
    case fullBleed
    case centeredColumn(maxWidth: CGFloat)

    public static func resolve(isMacCatalyst: Bool) -> RishiScreenLayout {
        isMacCatalyst ? .centeredColumn(maxWidth: 440) : .fullBleed
    }

    public static var current: RishiScreenLayout {
        #if targetEnvironment(macCatalyst)
            return resolve(isMacCatalyst: true)
        #else
            return resolve(isMacCatalyst: false)
        #endif
    }
}

public enum RishiScreenActionPlacement {

    case pinnedToBottom

    case belowContent
}

public struct RishiScreenScaffold<Hero: View, Actions: View>: View {
    private let layout: RishiScreenLayout
    private let actionPlacement: RishiScreenActionPlacement
    @ViewBuilder private let hero: () -> Hero
    @ViewBuilder private let actions: () -> Actions

    public init(
        layout: RishiScreenLayout = .current,
        actionPlacement: RishiScreenActionPlacement,
        @ViewBuilder hero: @escaping () -> Hero,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.layout = layout
        self.actionPlacement = actionPlacement
        self.hero = hero
        self.actions = actions
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
    }

    @ViewBuilder private var content: some View {
        switch layout {
        case .centeredColumn(let maxWidth):
            VStack(spacing: RishiSpacing.xl) {
                hero()
                actions()
            }
            .frame(maxWidth: maxWidth)
            .padding(RishiSpacing.l)
        case .fullBleed:
            fullBleed
        }
    }

    @ViewBuilder private var fullBleed: some View {
        switch actionPlacement {
        case .pinnedToBottom:
            VStack(spacing: RishiSpacing.l) {
                Spacer(minLength: 0)
                hero()
                Spacer(minLength: 0)
                actions()
            }
        case .belowContent:
            VStack(spacing: RishiSpacing.l) {
                hero()
                actions()
            }
            .padding(RishiSpacing.l)
        }
    }
}
