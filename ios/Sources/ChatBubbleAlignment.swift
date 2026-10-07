import SwiftUI

private enum ChatBubbleCenterAlignment: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
        dimensions[VerticalAlignment.center]
    }
}

extension VerticalAlignment {
    /// Align avatars with the bubble itself, excluding names and timestamps.
    static let chatBubbleCenter = VerticalAlignment(ChatBubbleCenterAlignment.self)
}
