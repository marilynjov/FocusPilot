import Foundation
import GRDB

extension TaskRepository {
    /// Records what an engine transition asks to keep: the session, if it
    /// changed, and a new policy revision for each publish, all in one
    /// write, with the rule inputs those policies are compiled from. With
    /// `cancellingExceptionsAt`, exceptions granted up to then are cancelled
    /// in the same write (a strict session starting). A plan block's
    /// `planChange` goes in the same write too.
    @discardableResult
    public func record(_ transition: FocusTransition, cancellingExceptionsAt cancel: Date? = nil,
                       planChange: PlanRunChange? = nil) async throws -> RecordedTransition {
        let now = now()
        return try await ownerDatabase.write { db in
            if let cancel { try Self.cancelExceptions(grantedBy: cancel, db) }
            var revisions: [Int] = []
            for effect in transition.effects {
                switch effect {
                case .persist(let session):
                    // A new session never joins one still active: the
                    // coordinator serializes steps, and this keeps two
                    // starts from both being stored as running regardless.
                    if try !SessionRow.exists(db, key: session.id.uuidString),
                       let latest = try SessionRow.order(Column.rowID.desc).fetchOne(db)?.session(), !latest.hasEnded {
                        throw FocusEngineError.sessionAlreadyActive
                    }
                    try SessionRow(session).save(db)
                case .publishPolicy:
                    revisions.append(try Self.nextPolicyRevision(db))
                case .notify:
                    break
                }
            }
            if let planChange { try Self.apply(planChange, db) }
            return RecordedTransition(revisions: revisions, inputs: try Self.policyInputs(db, at: now))
        }
    }

    /// The most recently started session, which may have ended. Ordered by
    /// insertion, not `startedAt`, so a clock set back cannot hide it.
    public func latestSession() async throws -> FocusSession? {
        try await ownerDatabase.read { db in
            try SessionRow.order(Column.rowID.desc).fetchOne(db)?.session()
        }
    }
}

/// The revisions handed out for a transition's publishes, in order, and the
/// rule inputs read in the same write.
public struct RecordedTransition: Sendable {
    public var revisions: [Int]
    public var inputs: PolicyInputs
}
