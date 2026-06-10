import SwiftUI

private enum PanelTheme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.97, green: 0.95, blue: 0.92),
            Color(red: 0.95, green: 0.93, blue: 0.90)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let card = Color.white.opacity(0.68)
    static let border = Color.black.opacity(0.06)
    static let shadow = Color.black.opacity(0.08)
    static let accent = Color(red: 0.77, green: 0.42, blue: 0.21)
    static let success = Color(red: 0.37, green: 0.53, blue: 0.42)
    static let textPrimary = Color(red: 0.12, green: 0.11, blue: 0.10)
    static let textMuted = Color.black.opacity(0.55)
    static let badgePersonal = Color(red: 0.01, green: 0.32, blue: 0.88)
    static let badgeClinic = Color(red: 0.12, green: 0.53, blue: 0.63)
    static let badgeFinance = Color(red: 0.82, green: 0.38, blue: 0.18)
    static let cardRadius: CGFloat = 12
    static let panelRadius: CGFloat = 14
}

struct ProfilePickerView: View {
    let onDismiss: () -> Void

    @StateObject private var launcher = CDPProfileLauncher.shared
    @StateObject private var linkRouter = LinkRouter.shared
    @State private var openingProfileID: String?
    @State private var closingProfileID: String?
    @State private var disconnectingMCPProfileID: String?
    @State private var expandedProfileID: String?
    @State private var feedback: String?
    @AppStorage(UserDefaultsKeys.lastSelectedProfileID) private var lastSelectedProfileID = CDPProfile.defaultProfile.id

    private var hasPendingLinks: Bool {
        !linkRouter.pendingURLs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

        ScrollView {
            VStack(spacing: 10) {
                ForEach(CDPProfile.visibleProfiles) { profile in
                    ProfileRow(
                        profile: profile,
                        isRunning: launcher.runningProfileIDs.contains(profile.id),
                        mcpClientCount: launcher.mcpClientsByProfileID[profile.id]?.count ?? 0,
                        isOpening: openingProfileID == profile.id,
                        isClosing: closingProfileID == profile.id,
                        isDisconnectingMCP: disconnectingMCPProfileID == profile.id,
                        allowsRunningSelection: hasPendingLinks,
                        isExpanded: expandedProfileID == profile.id
                    ) {
                        select(profile)
                    } onToggleDetails: {
                        toggleDetails(for: profile)
                    } onDisconnectMCP: {
                        disconnectMCPClients(for: profile)
                    } onClose: {
                        close(profile)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .padding(.trailing, 4)
        }
        .scrollIndicators(.hidden)

            footer
        }
        .frame(width: 420, height: 470)
        .background(
            PanelTheme.background
                .overlay(
                    RoundedRectangle(cornerRadius: PanelTheme.panelRadius)
                        .fill(.ultraThinMaterial)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.panelRadius))
        .shadow(color: PanelTheme.shadow, radius: 18, x: 0, y: 12)
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
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: hasPendingLinks ? "link" : "globe.europe.africa.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PanelTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hasPendingLinks ? "Abrir link" : "Custom CDP Browser")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(PanelTheme.textPrimary)

                    if hasPendingLinks {
                        Text(pendingLinkSummary)
                            .font(.caption)
                            .foregroundStyle(PanelTheme.textMuted)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Text("ESC para fechar")
                    .font(.caption)
                    .foregroundStyle(PanelTheme.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let visibleFeedback = feedback ?? linkRouter.feedback {
                Text(visibleFeedback)
                    .font(.caption)
                    .foregroundStyle(PanelTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                launcher.refreshStatuses()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
                    .foregroundStyle(PanelTheme.textMuted)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(PanelTheme.border.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .help("Atualizar status do CDP")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(PanelTheme.textMuted)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(PanelTheme.border.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var pendingLinkSummary: String {
        guard let firstURL = linkRouter.pendingURLs.first else {
            return ""
        }

        let prefix = linkRouter.pendingURLs.count > 1 ? "\(linkRouter.pendingURLs.count) links · " : ""
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

    private func toggleDetails(for profile: CDPProfile) {
        withAnimation(.easeOut(duration: 0.16)) {
            expandedProfileID = expandedProfileID == profile.id ? nil : profile.id
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
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggleDetails: () -> Void
    let onDisconnectMCP: () -> Void
    let onClose: () -> Void

    private var canSelect: Bool {
        (!isRunning || allowsRunningSelection) && !isOpening && !isClosing && !isDisconnectingMCP
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    guard canSelect else { return }
                    onSelect()
                } label: {
                    HStack(spacing: 12) {
                        badge

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(profile.name) · porta \(profile.port)")
                                .font(.body.weight(isRunning ? .semibold : .regular))
                                .foregroundStyle(PanelTheme.textPrimary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSelect)

                Spacer(minLength: 8)

                if isOpening || isClosing || isDisconnectingMCP {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    HStack(spacing: 8) {
                        if mcpClientCount > 0 {
                            Button(action: onDisconnectMCP) {
                                Image(systemName: "bolt.slash")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(PanelTheme.accent)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        Circle()
                                            .fill(PanelTheme.accent.opacity(0.12))
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Liberar upload desconectando MCP clients de \(profile.name)")
                        }

                        if isRunning {
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(PanelTheme.textMuted)
                                    .frame(width: 26, height: 26)
                                    .background(
                                        Circle()
                                            .fill(PanelTheme.border.opacity(0.9))
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Close \(profile.name)")
                        }

                        Button(action: onToggleDetails) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PanelTheme.textPrimary)
                                .frame(width: 26, height: 26)
                                .background(
                                    Circle()
                                        .fill(PanelTheme.border.opacity(0.9))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isExpanded ? "Ocultar detalhes" : "Mostrar detalhes")
                    }
                }
            }

            if isExpanded {
                ProfileDetails(
                    profile: profile,
                    isRunning: isRunning,
                    mcpClientCount: mcpClientCount
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PanelTheme.cardRadius)
                .fill(PanelTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: PanelTheme.cardRadius)
                        .strokeBorder(
                            isRunning ? PanelTheme.success.opacity(0.5) : PanelTheme.border,
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: PanelTheme.shadow.opacity(isExpanded ? 0.18 : 0.1), radius: isExpanded ? 12 : 8, x: 0, y: 6)
        .animation(.easeOut(duration: 0.15), value: isExpanded)
    }

    private var badge: some View {
        Text(profile.badgeText)
            .font(.system(size: profile.badgeText.count > 1 ? 13 : 16, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(iconForeground)
            )
    }

    private var iconForeground: Color {
        switch profile.kind {
        case .personal:
            PanelTheme.badgePersonal
        case .clinic:
            PanelTheme.badgeClinic
        case .finance:
            PanelTheme.badgeFinance
        }
    }
}

private struct ProfileDetails: View {
    let profile: CDPProfile
    let isRunning: Bool
    let mcpClientCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow(icon: "globe", label: "Default", value: profile.defaultURL ?? "Sem URL padrão")
            detailRow(icon: "app.badge", label: "App", value: profile.browserAppName)
            detailRow(
                icon: "bolt.horizontal",
                label: "MCP",
                value: mcpClientCount > 0 ? "\(mcpClientCount) ativo\(mcpClientCount == 1 ? "" : "s")" : "Sem MCP ativos"
            )
            detailRow(
                icon: "power",
                label: "Status",
                value: isRunning ? "Rodando" : "Disponível"
            )
        }
        .font(.caption)
        .foregroundStyle(PanelTheme.textMuted)
        .padding(.leading, 2)
        .padding(.top, 2)
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PanelTheme.textMuted)
                .frame(width: 16)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PanelTheme.textPrimary)
            Text("·")
                .foregroundStyle(PanelTheme.textMuted)
            Text(value)
                .lineLimit(1)
        }
    }
}
