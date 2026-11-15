import Foundation
import Observation

/// What actions with no screen of their own (a menu's "Mark as Watched", say) have to say: an
/// error, shown as an alert; a question to answer before a change that rewrites a lot, as
/// marking a whole show watched does; and a change just made that can be taken back for a few
/// seconds, offered in a toast. The root view shows all three.
@Observable
final class AppMessages {
    var current: String?
    /// The question waiting for an answer.
    var confirmation: Confirmation?
    /// The change the toast offers to take back.
    private(set) var undoOffer: UndoOffer?

    func show(_ message: String) {
        current = message
    }

    func ask(_ confirmation: Confirmation) {
        self.confirmation = confirmation
    }

    /// Offers to take a change back, in place of any change offered before, which then stands.
    func offerUndo(_ offer: UndoOffer) {
        if let earlier = undoOffer, earlier.id != offer.id { earlier.expire() }
        undoOffer = offer
    }

    /// Takes the change back, while it's still offered.
    func undo(_ id: UUID) {
        guard let offer = undoOffer, offer.id == id else { return }
        undoOffer = nil
        offer.undo()
    }

    /// The time to take the change back is over, and it stands.
    func expireUndo(_ id: UUID) {
        guard let offer = undoOffer, offer.id == id else { return }
        undoOffer = nil
        offer.expire()
    }

    /// Stops offering the change, as one that didn't go through.
    func withdrawUndo(_ id: UUID) {
        if undoOffer?.id == id { undoOffer = nil }
    }
}

/// A question before a change: what it is, what it does, and the button that goes ahead.
struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// The button that makes the change.
    let action: String
    let perform: () -> Void
}

/// A change just made that can be taken back, as the toast says it: "Marked as Watched" over
/// "Port Ellery".
struct UndoOffer: Identifiable {
    var id = UUID()
    let title: String
    let detail: String
    /// What VoiceOver says as it's offered.
    let announcement: String
    let undo: () -> Void
    /// Called once the time to take it back is over.
    var expire: () -> Void = {}
}
