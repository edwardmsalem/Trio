import SwiftUI

struct Popup<T: View>: ViewModifier {
    let popup: T
    let isPresented: Bool
    let alignment: Alignment
    let direction: Direction

    init(isPresented: Bool, alignment: Alignment, direction: Direction, @ViewBuilder content: () -> T) {
        self.isPresented = isPresented
        self.alignment = alignment
        self.direction = direction
        popup = content()
    }

    func body(content: Content) -> some View {
        content
            .overlay(popupContent())
    }

    @ViewBuilder private func popupContent() -> some View {
        GeometryReader { geometry in
            if isPresented {
                popup
                    .animation(.spring())
                    .transition(.offset(
                        x: 0,
                        y: direction.offset(
                            popupFrame: geometry.frame(in: .global),
                            containerHeight: geometry.size.height + geometry.safeAreaInsets.bottom
                        )
                    ))
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: alignment)
            }
        }
    }
}

extension Popup {
    enum Direction {
        case top
        case bottom

        /// Distance that moves the popup just past the container edge. Uses the container's own
        /// geometry rather than the screen, so it stays right when the window is resized.
        func offset(popupFrame: CGRect, containerHeight: CGFloat) -> CGFloat {
            switch self {
            case .top:
                let aboveScreenEdge = -popupFrame.maxY
                return aboveScreenEdge
            case .bottom:
                let belowContainerEdge = popupFrame.minY + containerHeight
                return belowContainerEdge
            }
        }
    }
}

extension View {
    func popup<T: View>(
        isPresented: Bool,
        alignment: Alignment = .center,
        direction: Popup<T>.Direction = .bottom,
        @ViewBuilder content: () -> T
    ) -> some View {
        modifier(Popup(isPresented: isPresented, alignment: alignment, direction: direction, content: content))
    }
}
