#if DEBUG
import Foundation

/// DEBUG-only switch surfacing whether the app should attach
/// `X-Dev-Bypass: 1` to outbound worker requests.
///
/// The ENTIRE type is wrapped in `#if DEBUG` so release builds CANNOT reference
/// it — this is enforced by the compile boundary, not a runtime check. Plan
/// 03-06 reads ``isEnabled`` once at app composition time and passes the bool
/// to ``WorkerClient``'s `devBypassEnabled` initializer parameter.
///
/// Sources (in priority order):
///   1. Environment variable `RISHI_DEV_BYPASS=1` (Xcode scheme arg or shell)
///   2. `Info.plist` key `RishiDevBypass` (Bool) — set by debug-only build configs
///
/// Read fresh on every access so test harnesses can flip the env var mid-run
/// without rebuilding.
public enum DevBypassConfig {
    public static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["RISHI_DEV_BYPASS"] == "1" {
            return true
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "RishiDevBypass") as? Bool, value {
            return true
        }
        return false
    }
}
#endif
