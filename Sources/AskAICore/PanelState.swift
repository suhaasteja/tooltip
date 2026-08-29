import Foundation

/// What the result panel is currently showing.
public enum PanelState: Equatable {
    case idle
    case loading(selection: String)
    case success(selection: String, answer: String)
    case failure(selection: String, message: String, retryable: Bool)
    /// The service fired but the pasteboard carried nothing usable.
    case emptySelection

    /// The selection this state relates to, if any. Retry needs it.
    public var selection: String? {
        switch self {
        case .idle, .emptySelection: return nil
        case .loading(let s): return s
        case .success(let s, _): return s
        case .failure(let s, _, _): return s
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// Drives `PanelState` transitions.
///
/// A separate type from the view so the transition rules are testable without
/// any UI. Notably it rejects results that arrive after a newer request started,
/// which is what stops a slow first answer from overwriting a fast second one.
public final class PanelViewModel {
    public private(set) var state: PanelState = .idle

    /// Monotonic id of the in-flight request. Bumped on every `startLoading`.
    public private(set) var currentRequestID: UInt64 = 0

    public var onChange: ((PanelState) -> Void)?

    public init() {}

    private func transition(to newState: PanelState) {
        state = newState
        onChange?(newState)
    }

    /// Begins a new request, invalidating any in-flight one.
    /// - Returns: The id to pass back to `finish`/`fail`.
    @discardableResult
    public func startLoading(selection: String) -> UInt64 {
        currentRequestID &+= 1
        transition(to: .loading(selection: selection))
        return currentRequestID
    }

    public func showEmptySelection() {
        currentRequestID &+= 1
        transition(to: .emptySelection)
    }

    /// Applies a successful result, ignoring it if superseded.
    /// - Returns: `true` if the state changed.
    @discardableResult
    public func finish(requestID: UInt64, answer: String) -> Bool {
        guard requestID == currentRequestID, let selection = state.selection else { return false }
        transition(to: .success(selection: selection, answer: answer))
        return true
    }

    /// Applies a failure, ignoring it if superseded.
    @discardableResult
    public func fail(requestID: UInt64, message: String, retryable: Bool = true) -> Bool {
        guard requestID == currentRequestID, let selection = state.selection else { return false }
        transition(to: .failure(selection: selection, message: message, retryable: retryable))
        return true
    }

    /// Dismissal. Also invalidates in-flight work so a late reply cannot
    /// resurrect a closed panel.
    public func reset() {
        currentRequestID &+= 1
        transition(to: .idle)
    }
}
