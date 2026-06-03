import SwiftUI

struct ProfilePickerView: View {
    let onDismiss: () -> Void

    @StateObject private var launcher = CDPProfileLauncher.shared
    @State private var openingProfileID: String?
    @State private var feedback: String?

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
                            isOpening: openingProfileID == profile.id
                        ) {
                            open(profile)
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
            onDismiss()
            return .handled
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "network")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Custom CDP Browser")
                .font(.headline)

            Spacer()

            Text("ESC to close")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if let feedback {
                Text(feedback)
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
}

struct ProfileRow: View {
    let profile: CDPProfile
    let isRunning: Bool
    let isOpening: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconBackground)
                        .frame(width: 34, height: 34)

                    Text(profile.badgeText)
                        .font(.system(size: profile.badgeText.count > 1 ? 13 : 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(iconForeground)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(profile.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isOpening {
                    ProgressView()
                        .controlSize(.small)
                } else if isRunning {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isRunning ? Color.green.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOpening || isRunning)
    }

    private var iconBackground: Color {
        switch profile.kind {
        case .personal:
            Color.blue.opacity(0.18)
        case .clinic:
            Color.teal.opacity(0.18)
        case .finance:
            Color.orange.opacity(0.18)
        }
    }

    private var iconForeground: Color {
        switch profile.kind {
        case .personal:
            .blue
        case .clinic:
            .teal
        case .finance:
            .orange
        }
    }
}
