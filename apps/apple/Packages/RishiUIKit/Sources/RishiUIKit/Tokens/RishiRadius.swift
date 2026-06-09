import CoreGraphics

/// Corner-radius scale.
public enum RishiRadius {
    public static let small:  CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large:  CGFloat = 16
    /// Use with `RoundedRectangle(cornerRadius: RishiRadius.pill)` for pill shapes.
    public static let pill:   CGFloat = .infinity
}
