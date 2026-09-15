// PlacementLedger.swift
// Everything the placement controller remembers about an item, in one
// record per ItemID: whether it is queued for the next reveal settle, held
// for the hidden cluster, trapped in the native overflow, how long it has
// had no frame, and the budgets that stop a correction from running on
// every hover. Pure — the app layer decides when to measure and how to
// drag; this owns the bookkeeping and the budget rules, so a key removed
// from one concern is removed from all of them in one place.
//
// Before this (2026-09-12 audit): nine parallel dictionaries and sets in
// PlacementController, each flush path pruning its own subset, a leaked key
// silent.

import Foundation

public struct PlacementRecord: Equatable, Sendable {
    /// Queued for the next reveal-settle flush (`pendingPlacements`).
    public var pending = false
    /// Its drag would touch the hidden zone while that zone is absent —
    /// stays queued, tried again once a reveal materializes the cluster.
    public var deferredForReveal = false
    /// Registration trapped in the native « overflow; placed at the next
    /// conceal settle, when de-crowding gives it a real frame.
    public var rescueQueued = false
    /// First attempt that found no frame at all, until one is found.
    public var framelessSince: Date?
    /// Frameless items retry on a slow clock.
    public var framelessRetryAfter: Date?
    public var rescueAttempts = 0
    public var driftAttempts = 0
    /// After the drift budget is spent the item is left alone until here.
    public var driftCoolOffUntil: Date?

    public init() {}

    var isBlank: Bool { self == PlacementRecord() }
}

public struct PlacementLedger: Sendable {
    /// A correction is a drag under a reveal; an item that will not stay put
    /// after a few of them is left alone for a while rather than dragged on
    /// every hover.
    public static let maxDriftAttempts = 3
    public static let driftCoolOff: TimeInterval = 8 * 60
    public static let maxRescueAttempts = 3
    public static let framelessRetryInterval: TimeInterval = 30

    private var records: [ItemID: PlacementRecord] = [:]

    public init() {}

    /// A blank record reads as absent and writes as a removal — the one
    /// place a key leaves the ledger.
    public subscript(id: ItemID) -> PlacementRecord {
        get { records[id] ?? PlacementRecord() }
        set {
            if newValue.isBlank { records.removeValue(forKey: id) } else { records[id] = newValue }
        }
    }

    public var trackedIDs: Set<ItemID> { Set(records.keys) }
    public var pending: Set<ItemID> { ids { $0.pending } }
    public var rescueQueued: Set<ItemID> { ids { $0.rescueQueued } }

    private func ids(where matches: (PlacementRecord) -> Bool) -> Set<ItemID> {
        Set(records.filter { matches($0.value) }.keys)
    }

    // MARK: Pending queue

    public mutating func queue(_ id: ItemID) { self[id].pending = true }
    public mutating func queue(_ ids: some Sequence<ItemID>) { for id in ids { queue(id) } }
    public mutating func dequeue(_ id: ItemID) { self[id].pending = false }

    /// Queue for a rescue; true when newly queued.
    public mutating func queueRescue(_ id: ItemID) -> Bool {
        let wasQueued = self[id].rescueQueued
        self[id].rescueQueued = true
        return !wasQueued
    }

    // MARK: Frameless

    /// True while a frameless item's slow-clock retry is still ahead.
    public func framelessRetryPending(_ id: ItemID, now: Date) -> Bool {
        self[id].framelessRetryAfter.map { $0 > now } ?? false
    }

    /// An attempt found no frame: remember the first such miss.
    public mutating func noteFrameless(_ id: ItemID, now: Date) {
        if self[id].framelessSince == nil { self[id].framelessSince = now }
    }

    /// An attempt found a frame.
    public mutating func noteFrame(_ id: ItemID) {
        self[id].framelessSince = nil
    }

    /// A flush attempt failed on a frameless item: schedule the slow retry
    /// and return how long it has been frameless, nil when it is not.
    public mutating func scheduleFramelessRetry(_ id: ItemID, now: Date) -> TimeInterval? {
        guard let since = self[id].framelessSince else { return nil }
        self[id].framelessRetryAfter = now.addingTimeInterval(Self.framelessRetryInterval)
        return now.timeIntervalSince(since)
    }

    /// A verified placement ends any rescue ping-pong and frameless wait.
    public mutating func notePlaced(_ id: ItemID) {
        self[id].rescueAttempts = 0
        self[id].framelessSince = nil
        self[id].framelessRetryAfter = nil
    }

    // MARK: Drift budget

    /// Anything not misplaced has earned its budget back.
    public mutating func resetDriftBudget(except misplaced: some Collection<ItemID>) {
        for id in trackedIDs where !misplaced.contains(id) {
            self[id].driftAttempts = 0
        }
    }

    public enum DriftVerdict: Equatable, Sendable {
        /// Queue a correction; the attempt number for the log.
        case correct(attempt: Int)
        /// Budget just spent: leave the item alone for `driftCoolOff`.
        case coolOff
        /// Still cooling off from an earlier spent budget.
        case skip
    }

    /// Spend one drift correction for a misplaced item.
    public mutating func spendDriftAttempt(_ id: ItemID, now: Date) -> DriftVerdict {
        if let until = self[id].driftCoolOffUntil, until > now { return .skip }
        self[id].driftCoolOffUntil = nil
        let attempts = self[id].driftAttempts + 1
        if attempts > Self.maxDriftAttempts {
            self[id].driftCoolOffUntil = now.addingTimeInterval(Self.driftCoolOff)
            self[id].driftAttempts = 0
            return .coolOff
        }
        self[id].driftAttempts = attempts
        return .correct(attempt: attempts)
    }

    // MARK: Rescue budget

    /// A rescue attempt failed: the attempt number and whether to requeue.
    public mutating func spendRescueAttempt(_ id: ItemID) -> (attempt: Int, requeue: Bool) {
        let attempts = self[id].rescueAttempts + 1
        if attempts < Self.maxRescueAttempts {
            self[id].rescueAttempts = attempts
            return (attempts, true)
        }
        self[id].rescueAttempts = 0
        return (attempts, false)
    }
}
