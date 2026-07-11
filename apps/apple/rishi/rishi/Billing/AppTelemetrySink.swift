import Foundation
import RishiLogging
import RishiSettings

struct AppTelemetrySink: TelemetrySink {

    func setEnabled(_ enabled: Bool) async {
        RishiLogging.setSentryEnabled(enabled)
    }
}
