import Foundation

public enum ShareInboxButtonVisibility {
    public static func shouldShow(shareServiceAvailable: Bool) -> Bool {
        shareServiceAvailable
    }
}
