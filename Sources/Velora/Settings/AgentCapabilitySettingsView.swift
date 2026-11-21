import SwiftUI

struct AgentCapabilitySettingsView: View {
    let enabled: Bool
    @State private var revision = 0
    var body: some View {
        DisclosureGroup("Local-agent permissions") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AgentCapability.allCases) { capability in
                    HStack(alignment: .center, spacing: VeloraSpacing.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capability.title).font(.system(size: 12.5))
                            Text(capability.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { _ = revision; return AgentAccessPolicy.shared.allows(capability) },
                            set: { AgentAccessPolicy.shared.setAllowed($0, for: capability); revision += 1 }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 8)
            .disabled(!enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onReceive(NotificationCenter.default.publisher(for: .veloraAgentCapabilitiesChanged)) { _ in revision += 1 }
    }
}
