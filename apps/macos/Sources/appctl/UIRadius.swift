import CoreGraphics

public enum UIRadius {
    public static let compact: CGFloat = 6
    public static let regular: CGFloat = 8
    public static let large: CGFloat = 12

    public static func pill(forHeight height: CGFloat) -> CGFloat { height / 2 }
}
