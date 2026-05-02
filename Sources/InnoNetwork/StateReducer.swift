/// Generic value returned by reducers that emit a new state plus ordered
/// side-effect descriptions for the caller to interpret.
public struct StateReduction<State: Sendable, Effect: Sendable>: Sendable {
    /// The next state after the reducer has applied an event.
    public let state: State
    /// Side effects the reducer wants the caller to perform, in order.
    public let effects: [Effect]

    /// Construct a reduction result.
    /// - Parameters:
    ///   - state: The next state to apply.
    ///   - effects: Side effects to perform in order. Defaults to an empty list
    ///     for transitions that only update state.
    public init(state: State, effects: [Effect] = []) {
        self.state = state
        self.effects = effects
    }
}

/// Common shape for reducer-driven lifecycle logic.
public protocol StateReducer: Sendable {
    /// The reducer's persistent input — typically a value type representing a
    /// snapshot of the lifecycle.
    associatedtype State: Sendable
    /// The transition input. A reducer must produce a deterministic
    /// `Reduction` for any `(State, Event, Context)` triple.
    associatedtype Event: Sendable
    /// Auxiliary context (configuration, clocks, derived facts) the reducer
    /// needs but does not own.
    associatedtype Context: Sendable
    /// The reducer's output shape — usually
    /// ``StateReduction`` parameterised on the state and an effect type.
    associatedtype Reduction: Sendable

    /// Compute the next reduction for a given event.
    ///
    /// Implementations must be pure: the same `(state, event, context)` must
    /// always produce the same result. Any side effects must be expressed in
    /// the returned reduction's effect list, not performed inline.
    static func reduce(
        state: State,
        event: Event,
        context: Context
    ) -> Reduction
}
