//
//  SettingsAgentsPane.swift
//  Screendrop
//
//  Settings › Agents: the switch that lets coding agents use Sukusho through
//  its MCP helper, how to add it, who is connected, what each agent may do
//  without asking, and every call they made.
//

import AppKit
import SwiftUI

struct AgentsSettingsPane: View {
    @State private var access = AgentAccess.shared
    @State private var commandCopied = ActionFeedback()

    var body: some View {
        Form {
            Section {
                Toggle("Let agents use Sukusho", isOn: $access.isEnabled)
                if let error = access.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Coding agents such as Claude Code or Codex can add screenshots, share them, request files and read feedback. Sukusho asks you first, in its own window, before anything is shared, deleted or captured. Agents never get your Cloud token or Library files.")
            }

            if access.isEnabled {
                Section("Add Sukusho to an agent") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(access.addCommand)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(access.addCommand, forType: .string)
                            commandCopied.show()
                        } label: {
                            Image(systemName: commandCopied.isShowing ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(commandCopied.isShowing ? Color.green : .secondary)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                        .actionFeedback(commandCopied, label: "Copy Command")
                    }
                    Text("Other agents take the helper’s path as a local (stdio) MCP server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Connected now") {
                    if access.server.sessions.isEmpty {
                        Text("No agent is connected.").foregroundStyle(.secondary)
                    }
                    ForEach(access.server.sessions) { session in
                        AgentRow(agent: session.agent, detail: session.grants.isEmpty ? "Asks for everything"
                                    : "Allowed for this session: " + session.grants.map(\.title).sorted().joined(separator: ", "))
                    }
                }

                Section {
                    if access.grants.grants.isEmpty {
                        Text("No agent is always allowed anything.").foregroundStyle(.secondary)
                    }
                    ForEach(access.grants.grants) { grant in
                        HStack {
                            AgentRow(agent: grant.agent, detail: grant.groups.map(\.title).sorted().joined(separator: ", ")
                                        + " · since " + grant.granted.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Button("Revoke") { access.grants.revoke(grant.agent.key) }
                        }
                    }
                } header: {
                    Text("Always allowed")
                } footer: {
                    Text("“Always” covers only what that agent added or created. Sharing anything else from the Library still asks.")
                }

                Section {
                    if access.log.entries.isEmpty {
                        Text("No calls yet.").foregroundStyle(.secondary)
                    }
                    ForEach(access.log.entries.prefix(100)) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.time.formatted(date: .numeric, time: .shortened))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .leading)
                            Text(entry.agent).lineLimit(1)
                            Text(entry.tool).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(entry.result).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.callout)
                    }
                } header: {
                    HStack {
                        Text("Activity")
                        Spacer()
                        if !access.log.entries.isEmpty {
                            Button("Clear") { access.log.clear() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentRow: View {
    let agent: AgentIdentity
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(agent.displayName)
            Text(agent.signerName + " · " + detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
