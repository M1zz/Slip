import Foundation

/// Algorithms for deciding which notes to resurface, grounded in memory research.
///
/// References:
/// - Ebbinghaus (1885): forgetting follows an exponential decay ~ exp(-t / S),
///   where S is memory strength.
/// - Bjork (1994): "desirable difficulty" — retrieval is most beneficial when
///   the item is slightly forgotten (recall probability ~ 0.4–0.7), not when
///   it's fresh, and not when it's fully lost.
/// - Karpicke & Roediger (2008): spaced retrieval outperforms re-reading.
///
/// We don't try to model spaced-repetition cards (SM-2, FSRS) because notes
/// aren't flashcards. Instead we derive a continuous `forgettingScore` that
/// peaks in the "almost forgotten" zone.
public enum SpacingAlgorithm {

    /// Estimated retrievability r ∈ (0, 1] given time since last view and
    /// a "stability" proxy derived from view count.
    ///
    /// If the note has never been viewed, we pretend it was viewed once at
    /// creation time — rewarding old but unopened notes.
    public static func retrievability(
        lastViewedAt: Date?,
        viewCount: Int,
        createdAt: Date,
        now: Date = Date()
    ) -> Double {
        let referenceDate = lastViewedAt ?? createdAt
        let days = max(0, now.timeIntervalSince(referenceDate) / 86_400)

        // Stability grows with repeated views (consolidation).
        // Baseline stability: 3 days. Each view roughly doubles stability,
        // capped to prevent runaway.
        let views = max(1, viewCount)
        let stability = min(3.0 * pow(1.7, Double(views - 1)), 180.0)

        // r = exp(-t / S), classic Ebbinghaus form.
        return exp(-days / stability)
    }

    /// Bjork-style "desirable difficulty" score: peaks at r ≈ 0.5.
    /// Returns a value in [0, 1].
    public static func desirableDifficulty(retrievability r: Double) -> Double {
        // Triangle peaked at 0.5: 1 - 2 * |r - 0.5|. Clamp to [0, 1].
        let score = 1.0 - 2.0 * abs(r - 0.5)
        return max(0, min(1, score))
    }
}
