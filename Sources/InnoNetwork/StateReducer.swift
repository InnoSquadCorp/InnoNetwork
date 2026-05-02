/// Generic value returned by reducers that emit a new state plus ordered
/// side-effect descriptions for the caller to interpret.
public struct StateReduction<State: Sendable, Effect: Sendable>: Sendable {
    public let state: State
    public let effects: [Effect]

    public init(state: State, effects: [Effect] = []) {
        self.state = state
        self.effects = effects
    }
}

/// Common shape for reducer-driven lifecycle logic.
public protocol StateReducer: Sendable {
    associatedtype State: Sendable
    associatedtype Event: Sendable
    associatedtype Context: Sendable
    associatedtype Reduction: Sendable

    static func reduce(
        state: State,
        event: Event,
        context: Context
    ) -> Reduction
}
