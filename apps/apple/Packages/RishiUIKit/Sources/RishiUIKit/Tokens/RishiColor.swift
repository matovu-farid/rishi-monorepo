import SwiftUI

/// Semantic color tokens. Light + dark are baked into `Resources/Colors.xcassets`;
/// the sepia palette ships as a Swift dictionary (`RishiColor.sepia`) for the
/// Reader phase to apply via custom view modifier.
public enum RishiColor {

    private static var bundle: Bundle { .module }

    public static var background:      Color { Color("background",      bundle: bundle) }
    public static var surface:         Color { Color("surface",         bundle: bundle) }
    public static var surfaceElevated: Color { Color("surfaceElevated", bundle: bundle) }
    public static var divider:         Color { Color("divider",         bundle: bundle) }
    public static var textPrimary:     Color { Color("textPrimary",     bundle: bundle) }
    public static var textSecondary:   Color { Color("textSecondary",   bundle: bundle) }
    public static var textMuted:       Color { Color("textMuted",       bundle: bundle) }
    public static var accent:          Color { Color("accent",          bundle: bundle) }
    public static var accentMuted:     Color { Color("accentMuted",     bundle: bundle) }
    public static var warning:         Color { Color("warning",         bundle: bundle) }
    public static var danger:          Color { Color("danger",          bundle: bundle) }
    public static var success:         Color { Color("success",         bundle: bundle) }

    /// Sepia palette — applied by the Reader phase via custom theme switching.
    /// Light + dark variants live in the asset catalog; sepia is data-only so
    /// callers can construct `Color(red:green:blue:)` at theme-switch time.
    public enum sepia {
        public static var background:      Color { Color(red: 0xF4/255, green: 0xEC/255, blue: 0xD8/255) }
        public static var surface:         Color { Color(red: 0xEC/255, green: 0xE2/255, blue: 0xC7/255) }
        public static var surfaceElevated: Color { Color(red: 0xF4/255, green: 0xEC/255, blue: 0xD8/255) }
        public static var divider:         Color { Color(red: 0xD8/255, green: 0xCD/255, blue: 0xB0/255) }
        public static var textPrimary:     Color { Color(red: 0x3C/255, green: 0x2F/255, blue: 0x1E/255) }
        public static var textSecondary:   Color { Color(red: 0x6B/255, green: 0x5A/255, blue: 0x3F/255) }
        public static var textMuted:       Color { Color(red: 0x9B/255, green: 0x8B/255, blue: 0x69/255) }
        public static var accent:          Color { Color(red: 0x7A/255, green: 0x5C/255, blue: 0x2E/255) }
        public static var accentMuted:     Color { Color(red: 0xC2/255, green: 0xA6/255, blue: 0x78/255) }
        public static var warning:         Color { Color(red: 0xB4/255, green: 0x53/255, blue: 0x09/255) }
        public static var danger:          Color { Color(red: 0xB9/255, green: 0x1C/255, blue: 0x1C/255) }
        public static var success:         Color { Color(red: 0x4D/255, green: 0x7C/255, blue: 0x0F/255) }
    }
}
