import SwiftUI
import PassthroughUI
import PassthroughCore

@main
struct PassthroughMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = SessionCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(session)
                .environmentObject(session.vpnLayer)
                .environmentObject(session.keepAwake)
                .environmentObject(session.shell)
        } label: {
            MenuBarLabel(session: session, vpnLayer: session.vpnLayer, keepAwake: session.keepAwake, shell: session.shell)
        }
        .menuBarExtraStyle(.window)

        Window("Passthrough Wireless Setup", id: "wireless-setup") {
            WirelessSetupView().environmentObject(session)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(session)
                .environmentObject(session.vpnLayer)
                .environmentObject(session.keepAwake)
                .environmentObject(session.shell)
        }

        Window("Shell History", id: ShellHistoryWindow.id) {
            ShellHistoryWindow()
                .environmentObject(session.shell)
        }

        WindowGroup("Screen", id: RemoteScreenWindow.id, for: String.self) { $macID in
            if let macID {
                RemoteScreenWindow(macID: macID)
                    .environmentObject(session.shell)
            }
        }
        .defaultSize(width: 1280, height: 820)

        Window("Welcome to Passthrough", id: WelcomeView.id) {
            WelcomeView()
                .environmentObject(session)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar icon (`MenuBarIcon`). Observes everything it shows so any change redraws it.
private struct MenuBarLabel: View {
    @ObservedObject var session: SessionCoordinator
    @ObservedObject var vpnLayer: VPNLayer
    @ObservedObject var keepAwake: KeepAwakeController
    @ObservedObject var shell: RemoteShellController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon.task {
            if CommandLine.arguments.contains("--wireless-enrollment-output") {
                openWindow(id: "wireless-setup")
                return
            }
            // First run on a Mac never set up: what should the phone do for it?
            guard !SessionCoordinator.isSnapshotRun, WelcomeView.shouldShow(session) else { return }
            openWindow(id: WelcomeView.id)
            NSApp.activate()
        }
    }

    private var icon: some View {
        Image(nsImage: MenuBarIcon.image(MenuBarIcon.State(
            online: session.phase.isConnected,
            phone: session.device != nil,
            awake: keepAwake.isOn,
            vpn: vpnLayer.status.isConnected,
            screen: !shell.screenViewers.isEmpty,
            needsYou: !shell.phonesAsking.isEmpty,
            problem: vpnLayer.isWanted && vpnLayer.status.isFailing)))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--wireless-enrollment-output") ? .regular : .accessory)
        Self.raiseFileDescriptorLimit()
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            let dir = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PanelSnapshots.render(to: dir)
                // Nothing to tear down in a snapshot run; `terminate` from this
                // main-queue block would wait on a reply queued behind it.
                exit(0)
            }
        }
    }

    private var quitObserver: NSObjectProtocol?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Let the coordinator tear the tunnel down and turn the VPN off (else
        // the helper keeps its kill switch blocking, as after a crash): quit
        // once it says it is done, or after 4 s regardless.
        var replied = false
        let reply = { [weak self] in
            guard !replied else { return }
            replied = true
            if let observer = self?.quitObserver { NotificationCenter.default.removeObserver(observer) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        quitObserver = NotificationCenter.default.addObserver(forName: .passthroughReadyToQuit, object: nil, queue: .main) { _ in reply() }
        NotificationCenter.default.post(name: .passthroughWillTerminate, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { reply() }
        return .terminateLater
    }
}

extension AppDelegate {
    /// Every proxied flow costs two descriptors (loopback + usbmuxd); the GUI
    /// default of 256 is exhausted by a single busy browser tab.
    static func raiseFileDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = rlim_t(OPEN_MAX)
        limit.rlim_cur = min(wanted, limit.rlim_max)
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            limit.rlim_cur = 4096
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
        getrlimit(RLIMIT_NOFILE, &limit)
        PassthroughLog.shared.log(.info, "File descriptor limit: \(limit.rlim_cur)")
    }
}

extension Notification.Name {
    static let passthroughWillTerminate = Notification.Name("\(PassthroughProtocol.identifier).willTerminate")
    /// The coordinator finished tearing down for a quit.
    static let passthroughReadyToQuit = Notification.Name("\(PassthroughProtocol.identifier).readyToQuit")
}

/// A normal background-operable window for the one-time wireless setup.
private struct WirelessSetupView: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Wireless setup").font(.title2.bold())
            Text(session.wirelessEnrollmentStatus).textSelection(.enabled)
            Text(session.device.map { "Phone reachable: \($0.label)" } ?? "Waiting for the phone to start sharing.")
            Text("Internet: \(String(describing: session.phase))").font(.callout)
            if let note = session.helperNote { Text(note).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Register networking helper") {
                    session.disconnect()
                    session.retryHelper()
                }
                Button("Login Items settings") { session.openLoginItems() }
            }
            HStack {
                Button(session.phase.isConnected ? "Disconnect" : "Connect") { session.toggle() }
                    .disabled(session.device == nil || session.phase.isBusy)
                if session.phase.isConnected { Text("Connected").foregroundStyle(.green) }
            }
            Text("Keep Personal Hotspot enabled. The iPhone app uses its VPN extension for background sharing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 480)
    }
}
