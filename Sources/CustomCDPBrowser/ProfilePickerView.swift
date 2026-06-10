import SwiftUI

struct ProfilePickerView: View {
    let onDismiss: () -> Void

    @StateObject private var launcher = CDPProfileLauncher.shared
    @StateObject private var linkRouter = LinkRouter.shared
    @State private var openingProfileID: String?
    @State private var closingProfileID: String?
    @State private var disconnectingMCPProfileID: String?
    @State private var feedback: String?
    @AppStorage(UserDefaultsKeys.lastSelectedProfileID) private var lastSelectedProfileID = CDPProfile.defaultProfile.id

    private var hasPendingLinks: Bool {
        !linkRouter.pendingURLs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(CDPProfile.visibleProfiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isRunning: launcher.runningProfileIDs.contains(profile.id),
                            mcpClientCount: launcher.mcpClientsByProfileID[profile.id]?.count ?? 0,
                            isOpening: openingProfileID == profile.id,
                            isClosing: closingProfileID == profile.id,
                            isDisconnectingMCP: disconnectingMCPProfileID == profile.id,
                            allowsRunningSelection: hasPendingLinks
                        ) {
                            select(profile)
                        } onDisconnectMCP: {
                            disconnectMCPClients(for: profile)
                        } onClose: {
                            close(profile)
                        }
                    }
                }
                .padding(8)
            }

            Divider()

            footer
        }
        .frame(width: 380, height: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            launcher.refreshStatuses()
        }
        .onKeyPress(.escape) {
            if hasPendingLinks {
                linkRouter.cancelPendingURLs()
            }
            onDismiss()
            return .handled
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: hasPendingLinks ? "link" : "network")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(hasPendingLinks ? "Open Link" : "Custom CDP Browser")
                    .font(.headline)

                if hasPendingLinks {
                    Text(pendingLinkSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("ESC to close")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if let visibleFeedback = feedback ?? linkRouter.feedback {
                Text(visibleFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                launcher.refreshStatuses()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh CDP status")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var pendingLinkSummary: String {
        guard let firstURL = linkRouter.pendingURLs.first else {
            return ""
        }

        let prefix = linkRouter.pendingURLs.count > 1 ? "\(linkRouter.pendingURLs.count) links - " : ""
        return prefix + (firstURL.host ?? firstURL.absoluteString)
    }

    private func select(_ profile: CDPProfile) {
        lastSelectedProfileID = profile.id

        if hasPendingLinks {
            routePendingLinks(to: profile)
        } else {
            open(profile)
        }
    }

    private func open(_ profile: CDPProfile) {
        openingProfileID = profile.id
        feedback = "Opening \(profile.name)..."

        launcher.open(profile) { result in
            openingProfileID = nil

            switch result {
            case .success:
                feedback = "\(profile.name) is ready on port \(profile.port)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    onDismiss()
                }
            case .failure(let error):
                feedback = error.localizedDescription
            }
        }
    }

    private func routePendingLinks(to profile: CDPProfile) {
        openingProfileID = profile.id
        feedback = "Opening link in \(profile.name)..."

        linkRouter.routePendingURLs(to: profile) { result in
            openingProfileID = nil

            switch result {
            case .success:
                feedback = "Opened in \(profile.name)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    onDismiss()
                }
            case .failure(let error):
                feedback = error.localizedDescription
            }
        }
    }

    private func close(_ profile: CDPProfile) {
        closingProfileID = profile.id
        feedback = "Closing \(profile.name)..."

        launcher.close(profile) { result in
            closingProfileID = nil

            switch result {
            case .success:
                feedback = "\(profile.name) closed"
            case .failure(let error):
                feedback = error.localizedDescription
            }
        }
    }

    private func disconnectMCPClients(for profile: CDPProfile) {
        disconnectingMCPProfileID = profile.id
        feedback = "Disconnecting MCP clients from \(profile.name)..."

        launcher.disconnectMCPClients(for: profile) { result in
            disconnectingMCPProfileID = nil

            switch result {
            case .success(let disconnectedCount):
                if disconnectedCount == 0 {
                    feedback = "No MCP clients connected to \(profile.name)"
                } else {
                    feedback = "Disconnected \(disconnectedCount) MCP client\(disconnectedCount == 1 ? "" : "s") from \(profile.name)"
                }
            case .failure(let error):
                feedback = error.localizedDescription
            }
        }
    }
}

struct ProfileRow: View {
    let profile: CDPProfile
    let isRunning: Bool
    let mcpClientCount: Int
    let isOpening: Bool
    let isClosing: Bool
    let isDisconnectingMCP: Bool
    let allowsRunningSelection: Bool
    let onSelect: () -> Void
    let onDisconnectMCP: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Text(profile.badgeText)
                    .font(.system(size: profile.badgeText.count > 1 ? 13 : 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(iconForeground)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(profile.name) - porta \(profile.port)")
                    .font(.body.weight(isRunning ? .semibold : .regular))
                    .foregroundStyle(.primary)

                if mcpClientCount > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.caption)
                            .symbolRenderingMode(.hierarchical)

                        Text("\(mcpClientCount) MCP ativo\(mcpClientCount == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.16)))
                }
            }

            Spacer()

            if isOpening || isClosing || isDisconnectingMCP {
                ProgressView()
                    .controlSize(.small)
            } else if isRunning {
                HStack(spacing: 8) {
                    if mcpClientCount > 0 {
                        Button(action: onDisconnectMCP) {
                            Label("Liberar", systemImage: "bolt.slash.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.orange.opacity(0.34), lineWidth: 1)
                        )
                        .help("Liberar upload desconectando MCP clients de \(profile.name)")
                    }

                    ZStack {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.green)
                    }
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.green.opacity(0.16)))

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .help("Close \(profile.name)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isRunning ? Color.white.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isRunning ? Color.green.opacity(0.7) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard (!isRunning || allowsRunningSelection), !isOpening, !isClosing, !isDisconnectingMCP else { return }
            onSelect()
        }
        .disabled(isOpening || isClosing || isDisconnectingMCP)
    }

    private var iconForeground: Color {
        switch profile.kind {
        case .personal:
            Color(red: 0.0, green: 0.36, blue: 1.0)
        case .clinic:
            Color(red: 0.0, green: 0.62, blue: 0.72)
        case .finance:
            Color(red: 0.98, green: 0.42, blue: 0.0)
        }
    }
}
