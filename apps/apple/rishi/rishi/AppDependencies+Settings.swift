import Foundation
import RishiSettings
import RishiOnboarding



extension AppDependencies {
    var telemetryStore: any TelemetryStore { services!.telemetryStore }
    var footerDetectionStore: any FooterDetectionStore { services!.footerDetectionStore }
    var onboardingState: any OnboardingState { services!.onboardingState }
    var onboardingCoordinator: OnboardingCoordinator { services!.onboardingCoordinator }
    var readerDefaults: AppReaderDefaults { services!.readerDefaults }
}
