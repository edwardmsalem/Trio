import CoreGraphics

/// Fixed zone heights for the non-scrolling Home dashboard; the chart takes the remainder.
enum HomeLayout {
    /// header slot: pump panel / glucose bobble / loop status; includes room
    /// for the sensor arc/tag overhanging the bobble
    static let headerHeight: CGFloat = 172
    /// meal panel slot (IOB / COB / delivery rate)
    static let mealSlotHeight: CGFloat = 44
    /// shared slot for adjustment panel and bolus progress (was 8% of screen height)
    static let bottomPanelHeight: CGFloat = 60
    /// stats banner slot below the adjustment panel (multi-use panel later)
    static let statsBannerHeight: CGFloat = 60
    /// clear air above, between, and below the bottom-zone panels
    static let bottomZonePadding: CGFloat = 10
    static var bottomZoneHeight: CGFloat { bottomPanelHeight + statsBannerHeight + 3 * bottomZonePadding }
    /// pull distance that triggers the forced loop
    static let refreshTriggerDistance: CGFloat = 70
    /// indicator row height while the loop runs
    static let refreshIndicatorHeight: CGFloat = 40
    /// last-resort chart floor; must stay below the tightest natural allocation
    /// (SE under the iOS 26 tab bar + accessory leaves ~140) or the bottom zone overflows
    static let chartMinHeight: CGFloat = 130
}

import SwiftUI

/// Two even columns for a wide screen, such as the open inner screen of iPhone Duo.
///
/// When the device is partly folded like a book, the fold becomes an active division region. The
/// columns then end at either side of the fold, so no card or button sits in the crease. With no
/// active fold the columns split the width 50/50 around a normal gutter. Only reached on regular
/// width, so normal iPhones never use it.
struct FoldAwareColumns<Leading: View, Trailing: View>: View {
    var gutter: CGFloat = 16
    var edgePadding: CGFloat = 16
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    /// Bumped on every hinge change so the layout re-reads the fold even if the size is unchanged.
    @State private var hingeChanges = 0

    var body: some View {
        GeometryReader { geo in
            // reading the hinge counter here re-runs the layout when the fold changes
            let fold = Self.verticalFold(in: geo, hingeChanges: hingeChanges)
            let columns = Self.columns(width: geo.size.width, fold: fold, edge: edgePadding, gutter: gutter)
            HStack(spacing: 0) {
                leading.frame(width: columns.leading)
                Color.clear.frame(width: columns.gap)
                trailing.frame(width: columns.trailing)
            }
            .padding(.leading, edgePadding)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .modifier(HingeChangeCounter(count: $hingeChanges))
    }

    /// The active fold, when it runs top to bottom through this view.
    private static func verticalFold(in geo: GeometryProxy, hingeChanges _: Int) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        return geo.reservedRegions(kind: .division)
            .map(\.frame)
            .first { $0.height > $0.width && $0.minX > 0 && $0.maxX < geo.size.width }
    }

    static func columns(
        width: CGFloat,
        fold: CGRect?,
        edge: CGFloat,
        gutter: CGFloat
    ) -> (leading: CGFloat, gap: CGFloat, trailing: CGFloat) {
        if let fold {
            let leading = max(0, fold.minX - edge)
            let trailing = max(0, width - edge - fold.maxX)
            return (leading, fold.width, trailing)
        }
        let column = max(0, (width - 2 * edge - gutter) / 2)
        return (column, gutter, column)
    }
}

/// Counts hinge changes on iOS 27.1 and later. Does nothing on earlier systems.
private struct HingeChangeCounter: ViewModifier {
    @Binding var count: Int

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, _ in count += 1 }
        } else {
            content
        }
    }
}
