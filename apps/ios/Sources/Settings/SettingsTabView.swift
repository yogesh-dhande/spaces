import SwiftUI
import spacesterminalcore

enum SpacesMobileSettingsRoute: Hashable {
    case pairedDevices
    case daemon
}

/// Settings tab: connection, appearance, and version in the shared band language.
struct SettingsTabView: View {
    @Bindable var model: SpacesMobileAppModel
    @State private var path: [SpacesMobileSettingsRoute] = []
    @AppStorage(AppAppearanceStorage.key) private var appearanceMode: AppAppearanceMode = .default

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    settingsGroup("Connection") {
                        navigationRow(
                            label: "Paired Devices", identifier: "settings.pairedDevices",
                            destination: .pairedDevices
                        ) {
                            Text("\(model.pairedDevices.count)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.mutedSecondary)
                                .monospacedDigit()
                        }
                        navigationRow(label: "Daemon", identifier: "settings.daemon", destination: .daemon) {
                            daemonStatusValue
                        }
                    }
                    settingsGroup("Appearance") {
                        themeRow
                    }
                    settingsGroup("About") {
                        versionRow
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .tint(Theme.accent)
            .navigationDestination(for: SpacesMobileSettingsRoute.self) { route in
                switch route {
                case .pairedDevices:
                    PairedDevicesView(model: model)
                case .daemon:
                    DaemonSettingsView(model: model)
                }
            }
        }
        .accessibilityIdentifier("tab.settings")
        .task {
            presentPairedDevicesIfRequested(model.isShowingConnectionSettings)
        }
        .onChange(of: model.isShowingConnectionSettings) { _, isShowing in
            presentPairedDevicesIfRequested(isShowing)
        }
        .onChange(of: path) { _, newPath in
            guard !newPath.contains(.pairedDevices), model.isShowingConnectionSettings else { return }
            model.isShowingConnectionSettings = false
            model.clearPendingPairingLink()
        }
    }

    /// Pairing links and auth recovery raise `isShowingConnectionSettings`; the root tab view
    /// switches to this tab and this pushes the Paired Devices screen.
    private func presentPairedDevicesIfRequested(_ isShowing: Bool) {
        guard isShowing, !path.contains(.pairedDevices) else { return }
        path.append(.pairedDevices)
    }

    private func settingsGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HeaderBand {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                content()
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 14)
    }

    private func navigationRow(
        label: String,
        identifier: String,
        destination: SpacesMobileSettingsRoute,
        @ViewBuilder value: () -> some View
    ) -> some View {
        Button {
            path.append(destination)
        } label: {
            HStack(spacing: 10) {
                settingsLabel(label)
                Spacer(minLength: 0)
                value()
                RowChevron()
            }
            .settingsRowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var daemonStatusValue: some View {
        HStack(spacing: 6) {
            StatusDot(kind: daemonStatusDotKind)
            Text(daemonStatusLabel)
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedSecondary)
        }
    }

    private var daemonStatusDotKind: StatusDot.Kind {
        if model.isActiveDeviceBlocked || model.daemonUpdatePending { return .waiting }
        if model.compatibility == .compatible { return .done }
        return .idle
    }

    private var daemonStatusLabel: String {
        switch model.compatibility {
        case .clientTooOld: "App update required"
        case .daemonTooOld: "Restart required"
        case .compatible: model.daemonUpdatePending ? "Update pending" : "Compatible"
        case nil: "Unknown"
        }
    }

    private var themeRow: some View {
        HStack(spacing: 10) {
            settingsLabel("Theme")
            Spacer(minLength: 0)
            Picker("Theme", selection: $appearanceMode) {
                ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Theme.mutedSecondary)
        }
        .settingsRowPadding()
        .accessibilityIdentifier("settings.theme")
    }

    private var versionRow: some View {
        HStack(spacing: 10) {
            settingsLabel("Version")
            Spacer(minLength: 0)
            Text(versionString)
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedSecondary)
                .monospacedDigit()
        }
        .settingsRowPadding()
        .accessibilityIdentifier("settings.version")
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    private func settingsLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
    }
}

extension View {
    fileprivate func settingsRowPadding() -> some View {
        padding(.vertical, 10)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pushes the existing devices content with the model's connection plumbing.
struct PairedDevicesView: View {
    let model: SpacesMobileAppModel

    var body: some View {
        ConnectionSettingsView(
            initialSettings: model.settings,
            initialPairingLink: model.pendingPairingLink,
            pairedDevices: model.pairedDevices,
            activeDeviceID: model.activeDeviceID,
            noticeMessage: model.connectionNotice,
            onPairingLinkConsumed: { model.clearPendingPairingLink() },
            onSelectDevice: { deviceID in
                model.selectDevice(id: deviceID)
                Task { await model.refresh() }
            },
            onRemoveDevice: { deviceID in
                model.removeDevice(id: deviceID)
            },
            onRenameDevice: { deviceID, name in
                model.renameDevice(id: deviceID, name: name)
            }
        ) { settings, deviceName in
            model.applyConnectionSettings(settings, deviceName: deviceName)
            Task { await model.refresh() }
        }
    }
}
