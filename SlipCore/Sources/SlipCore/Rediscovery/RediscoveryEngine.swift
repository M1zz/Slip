import Foundation

/// Decides which old notes to resurface to the user.
///
/// Produces a ranked list of `RediscoveryCard` values. Each card carries its
/// rationale — we don't hide the scoring, because the user learning *why* a
/// note came back is half the value (it builds metacognition about their own
/// knowledge structure).
///
/// Design principles:
/// 1. **Spacing > recency**: recent notes are low priority. The prize is the
///    note you'd forgotten existed.
/// 2. **Orphans over hubs**: a note with 3 incoming links will be found by
///    navigation. A note with 0 links won't — it needs a lifeline.
/// 3. **Context when available**: if the user is viewing note N, boost notes
///    that share tags or are 2 hops away in the link graph.
/// 4. **Deterministic seed**: within a calendar day the surface is stable, so
///    the user can return to "today's rediscovery" without reshuffling.
public final class RediscoveryEngine {

    public struct Config {
        public var dailyCount: Int = 5
        public var orphanBoost: Double = 0.25
        public var weakTieBoost: Double = 0.15
        public var minDaysSinceView: Double = 7
        public var contextTagBoost: Double = 0.20

        public init() {}
    }

    public struct RediscoveryCard: Identifiable {
        public let id: NoteID
        public let title: String
        public let score: Double
        public let reasons: [Reason]

        public enum Reason: String, CaseIterable {
            case forgotten       // high desirable-difficulty
            case orphan          // no incoming links, low view count
            case weakTie         // shares context but not direct link
            case sharesTag       // shares a tag with current note
            case untouched       // created long ago, never opened
        }
    }

    public struct Context {
        public let currentNoteID: NoteID?
        public let currentNoteTags: Set<String>
        public let linkedTargets: Set<NoteID>      // notes the current one links to
        public let twoHopNeighbors: Set<NoteID>    // neighbors of neighbors

        public init(
            currentNoteID: NoteID? = nil,
            currentNoteTags: Set<String> = [],
            linkedTargets: Set<NoteID> = [],
            twoHopNeighbors: Set<NoteID> = []
        ) {
            self.currentNoteID = currentNoteID
            self.currentNoteTags = currentNoteTags
            self.linkedTargets = linkedTargets
            self.twoHopNeighbors = twoHopNeighbors
        }

        public static let none = Context()
    }

    public var config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Score every note and return the top `config.dailyCount`.
    public func rediscover(
        from metrics: [NoteIndex.NoteMetrics],
        context: Context = .none,
        metricsTagMap: [NoteID: Set<String>] = [:],
        now: Date = Date()
    ) -> [RediscoveryCard] {
        var scored: [(RediscoveryCard, Double)] = []

        for m in metrics {
            // Skip the note the user is currently reading.
            if let current = context.currentNoteID, m.id == current { continue }

            // Skip very recently viewed notes.
            if let lv = m.lastViewedAt,
               now.timeIntervalSince(lv) / 86_400 < config.minDaysSinceView {
                continue
            }

            let r = SpacingAlgorithm.retrievability(
                lastViewedAt: m.lastViewedAt,
                viewCount: m.viewCount,
                createdAt: m.createdAt,
                now: now
            )
            let dd = SpacingAlgorithm.desirableDifficulty(retrievability: r)

            var score = dd
            var reasons: [RediscoveryCard.Reason] = []
            if dd > 0.5 { reasons.append(.forgotten) }

            // Orphan rescue.
            if m.incomingLinks == 0 && m.viewCount < 2 {
                score += config.orphanBoost
                reasons.append(.orphan)
            }

            // Untouched: never viewed + older than 30 days.
            if m.lastViewedAt == nil,
               now.timeIntervalSince(m.createdAt) / 86_400 > 30 {
                reasons.append(.untouched)
            }

            // Contextual boosts.
            let tags = metricsTagMap[m.id] ?? []
            if !context.currentNoteTags.isDisjoint(with: tags) {
                score += config.contextTagBoost
                reasons.append(.sharesTag)
            }
            if context.twoHopNeighbors.contains(m.id),
               !context.linkedTargets.contains(m.id) {
                score += config.weakTieBoost
                reasons.append(.weakTie)
            }

            // Dedup reasons while preserving order.
            var seen = Set<RediscoveryCard.Reason>()
            reasons = reasons.filter { seen.insert($0).inserted }

            if !reasons.isEmpty {
                let card = RediscoveryCard(
                    id: m.id,
                    title: m.title,
                    score: score,
                    reasons: reasons
                )
                scored.append((card, score))
            }
        }

        // Sort by score desc, then by a daily-stable tiebreaker so refreshing
        // the same day doesn't shuffle results.
        let dayKey = Self.dayKey(for: now)
        scored.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return hash(lhs.0.id, salt: dayKey) < hash(rhs.0.id, salt: dayKey)
        }

        return scored.prefix(config.dailyCount).map { $0.0 }
    }

    // MARK: - Helpers

    private static func dayKey(for date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return (comps.year ?? 0) * 10_000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
    }

    private func hash(_ id: NoteID, salt: Int) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(id.relativePath)
        hasher.combine(salt)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
