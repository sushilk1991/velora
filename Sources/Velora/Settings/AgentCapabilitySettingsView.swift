import SwiftUI

struct AgentCapabilitySettingsView: View {
    let enabled: Bool
    @State private var revision = 0
    var body: some View {
        DisclosureGroup("Local-agent permissions") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AgentCapability.allCases) { capability in
                    Toggle(isOn: Binding(
                        get: { _ = revision; return AgentAccessPolicy.shared.allows(capability) },
                        set: { AgentAccessPolicy.shared.setAllowed($0, for: capability); revision += 1 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capability.title)
                            Text(capability.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(.top, 8).disabled(!enabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: .veloraAgentCapabilitiesChanged)) { _ in revision += 1 }
    }
}
