











import Foundation
import RishiSettings
import RishiLogging







struct AppTelemetrySink: TelemetrySink {

    func setEnabled(_ enabled: Bool) async {
        RishiLogging.setSentryEnabled(enabled)
    }
}
