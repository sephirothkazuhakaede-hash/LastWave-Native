import SwiftUI

/// Measure the side controls independently and reserve the larger side on both
/// sides of the title. Its anchor is the full container's mathematical center.
struct CenteredPlayerHeader: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let left = subviews[0].sizeThatFits(.unspecified)
        let right = subviews[2].sizeThatFits(.unspecified)
        let width = proposal.width ?? (left.width + right.width + subviews[1].sizeThatFits(.unspecified).width + spacing * 2)
        let center = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, width - 2 * (max(left.width, right.width) + spacing)), height: nil))
        return CGSize(width: width, height: max(left.height, max(right.height, center.height)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let left = subviews[0].sizeThatFits(.unspecified)
        let right = subviews[2].sizeThatFits(.unspecified)
        let available = max(0, bounds.width - 2 * (max(left.width, right.width) + spacing))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(left))
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(width: available, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(right))
    }
}
