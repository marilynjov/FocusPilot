import Foundation
import GRDB
import Testing
@testable import FocusPilotCore

@Suite("Rule storage")
struct RuleStorageTests {
    private let location: StorageLocation
    private let repository: TaskRepository

    init() throws {
        location = StorageLocation(directory: try makeTemporaryDirectory())
        repository = try TaskRepository(location: location)
    }

    @Test func seededAllowedToolsArePresent() async throws {
        let allowed = try await repository.policyInputs().allowed

        #expect(allowed.map(\.name) == ["Finder", "Terminal", "System Settings", "Overleaf", "Herdr"])
        #expect(allowed.allSatisfy { $0.source == .seeded })
        #expect(allowed.map(\.target).contains(.site(domain: "overleaf.com")))
        #expect(allowed.map(\.target).contains(.app(bundleID: "com.apple.finder", name: "Finder")))
    }

    @Test func savingARuleSetGetsAnIDAndANewPolicyRevision() async throws {
        let change = try await repository.save(BlockRuleSet(targets: [.site(domain: "instagram.com")], activation: .always))

        #expect(change.revision == 1)
        let saved = try #require(change.inputs.rules.first)
        #expect(saved.id != nil)
        #expect(saved.revision == 1)
        #expect(try await repository.policyInputs().rules == [saved])
    }

    @Test func editingARuleSetBumpsBothRevisions() async throws {
        var rule = try await repository.save(BlockRuleSet(targets: [.site(domain: "tiktok.com")], activation: .always)).inputs.rules[0]
        rule.activation = .schedule(WeeklySchedule(days: [.mon], from: ClockTime(8, 0), to: ClockTime(18, 0), timeZone: bogota))

        let change = try await repository.save(rule)

        #expect(change.revision == 2)
        #expect(change.inputs.rules == [BlockRuleSet(id: rule.id, targets: rule.targets, activation: rule.activation, revision: 2)])
    }

    // Review of PR #39: an edit made from an older copy of the rule must not
    // silently undo the changes saved since.
    @Test func savingFromAnOlderCopyIsRefusedAndNothingChanges() async throws {
        let first = try #require(try await repository.save(BlockRuleSet(targets: [.site(domain: "youtube.com")], activation: .always)).inputs.rules.first)
        var newer = first
        newer.targets.append(.site(domain: "x.com"))
        try await repository.save(newer)
        var stale = first
        stale.activation = .sessionOnly

        await #expect(throws: RuleError.ruleChanged) { try await repository.save(stale) }
        #expect(try await repository.policyInputs().rules.first?.targets.count == 2)
    }

    @Test func deletingAnOlderRevisionIsRefused() async throws {
        let first = try #require(try await repository.save(BlockRuleSet(targets: [.site(domain: "youtube.com")], activation: .always)).inputs.rules.first)
        var newer = first
        newer.targets.append(.site(domain: "x.com"))
        try await repository.save(newer)

        await #expect(throws: RuleError.ruleChanged) { try await repository.deleteRuleSet(first.id!, revision: first.revision) }
        #expect(try await repository.policyInputs().rules.count == 1)
        await #expect(throws: RuleError.ruleChanged) { try await repository.save(first) }
        try await repository.deleteRuleSet(first.id!, revision: 2)
        await #expect(throws: RuleError.ruleChanged) { try await repository.save(newer) }
    }

    @Test func rulesSurviveRelaunch() async throws {
        let schedule = WeeklySchedule(days: [.sat, .sun], from: ClockTime(22, 0), to: ClockTime(2, 0), timeZone: newYork)
        let saved = try await repository.save(BlockRuleSet(targets: [.site(domain: "reddit.com"), .app(bundleID: "com.valve.steam", name: "Steam")],
                                                           activation: .schedule(schedule))).inputs.rules

        #expect(try await TaskRepository(location: location).policyInputs().rules == saved)
    }

    @Test func deletingARuleSetPublishesANewRevision() async throws {
        let id = try await repository.save(BlockRuleSet(targets: [.site(domain: "x.com")], activation: .always)).inputs.rules[0].id!

        let change = try await repository.deleteRuleSet(id)

        #expect(change.revision == 2)
        #expect(change.inputs.rules.isEmpty)
    }

    @Test func emptyOrInvalidRuleSetsAreRefused() async throws {
        await #expect(throws: RuleError.noTargets) {
            try await repository.save(BlockRuleSet(targets: [], activation: .always))
        }
        await #expect(throws: RuleError.invalidSchedule) {
            try await repository.save(BlockRuleSet(targets: [.site(domain: "x.com")],
                                                   activation: .schedule(WeeklySchedule(days: [], from: ClockTime(8, 0), to: ClockTime(9, 0), timeZone: bogota))))
        }
        await #expect(throws: RuleError.notBlockable(.tool(command: "herdr"))) {
            try await repository.save(BlockRuleSet(targets: [.tool(command: "herdr")], activation: .always))
        }
    }

    // Review of PR #39: the core validates, since the CLI and AI proposals
    // will save rules without the Settings editor.
    @Test func savedSitesAreNormalizedAndDeduplicated() async throws {
        let change = try await repository.save(BlockRuleSet(
            targets: [.site(domain: "https://www.YouTube.com/watch?v=1"), .site(domain: "youtube.com"), .site(domain: "münchen.de")],
            activation: .always))

        #expect(change.inputs.rules[0].targets == [.site(domain: "youtube.com"), .site(domain: "xn--mnchen-3ya.de")])
    }

    @Test func unusableTargetsAreRefusedInTheCore() async throws {
        await #expect(throws: RuleError.invalidSite("not a site")) {
            try await repository.save(BlockRuleSet(targets: [.site(domain: "not a site")], activation: .always))
        }
        await #expect(throws: RuleError.invalidApp) {
            try await repository.save(BlockRuleSet(targets: [.app(bundleID: "  ", name: "Nothing")], activation: .always))
        }
        await #expect(throws: RuleError.invalidSite("nope")) {
            try await repository.allow(AllowedActivity(name: "Nope", target: .site(domain: "nope")))
        }
        #expect(try await repository.policyInputs().rules.isEmpty)
    }

    @Test func allowedSitesAreNormalizedAndNamed() async throws {
        let change = try await repository.allow(AllowedActivity(name: "  ", target: .site(domain: "https://Scholar.Google.com/scholar?q=x")))

        #expect(change.inputs.allowed.last?.target == .site(domain: "scholar.google.com"))
        #expect(change.inputs.allowed.last?.name == "scholar.google.com")
    }

    @Test func blockingAnAllowedSiteIsRefusedAndNothingChanges() async throws {
        await #expect(throws: RuleError.alreadyAllowed(.site(domain: "overleaf.com"))) {
            try await repository.save(BlockRuleSet(targets: [.site(domain: "overleaf.com")], activation: .always))
        }
        #expect(try await repository.policyInputs().rules.isEmpty)
        #expect(try await repository.save(BlockRuleSet(targets: [.site(domain: "x.com")], activation: .always)).revision == 1)
    }

    @Test func seededToolsCanBeRemovedAndOwnerEntriesAdded() async throws {
        let finder = try #require(try await repository.policyInputs().allowed.first { $0.name == "Finder" })

        let removed = try await repository.removeAllowed(finder.id!)
        let added = try await repository.allow(AllowedActivity(name: "Zotero", target: .app(bundleID: "org.zotero.zotero", name: "Zotero")))

        #expect(!removed.inputs.allowed.contains { $0.name == "Finder" })
        #expect(added.inputs.allowed.last?.name == "Zotero")
        #expect(added.inputs.allowed.last?.source == .owner)
        #expect(added.revision == removed.revision + 1)
    }

    @Test func allowingTwiceOrAllowingABlockedSiteIsRefused() async throws {
        _ = try await repository.save(BlockRuleSet(targets: [.site(domain: "instagram.com")], activation: .sessionOnly))

        await #expect(throws: RuleError.alreadyBlocked(.site(domain: "instagram.com"))) {
            try await repository.allow(AllowedActivity(name: "Instagram", target: .site(domain: "instagram.com")))
        }
        await #expect(throws: RuleError.alreadyAllowed(.site(domain: "overleaf.com"))) {
            try await repository.allow(AllowedActivity(name: "Overleaf again", target: .site(domain: "overleaf.com")))
        }
    }

    @Test func ruleEditsShareTheRevisionCounterWithSessions() async throws {
        _ = try await repository.addTask(title: "Write the essay")
        let session = FocusSession.sample(phase: .running)
        _ = try await repository.record(FocusTransition(session: session, effects: [.persist(session), .publishPolicy(nil)]))

        #expect(try await repository.save(BlockRuleSet(targets: [.site(domain: "x.com")], activation: .always)).revision == 2)
    }
}
