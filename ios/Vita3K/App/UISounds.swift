// Vita3K iOS shell app
// Soft interface sounds (library navigation, menus). The sounds are short,
// low-pitched and gently enveloped on purpose: no sharp clicks.
// The audio session category is deliberately left alone, so the core's own
// audio configuration is never disturbed.

import AVFoundation

@MainActor
final class UISounds {
    static let shared = UISounds()
    static let preference = "interface.sounds"

    enum Cue: String, CaseIterable {
        case move = "ui-move"
        case tap = "ui-tap"
        case confirm = "ui-confirm"
        case back = "ui-back"
        case open = "ui-open"

        var volume: Float {
            switch self {
            case .move: 0.55
            case .tap: 0.6
            case .confirm: 0.7
            case .back: 0.6
            case .open: 0.6
            }
        }
    }

    private var pools: [Cue: [AVAudioPlayer]] = [:]
    private var cursors: [Cue: Int] = [:]
    private var lastMove = Date.distantPast

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.preference) as? Bool ?? true
    }

    func play(_ cue: Cue) {
        guard isEnabled else { return }
        if cue == .move {
            // Fast swipes must not turn into a rattle.
            let now = Date()
            guard now.timeIntervalSince(lastMove) > 0.07 else { return }
            lastMove = now
        }
        let pool = players(for: cue)
        guard !pool.isEmpty else { return }
        let index = (cursors[cue] ?? 0) % pool.count
        cursors[cue] = index + 1
        let player = pool[index]
        player.currentTime = 0
        player.play()
    }

    private func players(for cue: Cue) -> [AVAudioPlayer] {
        if let pool = pools[cue] { return pool }
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav") else {
            pools[cue] = []
            return []
        }
        // Two players per cue so quick repeats overlap instead of cutting off.
        let pool = (0..<2).compactMap { _ -> AVAudioPlayer? in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.volume = cue.volume
            player.prepareToPlay()
            return player
        }
        pools[cue] = pool
        return pool
    }
}
