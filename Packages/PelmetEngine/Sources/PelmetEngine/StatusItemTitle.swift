import Foundation

/// Match a status item's title to its agent frame. A text status item can be
/// wider than an application's main menu; menu width does not identify it.
enum StatusItemTitle {
    struct Candidate {
        let title: String?
        let frame: CGRect?
        let isExtrasBar: Bool
    }

    static func resolve(_ candidates: [Candidate], groupFrame: CGRect) -> String? {
        let matching = candidates.compactMap { candidate -> (Candidate, CGFloat)? in
            guard let frame = candidate.frame, !frame.isEmpty else { return nil }
            let overlap = frame.intersection(groupFrame)
            guard !overlap.isNull, !overlap.isEmpty else { return nil }
            return (candidate, overlap.width * overlap.height)
        }.sorted {
            if $0.0.isExtrasBar != $1.0.isExtrasBar { return $0.0.isExtrasBar }
            return $0.1 > $1.1
        }
        if let match = matching.first { return nonempty(match.0.title) }
        // Some apps omit AXFrame. Only an explicit, single extras item is
        // unambiguous without geometry; never guess from a main menu title.
        let extras = candidates.filter(\.isExtrasBar)
        guard extras.count == 1, extras[0].frame == nil else { return nil }
        return nonempty(extras[0].title)
    }

    private static func nonempty(_ title: String?) -> String? {
        title?.isEmpty == false ? title : nil
    }
}
