import SwiftUI

/// Typography scale. Every token uses `.system(_ style:design:)` so Dynamic Type
/// adjusts text size automatically. Use `RishiTypography.body` etc. as drop-in
/// values for `.font(...)`.
public enum RishiTypography {
    public static var titleXL:        Font { .system(.largeTitle, design: .default).weight(.bold)     }
    public static var titleL:         Font { .system(.title,      design: .default).weight(.semibold) }
    public static var titleM:         Font { .system(.title2,     design: .default).weight(.semibold) }
    public static var body:           Font { .system(.body,       design: .default)                  }
    public static var bodyEmphasized: Font { .system(.body,       design: .default).weight(.semibold) }
    public static var caption:        Font { .system(.caption,    design: .default)                  }
    public static var code:           Font { .system(.body,       design: .monospaced)               }
}
