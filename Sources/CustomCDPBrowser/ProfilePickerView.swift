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
        Button {
            guard !isRunning else { return }
            onSelect()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Text(profile.badgeText)
                        .font(.system(size: profile.badgeText.count > 1 ? 13 : 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(iconForeground)
                }
                .frame(width: 34, height: 34)

                Text("\(profile.name) - porta \(profile.port)")
                    .font(.body.weight(isRunning ? .semibold : .regular))
                    .foregroundStyle(.primary)

                Spacer()

                if isOpening {
                    ProgressView()
                        .controlSize(.small)
                } else if isRunning {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.green)

                        Text("Aberto")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.16))
                    )
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
        }
        .buttonStyle(.plain)
        .disabled(isOpening)
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
