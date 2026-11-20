// Activity view: the live recent-updates feed from Syncthing events plus the
// local operation history (both persisted, newest first, capped at 200).
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 6) {
            sectionLabel("Recent updates")
            if app.updates.isEmpty {
                Text("Updates appear here as folders sync and devices connect.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(app.updates.prefix(30)) { update in
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: update.kind))
                            .font(.system(size: 11))
                            .foregroundStyle(update.kind == "error" ? Color.red : Color.secondary)
                            .frame(width: 16)
                        Text(update.text)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(update.text)
                        Spacer(minLength: 4)
                        Text(Format.relative(update.time))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 30)
                }
            }
            Divider()
            sectionLabel("Activity")
            if app.activity.isEmpty {
                Text("Your activity will appear here when you connect or transfer a file.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(app.activity.prefix(50)) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(entry.success ? Color.green : Color.red)
                                .frame(width: 16)
                            Text(entry.operation)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Format.time(entry.time))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text("\(entry.connection)  ·  \(entry.success ? entry.detail : "Failed: \(entry.detail)")")
                            .font(.system(size: 10))
                            .foregroundStyle(entry.success ? Color.secondary : Color.red)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .padding(.leading, 22)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "file": return "doc.badge.arrow.up"
        case "device": return "desktopcomputer"
        case "folder": return "folder.badge.gearshape"
        case "error": return "exclamationmark.triangle"
        default: return "bolt"
        }
    }
}
