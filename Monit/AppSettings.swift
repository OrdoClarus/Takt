import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {
    private enum StorageKey {
        static let modules = "monitorModules"
        static let presentation = "menuBarPresentation"
    }

    var modules: [MonitorModule] {
        didSet {
            saveModules()
        }
    }

    var menuBarPresentation: MenuBarPresentation {
        didSet {
            UserDefaults.standard.set(menuBarPresentation.rawValue, forKey: StorageKey.presentation)
        }
    }

    var launchAtLogin: Bool {
        didSet {
            updateLaunchAtLogin()
        }
    }

    private(set) var launchAtLoginMessage: String?
    private var isSynchronizingLaunchAtLogin = false

    init() {
        if let data = UserDefaults.standard.data(forKey: StorageKey.modules),
           let savedModules = try? JSONDecoder().decode([MonitorModule].self, from: data) {
            let savedIDs = Set(savedModules.map(\.id))
            let newModules = MonitorModule.defaults.filter { !savedIDs.contains($0.id) }
            modules = savedModules + newModules
        } else {
            modules = MonitorModule.defaults
        }

        let savedPresentation = UserDefaults.standard.string(forKey: StorageKey.presentation)
        menuBarPresentation = MenuBarPresentation(rawValue: savedPresentation ?? "") ?? .compact

        let loginService = SMAppService.mainApp
        launchAtLogin = loginService.status == .enabled || loginService.status == .requiresApproval
        launchAtLoginMessage = loginService.status == .requiresApproval
            ? "Allow this app in System Settings → General → Login Items."
            : nil
    }

    private func updateLaunchAtLogin() {
        guard !isSynchronizingLaunchAtLogin else {
            return
        }

        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginMessage = service.status == .requiresApproval
                ? "Allow this app in System Settings → General → Login Items."
                : nil
        } catch {
            launchAtLoginMessage = error.localizedDescription
            isSynchronizingLaunchAtLogin = true
            launchAtLogin = service.status == .enabled || service.status == .requiresApproval
            isSynchronizingLaunchAtLogin = false
        }
    }

    private func saveModules() {
        guard let data = try? JSONEncoder().encode(modules) else {
            return
        }

        UserDefaults.standard.set(data, forKey: StorageKey.modules)
    }
}

enum MenuBarPresentation: String, CaseIterable, Identifiable {
    case compact
    case detailed

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .compact:
            "Compact"
        case .detailed:
            "Detailed"
        }
    }
}

struct MonitorModule: Identifiable, Codable, Equatable {
    let id: ID
    var isEnabled: Bool

    var title: String {
        switch id {
        case .processor:
            "Processor"
        case .graphics:
            "Graphics"
        case .memory:
            "Memory"
        case .temperature:
            "Temperature"
        case .fans:
            "Fans"
        case .network:
            "Network"
        case .storage:
            "Storage"
        }
    }

    var subtitle: String {
        switch id {
        case .processor:
            "CPU and core load"
        case .graphics:
            "Integrated GPU load"
        case .memory:
            "Usage and memory pressure"
        case .temperature:
            "Apple Silicon sensors"
        case .fans:
            "Cooling speed and mode"
        case .network:
            "Incoming and outgoing traffic"
        case .storage:
            "Free space and activity"
        }
    }

    var systemImage: String {
        switch id {
        case .processor:
            "cpu"
        case .graphics:
            "display"
        case .memory:
            "memorychip"
        case .temperature:
            "thermometer.medium"
        case .fans:
            "fan"
        case .network:
            "network"
        case .storage:
            "internaldrive"
        }
    }

    enum ID: String, Codable {
        case processor
        case graphics
        case memory
        case temperature
        case fans
        case network
        case storage
    }

    static let defaults: [MonitorModule] = [
        MonitorModule(id: .processor, isEnabled: true),
        MonitorModule(id: .graphics, isEnabled: true),
        MonitorModule(id: .memory, isEnabled: true),
        MonitorModule(id: .temperature, isEnabled: true),
        MonitorModule(id: .fans, isEnabled: true),
        MonitorModule(id: .network, isEnabled: false),
        MonitorModule(id: .storage, isEnabled: false)
    ]
}
