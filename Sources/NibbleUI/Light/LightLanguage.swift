import Foundation
import NibbleCore

extension BackgroundMotion {
    /// The board's motion for this light at rest.
    var motion: Motion {
        switch self {
        case .lava: .lava
        case .stars: .stars
        case .tunnel: .tunnel
        case .glimmer: .glimmer
        case .ripple: .rings
        }
    }

    /// How strongly it plays behind a window (the main window, the menu bar panel).
    var windowGain: Double {
        switch self {
        case .lava: 0.55
        case .stars: 0.8
        case .tunnel: 0.75
        case .glimmer: 0.7
        case .ripple: 0.9
        }
    }

    /// How strongly it plays in the idle panel. Stars stay dimmer than thinking's stars, so a
    /// question still changes the light.
    var panelGain: Double {
        switch self {
        case .lava: 0.8
        case .stars: 0.6
        case .tunnel: 0.75
        case .glimmer: 0.8
        case .ripple: 0.9
        }
    }
}

/// A state of the panel that has a light of its own.
enum LightState: String, CaseIterable {
    case idle, waiting, think, deep, search, read, look, tool, attention, writing, error
}

/// The light language: what the board does in each state of the panel, one motion per state.
///
/// Most states take one of the board's whole-board motions; typing lights the board from the
/// caret; done is a single moment; an error holds whatever is playing. A slow answer is not a
/// state of its own: the current light goes on and the status line's seconds keep counting.
struct LightLanguage {
    /// At rest the panel plays the light chosen in settings (`BackgroundMotion`); this is the
    /// default before settings say otherwise.
    var idle: Motion? = .lava
    var typing: TypingLight? = .trail
    /// Waiting for the first word: a light goes round the edges, shone in from outside.
    var waiting: Motion? = .circuit
    var think: Motion? = .stars
    var deep: Motion? = .warp
    var search: Motion? = .across
    var read: Motion? = .page
    var look: Motion? = .fill
    var tool: Motion? = .terminal
    var attention: Motion? = .cursor
    var writing: Motion? = .flow
    var done: Moment? = .bloom
    var error: ErrorHold? = .stall

    /// Thinking for longer than this turns into deep thinking: the stars start drifting toward the
    /// viewer, and from 5 s the tunnel gathers pace (see `warpSpeed`).
    static let deepAfter: TimeInterval = 2.5

    /// The motion for a state and how strongly it plays.
    func motion(for state: LightState) -> (motion: Motion?, gain: Double) {
        switch state {
        case .idle: (idle, 0.8)
        case .waiting: (waiting, 1)
        case .think: (think, 1)
        case .deep: (deep, 1)
        case .search: (search, 1)
        case .read: (read, 1)
        case .look: (look, 1)
        case .tool: (tool, 1)
        case .attention: (attention, 1)
        case .writing: (writing, 0.85)
        case .error: (nil, 1)
        }
    }

    /// How warm a fast answer makes the board: none below about 25 tokens a second, most above 100.
    static func speedWarmth(_ tokensPerSecond: Double) -> Double {
        0.75 * min(1, max(0, (tokensPerSecond - 25) / 85))
    }

    /// How warm a failed request leaves the board.
    static let errorWarmth = 0.55
}
