import XCTest
@testable import CustomCDPBrowser

final class CustomCDPBrowserTests: XCTestCase {
    func testInvalidLinkRoutingModeFallsBackToAskEveryTime() {
        XCTAssertEqual(LinkRoutingMode(storedValue: "unknown"), .askEveryTime)
        XCTAssertEqual(LinkRoutingMode(storedValue: nil), .askEveryTime)
    }

    func testVisibleProfilesContainExpectedProfilesInOrder() {
        XCTAssertEqual(
            CDPProfile.visibleProfiles.map(\.id),
            [
                "pessoal",
                "central-es",
                "central-rj",
                "financeiro-centralsp",
            ]
        )
    }

    func testPessoalIsDefaultProfile() {
        XCTAssertEqual(CDPProfile.defaultProfile.id, "pessoal")
        XCTAssertEqual(CDPProfile.visibleProfiles.first?.id, "pessoal")
    }

    func testProfileLookupFallsBackToPessoalForInvalidID() {
        XCTAssertEqual(CDPProfile.profile(withID: "central-rj").id, "central-rj")
        XCTAssertEqual(CDPProfile.profile(withID: "missing").id, "pessoal")
        XCTAssertEqual(CDPProfile.profile(withID: nil).id, "pessoal")
    }

    func testLegacyUnifiedProfileIDsResolveToFinanceiroCentralSP() {
        XCTAssertEqual(CDPProfile.profile(withID: "central-sp").id, "financeiro-centralsp")
        XCTAssertEqual(CDPProfile.profile(withID: "financeiro-rossoni").id, "financeiro-centralsp")
    }

    func testProfilesUseDownloadsAsManualDownloadDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        for profile in CDPProfile.visibleProfiles {
            XCTAssertEqual(profile.expandedDownloadDirectory, "\(home)/Downloads")
            XCTAssertTrue(profile.preferencesPath.hasSuffix("/\(profile.profileDirectory)/Preferences"))
        }
    }

    @MainActor
    func testDownloadPreferencesPreserveExistingKeys() {
        let updatedPreferences = CDPProfileLauncher.preferencesWithDownloadDirectory(
            [
                "existing": "value",
                "download": [
                    "default_directory": "/tmp/old",
                    "some_other_key": "kept",
                ],
                "savefile": [
                    "default_directory": "/tmp/old-save",
                    "another_key": "kept",
                ],
            ],
            downloadDirectory: "/Users/gabrielalonso/Downloads"
        )

        let download = updatedPreferences["download"] as? [String: Any]
        let savefile = updatedPreferences["savefile"] as? [String: Any]

        XCTAssertEqual(updatedPreferences["existing"] as? String, "value")
        XCTAssertEqual(download?["default_directory"] as? String, "/Users/gabrielalonso/Downloads")
        XCTAssertEqual(download?["directory_upgrade"] as? Bool, true)
        XCTAssertEqual(download?["prompt_for_download"] as? Bool, false)
        XCTAssertEqual(download?["some_other_key"] as? String, "kept")
        XCTAssertEqual(savefile?["default_directory"] as? String, "/Users/gabrielalonso/Downloads")
        XCTAssertEqual(savefile?["another_key"] as? String, "kept")
    }

    @MainActor
    func testNewTabEndpointPreservesQueryAndFragment() {
        let url = URL(string: "https://example.com/path?q=one%20two&next=/x#section")!
        let endpoint = CDPProfileLauncher.newTabEndpoint(for: url, port: 9224)
        let encodedURL = endpoint.absoluteString.split(separator: "?", maxSplits: 1).last.map(String.init)

        XCTAssertEqual(endpoint.scheme, "http")
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(endpoint.port, 9224)
        XCTAssertEqual(endpoint.path, "/json/new")
        XCTAssertEqual(encodedURL?.removingPercentEncoding, url.absoluteString)
    }

    @MainActor
    func testStartupURLUsesInitialURLBeforeProfileDefault() {
        let profile = CDPProfile.profile(withID: "financeiro-centralsp")
        let initialURL = URL(string: "https://example.com/received-link")!

        XCTAssertEqual(
            CDPProfileLauncher.startupURL(for: profile, initialURL: initialURL),
            initialURL
        )
    }

    @MainActor
    func testStartupURLFallsBackToProfileDefault() {
        let profile = CDPProfile.profile(withID: "financeiro-centralsp")

        XCTAssertEqual(
            CDPProfileLauncher.startupURL(for: profile, initialURL: nil)?.absoluteString,
            "https://web.whatsapp.com/"
        )
    }

    func testLsofProcessIDParsingDeduplicatesInStableOrder() {
        XCTAssertEqual(
            CDPProcessInspector.uniqueProcessIDs(from: "123\n456\n123\n\n789\n"),
            ["123", "456", "789"]
        )
    }

    func testMCPCommandFilterRequiresPlaywrightMCPAndMatchingEndpointPort() {
        XCTAssertTrue(
            CDPProcessInspector.isPlaywrightMCPCommand(
                "node /usr/local/bin/playwright-mcp --cdp-endpoint http://127.0.0.1:9224",
                for: 9224
            )
        )
        XCTAssertTrue(
            CDPProcessInspector.isPlaywrightMCPCommand(
                "node /usr/local/bin/playwright-mcp --cdp-endpoint=http://127.0.0.1:9224",
                for: 9224
            )
        )
        XCTAssertTrue(
            CDPProcessInspector.isPlaywrightMCPCommand(
                "node /usr/local/bin/playwright-mcp --cdp-endpoint http://localhost:9224",
                for: 9224
            )
        )
        XCTAssertFalse(
            CDPProcessInspector.isPlaywrightMCPCommand(
                "node /usr/local/bin/playwright-mcp --cdp-endpoint http://127.0.0.1:9223",
                for: 9224
            )
        )
        XCTAssertFalse(
            CDPProcessInspector.isPlaywrightMCPCommand(
                "node /tmp/server.js --cdp-endpoint http://127.0.0.1:9224",
                for: 9224
            )
        )
        XCTAssertFalse(
            CDPProcessInspector.isPlaywrightMCPCommand(
                "/Applications/Helium.app/Contents/MacOS/Helium --remote-debugging-port=9224",
                for: 9224
            )
        )
    }

    func testMCPProcessCommandFilterIncludesNPMRunnerForMemoryAccounting() {
        XCTAssertTrue(
            CDPProcessInspector.isPlaywrightMCPProcessCommand(
                "npm exec @playwright/mcp@latest --cdp-endpoint http://127.0.0.1:9224",
                for: 9224
            )
        )
        XCTAssertTrue(
            CDPProcessInspector.isPlaywrightMCPProcessCommand(
                "node /usr/local/bin/playwright-mcp --cdp-endpoint http://127.0.0.1:9224",
                for: 9224
            )
        )
        XCTAssertFalse(
            CDPProcessInspector.isPlaywrightMCPProcessCommand(
                "npm exec @playwright/mcp@latest --cdp-endpoint http://127.0.0.1:9223",
                for: 9224
            )
        )
    }

    func testMCPClientsAreFilteredAndSortedByProcessID() {
        let clients = CDPProcessInspector.clients(
            from: [
                "456": "node playwright-mcp --cdp-endpoint http://127.0.0.1:9223",
                "123": "node playwright-mcp --cdp-endpoint http://127.0.0.1:9224",
                "789": "node other.js --cdp-endpoint http://127.0.0.1:9224",
                "234": "node /opt/bin/playwright-mcp --cdp-endpoint=http://127.0.0.1:9224",
            ],
            port: 9224
        )

        XCTAssertEqual(clients.map(\.processID), ["123", "234"])
    }

    func testMCPClientsPreserveResidentMemoryFromProcessSnapshots() {
        let clients = CDPProcessInspector.clients(
            from: [
                CDPProcessInspector.ProcessSnapshot(
                    processID: "456",
                    parentProcessID: "100",
                    residentMemoryKilobytes: 2048,
                    command: "node playwright-mcp --cdp-endpoint http://127.0.0.1:9223"
                ),
                CDPProcessInspector.ProcessSnapshot(
                    processID: "123",
                    parentProcessID: "100",
                    residentMemoryKilobytes: 8192,
                    command: "node playwright-mcp --cdp-endpoint http://127.0.0.1:9224"
                ),
            ],
            port: 9224
        )

        XCTAssertEqual(clients, [
            CDPAttachedClient(
                processID: "123",
                command: "node playwright-mcp --cdp-endpoint http://127.0.0.1:9224",
                residentMemoryKilobytes: 8192
            )
        ])
    }

    func testMCPResidentMemoryIncludesRunnerAndClientProcesses() {
        let memory = CDPProcessInspector.mcpResidentMemoryKilobytes(
            from: [
                CDPProcessInspector.ProcessSnapshot(
                    processID: "100",
                    parentProcessID: "1",
                    residentMemoryKilobytes: 11024,
                    command: "npm exec @playwright/mcp@latest --cdp-endpoint http://127.0.0.1:9224"
                ),
                CDPProcessInspector.ProcessSnapshot(
                    processID: "101",
                    parentProcessID: "100",
                    residentMemoryKilobytes: 8192,
                    command: "node playwright-mcp --cdp-endpoint http://127.0.0.1:9224"
                ),
                CDPProcessInspector.ProcessSnapshot(
                    processID: "102",
                    parentProcessID: "200",
                    residentMemoryKilobytes: 4096,
                    command: "node playwright-mcp --cdp-endpoint http://127.0.0.1:9223"
                ),
            ],
            ports: [9224]
        )

        XCTAssertEqual(memory, 19216)
    }

    func testMCPProcessesIncludePortAndParentProcessID() {
        let processes = CDPProcessInspector.mcpProcesses(
            from: [
                CDPProcessInspector.ProcessSnapshot(
                    processID: "100",
                    parentProcessID: "1",
                    residentMemoryKilobytes: 11024,
                    command: "npm exec @playwright/mcp@latest --cdp-endpoint http://127.0.0.1:9224"
                ),
                CDPProcessInspector.ProcessSnapshot(
                    processID: "101",
                    parentProcessID: "100",
                    residentMemoryKilobytes: 8192,
                    command: "node playwright-mcp --cdp-endpoint http://127.0.0.1:9224"
                ),
            ],
            ports: [9224]
        )

        XCTAssertEqual(processes.map(\.processID), ["100", "101"])
        XCTAssertEqual(processes.map(\.parentProcessID), ["1", "100"])
        XCTAssertEqual(processes.map(\.port), [9224, 9224])
    }

    func testIdleMCPProcessesExcludeConnectedClientAndParentRunner() {
        let processes = [
            CDPProcessInspector.MCPProcess(
                processID: "100",
                parentProcessID: "1",
                port: 9224,
                residentMemoryKilobytes: 11024,
                command: "npm exec @playwright/mcp@latest --cdp-endpoint http://127.0.0.1:9224"
            ),
            CDPProcessInspector.MCPProcess(
                processID: "101",
                parentProcessID: "100",
                port: 9224,
                residentMemoryKilobytes: 8192,
                command: "node playwright-mcp --cdp-endpoint http://127.0.0.1:9224"
            ),
            CDPProcessInspector.MCPProcess(
                processID: "200",
                parentProcessID: "1",
                port: 9225,
                residentMemoryKilobytes: 11024,
                command: "npm exec @playwright/mcp@latest --cdp-endpoint http://127.0.0.1:9225"
            ),
        ]

        let idleProcesses = CDPProcessInspector.idleMCPProcesses(
            from: processes,
            listeningPorts: [9224, 9225],
            establishedProcessIDsByPort: [9224: ["101"]]
        )

        XCTAssertEqual(idleProcesses.map(\.processID), ["200"])
    }

    func testIdleMCPProcessesIncludeProcessesForClosedPorts() {
        let processes = [
            CDPProcessInspector.MCPProcess(
                processID: "100",
                parentProcessID: "1",
                port: 9226,
                residentMemoryKilobytes: 11024,
                command: "npm exec @playwright/mcp@latest --cdp-endpoint http://127.0.0.1:9226"
            )
        ]

        let idleProcesses = CDPProcessInspector.idleMCPProcesses(
            from: processes,
            listeningPorts: [],
            establishedProcessIDsByPort: [:]
        )

        XCTAssertEqual(idleProcesses.map(\.processID), ["100"])
    }

    func testProcessListParsingPreservesCommandsWithSpaces() {
        let commands = CDPProcessInspector.processCommands(
            from: """
              123 node /tmp/playwright-mcp --cdp-endpoint http://127.0.0.1:9224
              456 /Applications/Helium.app/Contents/MacOS/Helium --remote-debugging-port=9224

            """
        )

        XCTAssertEqual(
            commands["123"],
            "node /tmp/playwright-mcp --cdp-endpoint http://127.0.0.1:9224"
        )
        XCTAssertEqual(
            commands["456"],
            "/Applications/Helium.app/Contents/MacOS/Helium --remote-debugging-port=9224"
        )
    }

    func testProcessSnapshotParsingPreservesRSSAndCommandsWithSpaces() {
        let snapshots = CDPProcessInspector.processSnapshots(
            from: """
              123 1 8192 node /tmp/playwright-mcp --cdp-endpoint http://127.0.0.1:9224
              456 1 2048 /Applications/Helium.app/Contents/MacOS/Helium --remote-debugging-port=9224

            """
        )

        XCTAssertEqual(snapshots, [
            CDPProcessInspector.ProcessSnapshot(
                processID: "123",
                parentProcessID: "1",
                residentMemoryKilobytes: 8192,
                command: "node /tmp/playwright-mcp --cdp-endpoint http://127.0.0.1:9224"
            ),
            CDPProcessInspector.ProcessSnapshot(
                processID: "456",
                parentProcessID: "1",
                residentMemoryKilobytes: 2048,
                command: "/Applications/Helium.app/Contents/MacOS/Helium --remote-debugging-port=9224"
            ),
        ])
    }

    func testProcessInspectorBuildsSafeSystemToolArguments() {
        XCTAssertEqual(
            CDPProcessInspector.processListArguments(),
            ["-axo", "pid=,ppid=,rss=,command="]
        )
        XCTAssertEqual(
            CDPProcessInspector.establishedLsofArguments(for: 9224),
            ["-nP", "-tiTCP:9224", "-sTCP:ESTABLISHED"]
        )
    }

    @MainActor
    func testRoutingDecisionUsesConfiguredMode() {
        XCTAssertEqual(
            LinkRouter.routingDecision(mode: .askEveryTime, lastSelectedProfileID: "central-rj"),
            .ask
        )
        XCTAssertEqual(
            LinkRouter.routingDecision(mode: .personal, lastSelectedProfileID: "central-rj"),
            .route(CDPProfile.defaultProfile)
        )
        XCTAssertEqual(
            LinkRouter.routingDecision(mode: .lastSelected, lastSelectedProfileID: "central-rj"),
            .route(CDPProfile.profile(withID: "central-rj"))
        )
        XCTAssertEqual(
            LinkRouter.routingDecision(mode: .lastSelected, lastSelectedProfileID: "missing"),
            .route(CDPProfile.defaultProfile)
        )
    }

    @MainActor
    func testAskEveryTimeEnqueuesIncomingURL() {
        let defaults = UserDefaults(suiteName: "CustomCDPBrowserTests-\(UUID().uuidString)")!
        defaults.set(LinkRoutingMode.askEveryTime.rawValue, forKey: UserDefaultsKeys.linkRoutingMode)

        let router = LinkRouter(userDefaults: defaults)
        let url = URL(string: "https://example.com/a?b=c#d")!

        router.handleIncomingURL(url)

        XCTAssertEqual(router.pendingURLs, [url])
    }
}
