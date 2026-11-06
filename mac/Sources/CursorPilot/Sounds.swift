import AppKit

/// Short, quiet system sounds for moments worth hearing. Settings › On
/// screen › Sound effects turns them off.
@MainActor
enum Sounds {
    enum Cue {
        /// You started talking.
        case listen
        /// Your question went off.
        case send
        /// A task with steps finished.
        case done
        case error
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? true }

    static func play(_ cue: Cue) {
        guard enabled else { return }
        let (name, volume): (String, Float) = switch cue {
        case .listen: ("Tink", 0.25)
        case .send: ("Pop", 0.22)
        case .done: ("Glass", 0.3)
        case .error: ("Funk", 0.3)
        }
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
