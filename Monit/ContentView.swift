import ServiceManagement
import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var settings

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Version \(version ?? "1.0")"
    }

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Open at login", isOn: $settings.launchAtLogin)
                    .font(.body.weight(.medium))

                Text("Starts Takt automatically after you sign in to macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let message = settings.launchAtLoginMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.orange)

                        if settings.launchAtLogin {
                            Button("Open Login Items") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Privacy")
                    .font(.body.weight(.medium))
                Text("Metrics are collected locally on this Mac. System and process data is not uploaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(versionText)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(width: 460, height: 240)
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
}
