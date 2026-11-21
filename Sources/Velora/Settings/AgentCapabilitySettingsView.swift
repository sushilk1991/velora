import SwiftUI

struct AgentCapabilitySettingsView: View {
    let enabled: Bool
    @State private var revision = 0

    var body: some View {
        SettingsDisclosureRow(title: "Local-agent permissions") {
            VStack(alignment: .leading, spacing: VeloraSpacing.m) {
                ForEach(AgentCapability.allCases) { capability in
                    HStack(alignment: .center, spacing: VeloraSpacing.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capability.title)
                                .font(.system(size: 13))
                            Text(capability.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Toggle(capability.title, isOn: Binding(
                            get: { _ = revision; return AgentAccessPolicy.shared.allows(capability) },
                            set: { AgentAccessPolicy.shared.setAllowed($0, for: capability); revision += 1 }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .onReceive(NotificationCenter.default.publisher(for: .veloraAgentCapabilitiesChanged)) { _ in revision += 1 }
    }
}
