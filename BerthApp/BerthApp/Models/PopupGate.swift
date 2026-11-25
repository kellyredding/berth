import Foundation

/// Whether a popup window ever appears. A popup starts hidden and appears
/// only once an in-scope page has committed and stayed for `grace`; a
/// main-frame navigation out of scope before then goes to the browser and the
/// popup closes, so a link sent through an in-scope redirector never leaves
/// an empty window behind. Blank pages decide nothing.
struct PopupGate: Equatable {
    enum State: Equatable {
        case pending
        /// An in-scope page committed; shown when grace `generation` elapses.
        case settling(generation: Int)
        case shown
        case closed
    }

    enum Action: Equatable {
        /// Nothing to do; a navigation goes ahead as the link policy says.
        case none
        /// Let a navigation load while the popup stays hidden.
        case allow
        /// Call `graceElapsed(generation)` after `grace`.
        case startGrace(generation: Int)
        case show
        /// Cancel the navigation, open it in the browser, close the popup.
        case handOffAndClose
        /// Cancel the navigation and close the popup.
        case close
    }

    /// Inferred, not measured: a redirector page navigates away within
    /// milliseconds of committing, well inside this.
    static let grace: TimeInterval = 1.0

    private(set) var state: State = .pending
    private var generation = 0

    var isShown: Bool { state == .shown }

    /// A main-frame navigation the link policy routed. Once shown, the popup
    /// behaves like any window and the caller follows the route as before.
    mutating func navigation(_ route: LinkPolicy.Route) -> Action {
        switch state {
        case .shown, .closed:
            return .none
        case .pending, .settling:
            switch route {
            case .app:
                return .allow
            case .browser:
                state = .closed
                return .handOffAndClose
            case .ignore:
                state = .closed
                return .close
            }
        }
    }

    /// A main-frame page committed; `inScope` when it is a web page on a kept
    /// host, never for about:blank.
    mutating func committed(inScope: Bool) -> Action {
        switch state {
        case .shown, .closed:
            return .none
        case .pending, .settling:
            guard inScope else { return .none }
            generation += 1
            state = .settling(generation: generation)
            return .startGrace(generation: generation)
        }
    }

    mutating func graceElapsed(_ generation: Int) -> Action {
        guard state == .settling(generation: generation) else { return .none }
        state = .shown
        return .show
    }
}
