import SwiftUI

public struct BuildThisPleaseTheme: Sendable {
    public let accent: Color
    public let voteHighlight: Color

    public init(accent: Color = .blue, voteHighlight: Color? = nil) {
        self.accent = accent
        self.voteHighlight = voteHighlight ?? accent
    }
}

extension EnvironmentValues {
    @Entry var buildThisPleaseTheme = BuildThisPleaseTheme()
}

extension View {
    public func buildThisPleaseTheme(_ theme: BuildThisPleaseTheme) -> some View {
        environment(\.buildThisPleaseTheme, theme).tint(theme.accent)
    }
}
