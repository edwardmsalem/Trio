import Combine
import SwiftUI

struct RoundedBackground: ViewModifier {
    private let color: Color

    init(color: Color = Color("CapsuleColor")) {
        self.color = color
    }

    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill()
                    .foregroundColor(color)
            )
    }
}

struct CapsulaBackground: ViewModifier {
    private let color: Color

    init(color: Color = Color("CapsuleColor")) {
        self.color = color
    }

    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                Capsule()
                    .fill()
                    .foregroundColor(color)
            )
    }
}

private let navigationCache = LRUCache<Screen.ID, AnyView>(capacity: 10)

struct NavigationLazyView: View {
    let build: () -> AnyView
    let screen: Screen

    init(_ build: @autoclosure @escaping () -> AnyView, screen: Screen) {
        self.build = build
        self.screen = screen
    }

    var body: AnyView {
        if navigationCache[screen.id] == nil {
            navigationCache[screen.id] = build()
        }
        return navigationCache[screen.id]!
            .onDisappear {
                navigationCache[screen.id] = nil
            }.asAny()
    }
}

struct Link: ViewModifier {
    let screen: Screen

    init(screen: Screen) {
        self.screen = screen
    }

    func body(content: Content) -> some View {
        PushRow(value: screen) { content }
    }
}

extension EnvironmentValues {
    /// Set on the Settings list when it is the sidebar of a split view (the open iPhone Duo). Its rows
    /// then push onto the detail stack. A plain value link in a sidebar replaces the whole detail
    /// column instead, which leaves the opened screen without a stack, so its own rows do nothing.
    @Entry var pushToSettingsDetail: ((any Hashable) -> Void)?
}

/// A navigation row: a value link, or a button that pushes onto the Settings detail stack when the
/// row sits in the split view sidebar.
struct PushRow<Value: Hashable, Label: View>: View {
    let value: Value
    @ViewBuilder let label: Label
    @Environment(\.pushToSettingsDetail) private var pushToSettingsDetail

    var body: some View {
        if let pushToSettingsDetail {
            Button {
                pushToSettingsDetail(value)
            } label: {
                HStack {
                    label
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: value) { label }
        }
    }
}

struct ScreenNavigation<T>: ViewModifier where T: View {
    private let destination: (Screen) -> T

    init(destination: @escaping (Screen) -> T) {
        self.destination = destination
    }

    func body(content: Content) -> some View {
        content.navigationDestination(
            for: Screen.self,
            destination: { screen in NavigationLazyView(destination(screen).asAny(), screen: screen) }
        )
    }
}

struct AdaptsToSoftwareKeyboard: ViewModifier {
    @State var currentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, currentHeight).animation(.easeOut(duration: 0.25))
            .edgesIgnoringSafeArea(currentHeight == 0 ? Edge.Set() : .bottom)
            .onAppear(perform: subscribeToKeyboardChanges)
    }

    private let keyboardHeightOnOpening = Foundation.NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillShowNotification)
        .map { $0.userInfo![UIResponder.keyboardFrameEndUserInfoKey] as! CGRect }
        .map(\.height)

    private let keyboardHeightOnHiding = Foundation.NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillHideNotification)
        .map { _ in CGFloat(0) }

    private func subscribeToKeyboardChanges() {
        _ = Publishers.Merge(keyboardHeightOnOpening, keyboardHeightOnHiding)
            .subscribe(on: DispatchQueue.main)
            .sink { height in
                if self.currentHeight == 0 || height == 0 {
                    self.currentHeight = height
                }
            }
    }
}

struct ClearButton: ViewModifier {
    @Binding var text: String
    func body(content: Content) -> some View {
        HStack {
            content
            if !text.isEmpty {
                Button { self.text = "" }
                label: {
                    Image(systemName: "delete.left")
                        .foregroundColor(.gray)
                }
            }
        }
    }
}

extension View {
    func roundedBackground() -> some View {
        modifier(RoundedBackground())
    }

    func buttonBackground() -> some View {
        modifier(RoundedBackground(color: .accentColor))
    }

    func navigationLink<V: BaseView>(to screen: Screen, from _: V) -> some View {
        modifier(Link(screen: screen))
    }

    func screenNavigation<V: BaseView>(_ view: V) -> some View {
        modifier(ScreenNavigation { screen in
            view.state.view(for: screen)
        })
    }

    func adaptsToSoftwareKeyboard() -> some View {
        modifier(AdaptsToSoftwareKeyboard())
    }

    func modal<V: BaseView>(for screen: Screen?, from view: V) -> some View {
        onTapGesture {
            view.state.showModal(for: screen)
        }
    }

    func asAny() -> AnyView { .init(self) }

    var backport: Backport<Self> { Backport(content: self) }
}

struct Backport<Content: View> {
    let content: Content
}

extension View {
    /// Sizes the view to a share of its container's width (the window, a split view column or the
    /// enclosing scroll view) instead of `UIScreen.main`. The layout then re-flows whenever the
    /// window changes size, for example when an iPhone Duo is folded or unfolded. On a normal
    /// iPhone the container is the full screen width, so this matches the old screen sizing.
    func containerWidth(_ fraction: CGFloat = 1, minus inset: CGFloat = 0, alignment: Alignment = .center) -> some View {
        containerRelativeFrame(.horizontal, alignment: alignment) { length, _ in
            max(0, length * fraction - inset)
        }
    }
}

extension View {
    /// Adds the "+ Treatment" bar item when `isEnabled`. It keeps a high visibility priority so a
    /// vertical side strip or a narrow bar never folds it into the overflow menu.
    func treatmentToolbarItem<Item: View>(isEnabled: Bool, @ViewBuilder item: () -> Item) -> some View {
        modifier(TreatmentToolbarItem(isEnabled: isEnabled, item: item()))
    }
}

private struct TreatmentToolbarItem<Item: View>: ViewModifier {
    let isEnabled: Bool
    let item: Item

    func body(content: Content) -> some View {
        content.toolbar {
            if isEnabled {
                if #available(iOS 27.0, *) {
                    ToolbarItem(placement: .primaryAction) { item }
                        .visibilityPriority(.high)
                } else {
                    ToolbarItem(placement: .primaryAction) { item }
                }
            }
        }
    }
}

/// Reports whether iOS currently shows the bars vertically at the side of the screen. That
/// happens on the folded outer screen of iPhone Duo and in some inner screen poses. Always false
/// before iOS 27.1, so normal iPhones are unaffected.
struct VerticalBarReader: ViewModifier {
    @Binding var isVertical: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.background(VerticalBarEdgeProbe(isVertical: $isVertical))
        } else {
            content
        }
    }
}

@available(iOS 27.1, *) private struct VerticalBarEdgeProbe: View {
    @Binding var isVertical: Bool
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    var body: some View {
        Color.clear
            .onChange(of: verticalEdge != nil, initial: true) { _, vertical in
                if isVertical != vertical { isVertical = vertical }
            }
    }
}

extension View {
    /// Keeps a custom control, such as a pinned bottom button bar, out of the iPhone Duo fold.
    /// When an active fold crosses the view, the content moves to the larger side of it (a fold
    /// running top to bottom) or below it (a fold running side to side). Standard sheets, alerts
    /// and bars already do this, so it is only for custom controls. Does nothing when there is no
    /// active fold, which covers every normal iPhone and an open, flat iPhone Duo.
    func avoidsFold() -> some View {
        modifier(FoldAvoiding())
    }
}

private struct FoldAvoiding: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(FoldAvoidingPadding())
        } else {
            content
        }
    }
}

@available(iOS 27.1, *) private struct FoldAvoidingPadding: ViewModifier {
    @State private var insets = EdgeInsets()
    @State private var hingeChanges = 0

    func body(content: Content) -> some View {
        content
            .padding(insets)
            // measured outside the padding, so the padding never feeds back into the measurement
            .background(
                GeometryReader { geo in
                    let folds = geo.reservedRegions(kind: .division).map(\.frame)
                    Color.clear.onChange(of: FoldSnapshot(size: geo.size, folds: folds, tick: hingeChanges), initial: true) {
                        _, snapshot in
                        let updated = snapshot.insets
                        if updated != insets { insets = updated }
                    }
                }
            )
            .onHingeChange { _, _ in hingeChanges += 1 }
    }
}

private struct FoldSnapshot: Equatable {
    let size: CGSize
    let folds: [CGRect]
    let tick: Int

    var insets: EdgeInsets {
        var result = EdgeInsets()
        let bounds = CGRect(origin: .zero, size: size)
        for fold in folds where fold.intersects(bounds) {
            if fold.height >= fold.width {
                // fold runs top to bottom: keep the content on the wider side
                if fold.minX >= size.width - fold.maxX {
                    result.trailing = max(result.trailing, size.width - fold.minX)
                } else {
                    result.leading = max(result.leading, fold.maxX)
                }
            } else {
                // fold runs side to side: keep the content below it
                result.top = max(result.top, fold.maxY)
            }
        }
        return result
    }
}

extension View {
    /// Keeps the tab bar and navigation bars horizontal on iPhone Duo, the way they sit on every
    /// other iPhone. Without it the folded outer screen moves the tabs into a vertical strip down
    /// the side, and Trio's floating "+" then lands on top of the Home cards. Does nothing before
    /// iOS 27.1 or on devices without a vertical bar.
    func horizontalBarsOnFoldables() -> some View {
        modifier(HorizontalBarsOnFoldables())
    }
}

private struct HorizontalBarsOnFoldables: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(.disabled)
        } else {
            content
        }
    }
}
