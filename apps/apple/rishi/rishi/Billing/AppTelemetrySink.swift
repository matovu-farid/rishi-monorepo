import Foundation



struct AppTelemetrySink: TelemetrySink {

    func setEnabled(_ enabled: Bool) async {
        RishiLogging.setSentryEnabled(enabled)
    }
}
