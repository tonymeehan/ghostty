import SwiftUI
import GhosttyKit

extension Ghostty {
    /// A spittable terminal view is one where the terminal allows for "splits" (vertical and horizontal) within the
    /// view. The terminal starts in the unsplit state (a plain ol' TerminalView) but responds to changes to the
    /// split direction by splitting the terminal.
    struct TerminalSplit: View {
        @Environment(\.ghosttyApp) private var app
        let onClose: (() -> Void)?
        
        var body: some View {
            if let app = app {
                TerminalSplitRoot(app: app, onClose: onClose)
            }
        }
    }
    
    /// This enum represents the possible states that a node in the split tree can be in. It is either:
    ///
    ///   - noSplit - This is an unsplit, single pane. This contains only a "leaf" which has a single
    ///   terminal surface to render.
    ///   - horizontal/vertical - This is split into the horizontal or vertical direction. This contains a
    ///   "container" which has a recursive top/left SplitNode and bottom/right SplitNode. These
    ///   values can further be split infinitely.
    ///
    enum SplitNode {
        case noSplit(Leaf)
        case horizontal(Container)
        case vertical(Container)
        
        /// Returns the view that would prefer receiving focus in this tree. This is always the
        /// top-left-most view. This is used when creating a split or closing a split to find the
        /// next view to send focus to.
        func preferredFocus() -> SurfaceView {
            switch (self) {
            case .noSplit(let leaf):
                return leaf.surface
                
            case .horizontal(let container):
                return container.topLeft.preferredFocus()
                
            case .vertical(let container):
                return container.topLeft.preferredFocus()
            }
        }
        
        class Leaf: ObservableObject {
            let app: ghostty_app_t
            @Published var surface: SurfaceView
            
            /// Initialize a new leaf which creates a new terminal surface.
            init(_ app: ghostty_app_t) {
                self.app = app
                self.surface = SurfaceView(app)
            }
        }
        
        class Container: ObservableObject {
            let app: ghostty_app_t
            @Published var topLeft: SplitNode
            @Published var bottomRight: SplitNode
            
            /// A container is always initialized from some prior leaf because a split has to originate
            /// from a non-split value. When initializing, we inherit the leaf's surface and then
            /// initialize a new surface for the new pane.
            init(from: Leaf) {
                self.app = from.app
                
                // Initially, both topLeft and bottomRight are in the "nosplit"
                // state since this is a new split.
                self.topLeft = .noSplit(from)
                self.bottomRight = .noSplit(.init(app))
            }
        }
    }
    
    /// The root of a split tree. This sets up the initial SplitNode state and renders. There is only ever
    /// one of these in a split tree.
    private struct TerminalSplitRoot: View {
        @State private var node: SplitNode
        @State private var requestClose: Bool = false
        let onClose: (() -> Void)?
        
        @FocusedValue(\.ghosttySurfaceTitle) private var surfaceTitle: String?
        
        init(app: ghostty_app_t, onClose: (() ->Void)? = nil) {
            self.onClose = onClose
            _node = State(wrappedValue: SplitNode.noSplit(.init(app)))
        }
        
        var body: some View {
            ZStack {
                switch (node) {
                case .noSplit(let leaf):
                    TerminalSplitLeaf(leaf: leaf, node: $node, requestClose: $requestClose)
                        .onChange(of: requestClose) { value in
                            guard value else { return }
                            guard let onClose = self.onClose else { return }
                            onClose()
                        }
                    
                case .horizontal(let container):
                    TerminalSplitContainer(direction: .horizontal, node: $node, container: container)
                    
                case .vertical(let container):
                    TerminalSplitContainer(direction: .vertical, node: $node, container: container)
                }
            }
            .navigationTitle(surfaceTitle ?? "Ghostty")
        }
    }
    
    /// A noSplit leaf node of a split tree.
    private struct TerminalSplitLeaf: View {
        /// The leaf to draw the surface for.
        let leaf: SplitNode.Leaf
        
        /// The SplitNode that the leaf belongs to.
        @Binding var node: SplitNode
        
        ///  This will be set to true when the split requests that is become closed.
        @Binding var requestClose: Bool
        
        var body: some View {
            let center = NotificationCenter.default
            let pub = center.publisher(for: Notification.ghosttyNewSplit, object: leaf.surface)
            let pubClose = center.publisher(for: Notification.ghosttyCloseSurface, object: leaf.surface)
            let pubFocus = center.publisher(for: Notification.ghosttyFocusSplit, object: leaf.surface)
            SurfaceWrapper(surfaceView: leaf.surface)
                .onReceive(pub) { onNewSplit(notification: $0) }
                .onReceive(pubClose) { _ in requestClose = true }
                .onReceive(pubFocus) { onMoveFocus(notification: $0) }
        }
        
        private func onNewSplit(notification: SwiftUI.Notification) {
            // Determine our desired direction
            guard let directionAny = notification.userInfo?["direction"] else { return }
            guard let direction = directionAny as? ghostty_split_direction_e else { return }
            var splitDirection: SplitViewDirection
            switch (direction) {
            case GHOSTTY_SPLIT_RIGHT:
                splitDirection = .horizontal
                
            case GHOSTTY_SPLIT_DOWN:
                splitDirection = .vertical
                
            default:
                return
            }
            
            // Setup our new container since we are now split
            let container = SplitNode.Container(from: leaf)
            
            // Depending on the direction, change the parent node. This will trigger
            // the parent to relayout our views.
            switch (splitDirection) {
            case .horizontal:
                node = .horizontal(container)
            case .vertical:
                node = .vertical(container)
            }
            
            // See fixFocus comment, we have to run this whenever split changes.
            Self.fixFocus(container.bottomRight, previous: node)
        }
        
        private func onMoveFocus(notification: SwiftUI.Notification) {
            // Determine our desired direction
            guard let directionAny = notification.userInfo?[Notification.SplitDirectionKey] else { return }
            guard let direction = directionAny as? SplitFocusDirection else { return }
            print("MOVE FOCUS: \(direction)")
        }
        
        /// There is a bug I can't figure out where when changing the split state, the terminal view
        /// will lose focus. There has to be some nice SwiftUI-native way to fix this but I can't
        /// figure it out so we're going to do this hacky thing to bring focus back to the terminal
        /// that should have it.
        fileprivate static func fixFocus(_ target: SplitNode, previous: SplitNode) {
            let view = target.preferredFocus()
            
            DispatchQueue.main.async {
                // If the callback runs before the surface is attached to a view
                // then the window will be nil. We just reschedule in that case.
                guard let window = view.window else {
                    self.fixFocus(target, previous: previous)
                    return
                }

                window.makeFirstResponder(view)
                
                // If we had a previously focused node and its not where we're sending
                // focus, make sure that we explicitly tell it to lose focus. In theory
                // we should NOT have to do this but the focus callback isn't getting
                // called for some reason.
                let previous = previous.preferredFocus()
                if previous != view {
                    _ = previous.resignFirstResponder()
                }
            }
        }
    }
    
    /// This represents a split view that is in the horizontal or vertical split state.
    private struct TerminalSplitContainer: View {
        let direction: SplitViewDirection
        @Binding var node: SplitNode
        @StateObject var container: SplitNode.Container
        
        @State private var closeTopLeft: Bool = false
        @State private var closeBottomRight: Bool = false
        
        var body: some View {
            SplitView(direction, left: {
                TerminalSplitNested(node: $container.topLeft, requestClose: $closeTopLeft)
                    .onChange(of: closeTopLeft) { value in
                        guard value else { return }
                        
                        // When closing the topLeft, our parent becomes the bottomRight.
                        node = container.bottomRight
                        TerminalSplitLeaf.fixFocus(node, previous: container.topLeft)
                    }
            }, right: {
                TerminalSplitNested(node: $container.bottomRight, requestClose: $closeBottomRight)
                    .onChange(of: closeBottomRight) { value in
                        guard value else { return }
                        
                        // When closing the bottomRight, our parent becomes the topLeft.
                        node = container.topLeft
                        TerminalSplitLeaf.fixFocus(node, previous: container.bottomRight)
                    }
            })
        }
    }
    
    /// This is like TerminalSplitRoot, but... not the root. This renders a SplitNode in any state but
    /// requires there be a binding to the parent node.
    private struct TerminalSplitNested: View {
        @Binding var node: SplitNode
        @Binding var requestClose: Bool
        
        var body: some View {
            switch (node) {
            case .noSplit(let leaf):
                TerminalSplitLeaf(leaf: leaf, node: $node, requestClose: $requestClose)
            
            case .horizontal(let container):
                TerminalSplitContainer(direction: .horizontal, node: $node, container: container)
                
            case .vertical(let container):
                TerminalSplitContainer(direction: .vertical, node: $node, container: container)
            }
        }
    }
}
