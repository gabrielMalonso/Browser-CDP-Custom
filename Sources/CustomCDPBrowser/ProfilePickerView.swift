import SwiftUI

struct ProfilePickerView: View {
    let onDismiss: () -> Void

    @StateObject private var launcher = CDPProfileLauncher.shared
    @State private var openingProfileID: String?
    @State private var closingProfileID: String?
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
                            isOpening: openingProfileID == profile.id,
                            isClosing: closingProfileID == profile.id
                        ) {
                            open(profile)
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
}

struct ProfileRow: View {
    let profile: CDPProfile
    let isRunning: Bool
    let isOpening: Bool
    let isClosing: Bool
    let onSelect: () -> Void
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

            Text("\(profile.name) - porta \(profile.port)")
                .font(.body.weight(isRunning ? .semibold : .regular))
                .foregroundStyle(.primary)

            Spacer()

            if isOpening || isClosing {
                ProgressView()
                    .controlSize(.small)
            } else if isRunning {
                HStack(spacing: 8) {
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
            guard !isRunning, !isOpening, !isClosing else { return }
            onSelect()
        }
        .disabled(isOpening || isClosing)
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
