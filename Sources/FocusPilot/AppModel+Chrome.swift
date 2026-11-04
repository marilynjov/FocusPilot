import AppKit
import FocusPilotCore

/// What Settings says about setting up Chrome.
struct ChromeSetup: Equatable {
    /// The unpacked extension the owner loads once in chrome://extensions.
    var extensionFolder: URL
    /// Why the host or extension could not be installed, if they could not.
    var problem: String?
}

/// Chrome enforcement (#16): at launch, point Chrome's per-user host
/// manifest at the host in this bundle (repairing a stale path) and refresh
/// the extension folder; then follow each profile's acknowledgements.
extension AppModel {
    func setUpChrome(location: StorageLocation) {
        let bundle = Bundle.main.bundleURL
        let host = bundle.appending(path: "Contents/Helpers/focuspilot-chrome-host")
        let bundled = bundle.appending(path: "Contents/Resources/ChromeExtension")
        Task.detached { [weak self] in
            let setup = Self.install(location: location, host: host, bundled: bundled)
            await MainActor.run { self?.chromeSetup = setup }
        }
        chromeLocation = location
        // The policy Chrome may still hold from before this launch is no evidence.
        protectionEvidence = ProtectionEvidence(currentRevision: (try? ChromePolicyMailbox.read(location))?.policy.revision)
        followFrontBrowser()
        Task { [weak self] in
            while let self {
                refreshChromeProfiles(location: location)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refreshChromeProfiles(location: StorageLocation) {
        let source = (try? ChromePolicyMailbox.read(location))?.source
        let profiles = (try? ChromeProfiles.statuses(location: location, currentRevision: snapshot.policy?.revision,
                                                     currentSource: source)) ?? []
        if profiles != chromeProfiles { chromeProfiles = profiles }
        // Chrome showed its blocked page since the last look (D12).
        let blockedPages = profiles.reduce(0) { $0 + $1.blockedPagesShown }
        if let seen = chromeBlockedPagesSeen, blockedPages > seen { noteBlockedVisit() }
        chromeBlockedPagesSeen = blockedPages
        // Only on a change: every write redraws the status, and this runs every 5 s.
        var evidence = protectionEvidence
        evidence.update(profiles)
        if evidence != protectionEvidence { protectionEvidence = evidence }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: ChromeExtension.chromeBundleID).isEmpty
        if running != chromeRunning { chromeRunning = running }
    }

    /// Removes a disconnected profile from Settings, e.g. one deleted in Chrome.
    func forgetChromeProfile(_ profileID: String) {
        guard let location = chromeLocation else { return }
        try? ChromeProfiles.forget(profileID, location: location)
        refreshChromeProfiles(location: location)
    }

    nonisolated private static func install(location: StorageLocation, host: URL, bundled: URL) -> ChromeSetup {
        var setup = ChromeSetup(extensionFolder: location.chromeExtensionDirectory)
        // Run from the build folder without a bundle (swift run): nothing to install.
        guard FileManager.default.fileExists(atPath: host.path) else {
            setup.problem = "Chrome blocking needs FocusPilot.app (scripts/build-app.sh)."
            return setup
        }
        // Chrome and its Beta, Dev and Canary channels, each in its own folder;
        // one that fails does not keep the others or the extension from updating.
        let directories = ChromeInstaller.chromeManifestDirectories()
        guard !directories.isEmpty else {
            setup.problem = "Google Chrome isn't installed."
            return setup
        }
        setup.problem = ChromeInstaller.setUpEverywhere(manifestDirectories: directories, hostExecutable: host,
                                                        bundledExtension: bundled,
                                                        extensionDirectory: location.chromeExtensionDirectory).problem
        return setup
    }
}
