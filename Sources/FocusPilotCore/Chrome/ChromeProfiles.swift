import Foundation

/// One Chrome profile's protection, as the app reports it.
public struct ChromeProfileStatus: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        /// Applied the current policy.
        case acknowledged(revision: Int)
        /// Connected, applied an older one; the newer one is on its way.
        case syncing(acknowledged: Int)
        /// Connected, nothing applied yet.
        case waiting
        /// No host is running for the profile, e.g. Chrome is closed.
        case disconnected(lastSeen: Date?)
    }

    public var profileID: String
    public var state: State
    public var incognitoAllowed: Bool
    public var allSitesAccess: Bool
    public var missingObservations: Int
    /// Times Chrome showed FocusPilot's blocked page in this profile; the
    /// raccoon cheers when it grows (D12).
    public var blockedPagesShown = 0
    public var id: String { profileID }

    public static func text(_ state: State) -> String {
        switch state {
        case .acknowledged: "Chrome has your latest rules"
        case .syncing: "Chrome is updating…"
        case .waiting: "Connected · getting your rules…"
        case .disconnected: "Disconnected"
        }
    }
}

public enum ChromeProfiles {
    public enum ForgetError: Error, Equatable {
        /// The profile's host still runs; it would write the record again.
        case connected
    }

    /// Each profile against the current revision and the source that issued
    /// it. `isRunning` checks whether a host process still exists, since a
    /// crashed host cannot say it stopped.
    public static func statuses(location: StorageLocation, currentRevision: Int?, currentSource: String? = nil,
                                isRunning: (Int32) -> Bool = processExists) throws -> [ChromeProfileStatus] {
        ChromeProfileStore(location: location).records()
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .map { record in
                ChromeProfileStatus(profileID: record.profileID,
                                    state: state(record, currentRevision, currentSource, isRunning),
                                    incognitoAllowed: record.incognitoAllowed, allSitesAccess: record.allSitesAccess,
                                    missingObservations: record.missingObservations,
                                    blockedPagesShown: record.blockedPagesShown)
            }
    }

    /// Settings drops a profile the owner no longer uses, e.g. one deleted
    /// in Chrome. It comes back if that profile connects again.
    public static func forget(_ profileID: String, location: StorageLocation,
                              isRunning: (Int32) -> Bool = processExists) throws {
        let store = ChromeProfileStore(location: location)
        if let pid = (try? store.record(profileID))?.hostProcessID, isRunning(pid) { throw ForgetError.connected }
        try store.remove(profileID)
    }

    private static func state(_ record: ChromeProfileRecord, _ current: Int?, _ source: String?,
                              _ isRunning: (Int32) -> Bool) -> ChromeProfileStatus.State {
        guard let pid = record.hostProcessID, isRunning(pid) else { return .disconnected(lastSeen: record.lastSeenAt) }
        guard let applied = record.appliedRevision, source == nil || record.appliedSource == source else { return .waiting }
        if let current, applied < current { return .syncing(acknowledged: applied) }
        return .acknowledged(revision: applied)
    }

    public static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
