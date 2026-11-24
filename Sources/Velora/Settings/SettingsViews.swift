import SwiftUI

/// The ⌘, Settings window's rail, System Settings-style: five coloured-tile
/// rows, in this order. Everything that is content rather than preference
/// (History, Stats, Meetings, Dictionary, Modes) lives in the main window's
/// `MainPane`; About is its own small window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, dictation, shortcuts, models, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.text("General")
        case .dictation: return L10n.text("Dictation")
        case .shortcuts: return L10n.text("Shortcuts")
        case .models: return L10n.text("Models")
        case .advanced: return L10n.text("Advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dictation: return "mic.fill"
        case .shortcuts: return "keyboard.fill"
        case .models: return "cpu.fill"
        case .advanced: return "gearshape.2.fill"
        }
    }

    /// Sidebar icon tile color — deliberate, System Settings-style palette
    /// (one hue per section, not per row).
    var tileColor: Color {
        switch self {
        case .general: return .gray
        case .dictation: return .red
        case .shortcuts: return .blue
        case .models: return .purple
        case .advanced: return Color(nsColor: .darkGray)
        }
    }
}

/// Bundle identity shared by the sidebar header and the About pane — one
/// source for the marketing version, build number, and the real app icon.
enum VeloraAppInfo {
    static var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.1.0"
    }

    static var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// The real bundled app icon — never an SF Symbol stand-in (a bare
    /// `swift build` binary falls back to the generic app icon).
    static var icon: NSImage {
        if let bundled = Bundle.main.image(forResource: "AppIcon") { return bundled }
        return NSApp.applicationIconImage ?? NSImage()
    }
}

// MARK: - Shared form pieces

/// Grouped-form section footer in the System Settings idiom: caption-sized,
/// secondary. Every footer goes through this so panes can't drift apart again
/// (they used to mix `.callout` and `.caption` and read as two designs).
/// Leading-aligned: a grouped Form trails its footers by default, which put
/// the header on the left and the footer on the right of every card.
struct SettingsFooter: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(L10n.text(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small capsule marking a feature that ships behind lowered expectations —
/// it works, it is tested, and it is still earning trust.
struct ExperimentalBadge: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    var body: some View {
        Text(L10n.text("EXPERIMENTAL"))
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(VeloraStatus.warningText)
            .background(
                Capsule().fill(VeloraStatus.warning.opacity(0.15))
            )
            .accessibilityLabel(L10n.text("Experimental feature"))
    }
}

/// The bordered search field used by list-style panes (History, Dictionary) —
/// one look for in-pane search everywhere.
struct SettingsSearchBox: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    let prompt: String
    @Binding var query: String
    var accessibilityLabel: String?

    var body: some View {
        HStack(spacing: VeloraSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n.text(prompt), text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel(L10n.text(accessibilityLabel ?? prompt))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Clear search"))
            }
        }
        .padding(.horizontal, VeloraSpacing.s)
        .padding(.vertical, 6)
        // Card, not textBackgroundColor: the semantic color drops to #1E1E1E
        // in dark mode and reads as a hole in the canvas.
        .background(RoundedRectangle(cornerRadius: VeloraRadius.tile).fill(VeloraPanel.card))
        .overlay(RoundedRectangle(cornerRadius: VeloraRadius.tile).strokeBorder(Color(.separatorColor)))
    }
}


// MARK: - General

/// General: appearance, the pill, and every update setting — the settings a
/// first-day user reaches for. Everything operational moved to Advanced.
struct GeneralSettingsView: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @ObservedObject var model: SettingsModel
    @State private var previewSounds = SoundPlayer()

    var body: some View {
        SettingsScrollCanvas {
            SettingsColumnPair {
                appearanceCard
                soundsCard
            } right: {
                updatesCard
                pillCard
            }
        }
    }

    private var appearanceCard: some View {
        GroupCard(header: L10n.text("Appearance")) {
            GroupRow(label: L10n.text("Theme")) {
                Picker(L10n.text("Appearance"), selection: $model.appearance) {
                    Text(L10n.text("System")).tag("system")
                    Text(L10n.text("Light")).tag("light")
                    Text(L10n.text("Dark")).tag("dark")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            GroupDivider()
            GroupRow(
                label: L10n.text("Interface language"),
                sub: L10n.text("Changes menus and settings. Dictation language is set separately.")
            ) {
                CapsuleOptionMenu(
                    L10n.text("Interface language"),
                    value: model.interfaceLanguage.title,
                    selection: $model.interfaceLanguage,
                    items: InterfaceLanguage.allCases.map { CapsuleMenuItem($0, title: $0.title) }
                )
            }
            GroupDivider()
            SettingsToggleRow(
                title: "Launch Velora at login",
                subtitle: "Start quietly in the menu bar when you sign in.",
                isOn: $model.launchAtLogin)
        }
    }

    private var pillCard: some View {
        GroupCard(
            header: L10n.text("Dictation pill"),
            footer: "You can also hide it from its right-click menu."
        ) {
            GroupRow(label: L10n.text("Show pill")) {
                CapsuleOptionMenu(
                    L10n.text("Show pill"),
                    value: L10n.text(pillVisibility.wrappedValue.title),
                    selection: pillVisibility,
                    items: PillVisibility.allCases.map { CapsuleMenuItem($0, title: L10n.text($0.title)) }
                )
            }
            GroupDivider()
            GroupRow(
                label: L10n.text("Recording view"),
                sub: L10n.text("Live Card shows your current line while speaking. Dictate & Send always uses the Live Card.")
            ) {
                Picker(L10n.text("Recording view"), selection: $model.showLiveWords) {
                    Text(L10n.text("Compact Pill")).tag(false)
                    Text(L10n.text("Live Card")).tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            GroupDivider()
            SettingsDisclosureRow(title: "Preview the pill") {
                HUDPreviewView(model: model)
            }
        }
    }

    private var soundsCard: some View {
        GroupCard(header: L10n.text("Sound and feedback")) {
            SettingsToggleRow(
                title: "Play sounds",
                subtitle: "Subtle cues for recording start, release, completion, and errors.",
                isOn: $model.soundsEnabled)
            if model.soundsEnabled {
                GroupDivider()
                GroupRow(label: L10n.text("Sound set")) {
                    CapsuleOptionMenu(
                        L10n.text("Sound set"),
                        value: model.soundSet.title,
                        selection: $model.soundSet,
                        items: SoundSet.allCases.map { CapsuleMenuItem($0, title: $0.title) }
                    )
                }
                GroupDivider()
                GroupRow(label: L10n.text("Sound volume")) {
                    HStack(spacing: VeloraSpacing.s) {
                        Slider(value: $model.soundVolume, in: 0...100)
                            .frame(width: 140)
                            .accessibilityLabel(L10n.text("Sound volume"))
                        Text("\(Int(model.soundVolume.rounded()))%")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                GroupDivider()
                VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                    Text(L10n.text("Preview cues"))
                        .font(.system(size: 13))
                    HStack(spacing: VeloraSpacing.xs) {
                        Button(L10n.text("Start")) { previewSounds.play(.start, preview: true) }
                        Button(L10n.text("Release")) { previewSounds.play(.preStop, preview: true) }
                        Button(L10n.text("Stop")) { previewSounds.play(.stop, preview: true) }
                        Button(L10n.text("No speech")) { previewSounds.play(.noResult, preview: true) }
                        Button(L10n.text("Error")) { previewSounds.play(.error, preview: true) }
                    }
                    .buttonStyle(.capsule)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, VeloraSpacing.m)
            }
        }
    }

    private var updatesCard: some View {
        GroupCard(
            header: L10n.text("Updates"),
            footer: "Checks GitHub once a day and sends nothing about you or what you dictate. Before installing an update, Velora checks Apple's signature and notarization."
        ) {
            GroupRow(
                label: L10n.format("Version %@", VeloraAppInfo.shortVersion),
                sub: model.updateCheckStatus
            ) {
                UpdateActionRow(model: model, checkStatusPlacement: .caller)
                    .buttonStyle(.capsule)
            }
            GroupDivider()
            SettingsToggleRow(
                title: "Check for updates automatically",
                isOn: $model.updateChecks)
            GroupDivider()
            SettingsToggleRow(
                title: "Download and install updates automatically",
                isOn: $model.autoInstallUpdates,
                disabled: !model.updateChecks)
            GroupDivider()
            GroupRow(label: L10n.text("Release notes")) {
                Button(L10n.text("View Release History…")) { model.openReleaseHistory() }
                    .buttonStyle(.capsule)
            }
        }
    }

    /// The one pill picker over `hud.visible` + `hud.alwaysVisible`.
    private var pillVisibility: Binding<PillVisibility> {
        Binding(
            get: {
                PillVisibility(visible: model.hudVisible, alwaysVisible: model.hudAlwaysVisible)
            },
            set: { choice in
                model.hudAlwaysVisible = choice.alwaysVisible(keeping: model.hudAlwaysVisible)
                model.hudVisible = choice.visible
            })
    }
}

/// Update controls mirroring the updater's state with the shared
/// `UpdateCopy` vocabulary: check → download progress → verify → restart.
/// Failures show the reason and keep both Try Again and Check Now within
/// reach. Shared by Settings › General › Updates and the About window.
struct UpdateActionRow: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    /// Where the last check's result ("This is the latest version.") shows.
    enum CheckStatusPlacement {
        /// Beside the buttons (About).
        case inline
        /// The caller shows it, under Settings' "Version X" label.
        case caller
    }

    @ObservedObject var model: SettingsModel
    /// The idle-state button title ("Check Now" in the Updates section,
    /// "Check for Updates" in About).
    var checkLabel = "Check Now"
    var checkStatusPlacement: CheckStatusPlacement = .inline

    private static let progressWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: VeloraSpacing.m) {
            switch model.updateState {
            case .downloading(_, let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: Self.progressWidth)
                caption(stateCaption)
                Button(L10n.text("Cancel")) { model.cancelUpdateDownload() }
            case .verifying, .installing:
                ProgressView().controlSize(.small)
                caption(stateCaption)
            case .ready:
                Button(model.updateInstallsWhenReady
                       ? UpdateCopy.waitingTitle : UpdateCopy.restartTitle) {
                    model.installStagedUpdate()
                }
                .disabled(model.updateInstallsWhenReady)
                if model.availableUpdate != nil {
                    Button(L10n.text("Release Notes…")) { model.showUpdateWindow() }
                }
                caption(stateCaption)
            case .failed:
                if model.canInstallUpdateInPlace {
                    Button(UpdateCopy.tryAgainTitle) { model.showUpdateWindow() }
                } else {
                    Button(UpdateCopy.releasesPageTitle) { model.openReleasesPage() }
                }
                Button(checkLabel) { model.checkForUpdatesNow() }
                caption(stateCaption)
                caption(checkStatus)
            case .idle:
                // One button: the update once one is known, else Check Now.
                if let update = model.availableUpdate {
                    if model.canInstallUpdateInPlace {
                        Button(UpdateCopy.updateTitle(update.version)) {
                            model.showUpdateWindow()
                        }
                    } else {
                        Button(UpdateCopy.releasesPageTitle) { model.openReleasesPage() }
                    }
                } else {
                    Button(checkLabel) { model.checkForUpdatesNow() }
                }
                caption(checkStatus)
            }
        }
    }

    private var checkStatus: String? {
        checkStatusPlacement == .inline ? model.updateCheckStatus : nil
    }

    private var stateCaption: String? {
        UpdateCopy.caption(
            for: model.updateState, installsWhenReady: model.updateInstallsWhenReady,
            waitingFor: model.updateWaitingFor)
    }

    @ViewBuilder
    private func caption(_ text: String?) -> some View {
        if let text {
            Text(L10n.text(text))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Dictation

/// Dictation: input (mic, language, how the shortcut behaves), writing
/// behaviour, and recordings. Terminal cleanup moved to Advanced › Terminals.
struct DictationSettingsView: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @ObservedObject var model: SettingsModel
    @State private var archiveSize: String = "…"
    @State private var inputDevices: [AudioInputDevices.Device] = []
    @State private var screenRecordingGranted = Permissions.screenRecordingGranted
    @State private var requestedScreenRecording = false

    /// Whisper language codes, weighted toward the most-spoken languages.
    private static let languages: [(String, String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("hi", "Hindi"),
        ("es", "Spanish"), ("zh", "Mandarin Chinese"), ("ar", "Arabic"),
        ("fr", "French"), ("pt", "Portuguese"), ("de", "German"),
        ("it", "Italian"), ("ja", "Japanese"),
    ]

    var body: some View {
        SettingsScrollCanvas {
            SettingsColumnPair {
                inputCard
                KeyboardRoutingSettingsView(model: model)
                deliveryCard
            } right: {
                writingCard
                screenContextCard
                recordingsCard
            }
        }
        .task(id: model.saveAudio) { archiveSize = await Self.archiveSizeDescription() }
        .onAppear {
            AudioInputDevices.beginObserving()
            inputDevices = AudioInputDevices.displayList()
            screenRecordingGranted = Permissions.screenRecordingGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: .veloraAudioInputDevicesChanged)) { _ in
            inputDevices = AudioInputDevices.displayList()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenRecordingGranted = Permissions.screenRecordingGranted
            if screenRecordingGranted {
                requestedScreenRecording = false
            }
        }
    }

    private var selectedMicrophoneName: String {
        guard let uid = model.inputDeviceUID else { return L10n.text("System Default") }
        return inputDevices.first(where: { $0.uid == uid })?.name
            ?? L10n.text("Chosen Microphone (Not Connected)")
    }

    private var microphoneMenuItems: [CapsuleMenuItem<String?>] {
        var items: [CapsuleMenuItem<String?>] = [
            CapsuleMenuItem(nil, title: L10n.text("System Default")),
        ]
        items.append(contentsOf: inputDevices.map {
            CapsuleMenuItem(Optional($0.uid), title: $0.name)
        })
        if let uid = model.inputDeviceUID,
           !inputDevices.contains(where: { $0.uid == uid }) {
            items.append(CapsuleMenuItem(Optional(uid), title: L10n.text("Chosen Microphone (Not Connected)"), separatorBefore: true))
        }
        return items
    }

    private var selectedLanguageName: String {
        let match = Self.languages.first(where: { $0.0 == model.language })?.1 ?? model.language
        return L10n.text(match)
    }

    private var inputCard: some View {
        GroupCard(
            header: L10n.text("Microphone and audio"),
            footer: "Velora keeps using a chosen microphone when AirPods or another input connect."
        ) {
            GroupRow(label: L10n.text("Microphone")) {
                CapsuleOptionMenu(
                    L10n.text("Microphone"),
                    value: selectedMicrophoneName,
                    selection: $model.inputDeviceUID,
                    items: microphoneMenuItems
                )
            }
            GroupDivider()
            GroupRow(label: L10n.text("Language")) {
                CapsuleOptionMenu(
                    L10n.text("Language"),
                    value: selectedLanguageName,
                    selection: $model.language,
                    items: Self.languages.map { CapsuleMenuItem($0.0, title: L10n.text($0.1)) }
                )
            }
            GroupDivider()
            SettingsToggleRow(
                title: "Quiet other audio while recording",
                subtitle: "Lowers volume on shared Bluetooth headsets and other audio; pauses Music or Spotify.",
                isOn: $model.duckOtherAudio)
        }
    }

    private var deliveryCard: some View {
        GroupCard(header: L10n.text("Delivery")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: VeloraSpacing.m) {
                    Text(L10n.text("Result"))
                        .font(.system(size: 13))
                    Spacer(minLength: VeloraSpacing.s)
                    CapsuleOptionMenu(
                        L10n.text("Result"),
                        value: L10n.text(model.dictationDelivery.title),
                        selection: $model.dictationDelivery,
                        items: DictationDelivery.allCases.map { CapsuleMenuItem($0, title: L10n.text($0.title)) }
                    )
                }
                Text(L10n.text("If insertion is blocked, your words stay on the clipboard. A copy you make during delivery always wins."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, VeloraSpacing.s)
            GroupDivider()
            SettingsToggleRow(
                title: "Show provisional words while speaking",
                subtitle: "Displays live speech feedback inside the dictation pill.",
                isOn: $model.showLiveWords)
        }
    }

    private var writingCard: some View {
        GroupCard(header: L10n.text("Writing and cleanup")) {
            SettingsToggleRow(
                title: "Fast dictation",
                subtitle: "Skip AI rewriting and the writing-model download at startup. Voice Edit and Action Mode need a writing model.",
                isOn: Binding(
                    get: { !model.cleanupEnabled },
                    set: { model.cleanupEnabled = !$0 }))
            GroupDivider()
            SettingsToggleRow(
                title: "Remove hesitation sounds without AI rewriting",
                subtitle: "Removes standalone um and uh in Fast dictation. As Heard and technical modes keep their words.",
                isOn: $model.removeHesitations)
            GroupDivider()
            SettingsToggleRow(
                title: "Automatic punctuation",
                isOn: $model.autoPunctuation,
                disabled: !model.cleanupEnabled)
            GroupDivider()
            SettingsToggleRow(
                title: "Voice commands",
                subtitle: "\u{201C}Scratch that\u{201D} undoes, \u{201C}new line\u{201D} presses Return.",
                isOn: $model.voiceCommands)
            GroupDivider()
            SettingsToggleRow(
                title: "Write other languages in English letters",
                subtitle: "\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947} becomes \u{201C}namaste\u{201D}. The words stay yours.",
                isOn: $model.romanizeOutput)
        }
    }

    private var screenContextCard: some View {
        GroupCard(
            header: L10n.text("Screen context"),
            footer: "While you dictate, Velora reads text near the cursor to spell names and terms right, and has no switch to turn this off. Nothing it reads is saved, password fields are skipped, and Screen Recording only adds on-device reading of text in images."
        ) {
            GroupRow(
                label: L10n.text("On-device screen text recognition"),
                sub: L10n.text(screenRecordingGranted
                    ? "Screen Recording access is enabled for reading text in images."
                    : "Helps spell names and technical terms visible on screen.")
            ) {
                if screenRecordingGranted {
                    Label(L10n.text("Allowed"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VeloraStatus.success)
                } else {
                    Button(L10n.text("Allow Access…")) {
                        requestedScreenRecording = true
                        Permissions.requestScreenText()
                    }
                    .buttonStyle(.capsule)
                }
            }
            if !screenRecordingGranted && requestedScreenRecording {
                GroupDivider()
                HStack(spacing: VeloraSpacing.s) {
                    Text(L10n.text("Already enabled in System Settings? Quit and reopen Velora so macOS applies Screen Recording access."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: VeloraSpacing.s)
                    Button(L10n.text("Recheck")) {
                        screenRecordingGranted = Permissions.screenRecordingGranted
                    }
                    .buttonStyle(.capsule)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, VeloraSpacing.s)
            }
        }
    }

    private var recordingsCard: some View {
        GroupCard(
            header: L10n.text("Audio archive"),
            headerCaption: archiveSize == "…" ? nil : archiveSize,
            footer: recordingsFooter
        ) {
            SettingsToggleRow(
                title: "Keep audio recordings",
                subtitle: "Saves compressed Ogg Opus clips locally so you can replay or reprocess past dictations.",
                isOn: $model.saveAudio)
        }
    }

    /// "1.2 GB on disk, kept for 180 days. Your voice never leaves this Mac."
    private var recordingsFooter: String {
        let days = Int(model.audioRetentionDays)
        let retention = "kept for \(days) days"
        if archiveSize == "…" {
            return "Kept for \(days) days. Your voice never leaves this Mac."
        }
        return "\(archiveSize) on disk, \(retention). Your voice never leaves this Mac."
    }

    /// Sums the archived-clip directory size off the main thread.
    private static func archiveSizeDescription() async -> String {
        let path = AppConfig.audioDirectory.path
        return await Task.detached(priority: .utility) { () -> String in
            let fm = FileManager.default
            guard fm.fileExists(atPath: path),
                  let files = fm.enumerator(atPath: path)
            else { return "Nothing" }
            var total: Int64 = 0
            while let file = files.nextObject() as? String {
                let attrs = try? fm.attributesOfItem(atPath: path + "/" + file)
                total += (attrs?[.size] as? Int64) ?? 0
            }
            return total == 0 ? "Nothing"
                : ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }.value
    }
}

// MARK: - Models

/// Models: direct, scannable model picker for Speech and Writing models
/// (inspired by Hex's zero-nesting clarity), with inline downloaded state,
/// live download progress, and one-click removal of unused local weights.
struct ModelSettingsView: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @ObservedObject var model: SettingsModel
    @State private var storageUsed: String = Self.calculating
    @State private var cachedModels: [ModelStorage.CachedModel] = []
    @State private var removalCandidate: String?
    @State private var speechFilter: SpeechFilter = .all

    private enum SpeechFilter: String, CaseIterable, Identifiable {
        case all, downloaded
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .downloaded: return "On Mac"
            }
        }
    }

    /// Shown in the storage header until the first disk scan finishes.
    private static let calculating = "Calculating…"

    private struct Choice: Identifiable {
        let id: String
        let name: String
        let detail: String
        let size: String
        let isRecommended: Bool
    }

    private var cachedByID: [String: ModelStorage.CachedModel] {
        Dictionary(uniqueKeysWithValues: cachedModels.map { ($0.id, $0) })
    }

    private var speechChoices: [Choice] {
        let engine = model.sttEngineModels
        let recommended = model.recommendedSTTModel
        let base: [Choice]
        if !engine.isEmpty {
            base = engine.map {
                Choice(
                    id: $0.id, name: $0.displayName,
                    detail: $0.description, size: $0.size,
                    isRecommended: $0.id == recommended)
            }
        } else {
            base = STTModel.all.map {
                Choice(
                    id: $0.id, name: $0.displayName,
                    detail: $0.languages, size: $0.size,
                    isRecommended: $0.id == recommended || ($0.id == model.sttModel && (recommended ?? "").isEmpty))
            }
        }
        return sortChoices(base, selected: model.sttModel)
    }

    private var visibleSpeechChoices: [Choice] {
        guard speechFilter == .downloaded else { return speechChoices }
        let cached = cachedByID
        return speechChoices.filter { choice in
            choice.id == model.sttModel || cached[choice.id] != nil
        }
    }

    private var cleanupChoices: [Choice] {
        let recommended = model.recommendedCleanupModel
        let base = model.cleanupEngineModels.map {
            Choice(
                id: $0.id, name: $0.displayName,
                detail: $0.description, size: $0.size,
                isRecommended: $0.id == recommended)
        }
        return sortChoices(base, selected: model.cleanupModel)
    }

    private func sortChoices(_ choices: [Choice], selected: String) -> [Choice] {
        choices.sorted { lhs, rhs in
            if (lhs.id == selected) != (rhs.id == selected) {
                return lhs.id == selected
            }
            if lhs.isRecommended != rhs.isRecommended {
                return lhs.isRecommended
            }
            let leftBytes = ModelChoiceOrder.downloadBytes(lhs.size)
            let rightBytes = ModelChoiceOrder.downloadBytes(rhs.size)
            if leftBytes != rightBytes { return leftBytes < rightBytes }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func chooseWhisperModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose whisper.cpp .bin or .gguf weights. Velora uses the original file in place. It never copies, changes, or deletes it. OpenAI .pt and MLX weights use different formats."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.setSpeechModel(url.path)
        }
    }

    /// Selected choices and in-flight models remain protected from deletion.
    private var activeModelIDs: Set<String> {
        Set([model.sttModel, model.cleanupModel].filter { !$0.isEmpty })
            .union(model.downloads.protectedModels)
    }

    private var hasActiveDownloadOrAlert: Bool {
        !model.downloads.downloads.filter { $0.state != .ready }.isEmpty
            || !model.downloads.pending.isEmpty
            || !model.downloads.selectionErrors.isEmpty
            || model.storageError != nil
    }

    private var customSpeechPathActive: Bool {
        !model.sttModel.isEmpty && !speechChoices.contains(where: { $0.id == model.sttModel })
    }

    var body: some View {
        SettingsScrollCanvas {
            if hasActiveDownloadOrAlert {
                downloadBannerCard
            }
            SettingsColumnPair {
                speechModelsCard
            } right: {
                writingModelsCard
                nativeCleanupSection
                customAndStorageCard
            }
        }
        .task(id: model.storageRevision) { await refreshStorage() }
        .onAppear { model.requestStatus() }
        .alert("Remove Velora model copies?", isPresented: Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } })) {
                Button(L10n.text("Cancel"), role: .cancel) { removalCandidate = nil }
                Button(L10n.text("Remove"), role: .destructive) {
                    if let id = removalCandidate { model.removeModelCopies(id) }
                    removalCandidate = nil
                }
            } message: {
                Text(L10n.text("Only inactive copies managed by Velora are removed. Shared Hub files and imported models stay on your Mac. You can download the model again later."))
            }
    }

    private var speechModelsCard: some View {
        GroupCard(
            header: L10n.text("Speech models"),
            headerCaption: storageUsed == Self.calculating ? nil : storageUsed,
            footer: "Models download once and run locally on this Mac. Switching languages picks the best default for that scope."
        ) {
            GroupRow(label: L10n.text("Languages")) {
                Picker(L10n.text("Languages you dictate"), selection: $model.languageScope) {
                    Text(L10n.text("English only")).tag("english")
                    Text(L10n.text("Multilingual")).tag("multilingual")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if !cachedModels.isEmpty {
                GroupDivider()
                HStack {
                    Text(L10n.text("Choose a model"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker(L10n.text("Filter models"), selection: $speechFilter) {
                        ForEach(SpeechFilter.allCases) { filter in
                            Text(L10n.text(filter.title)).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, VeloraSpacing.s)
            }
            if customSpeechPathActive {
                GroupDivider()
                GroupRow(
                    label: shortName(model.sttModel),
                    sub: L10n.text("Custom local Whisper weights in use.")
                ) {
                    Text(L10n.text("Active"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VeloraBrand.accent)
                }
            }
            let choices = visibleSpeechChoices
            if choices.isEmpty {
                GroupDivider()
                Text(L10n.text("No downloaded speech models yet. Switch to All to pick one."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, VeloraSpacing.m)
            } else {
                ForEach(choices) { choice in
                    GroupDivider()
                    modelCatalogRow(
                        choice: choice,
                        kind: .stt,
                        isSelected: choice.id == model.sttModel,
                        disabled: !model.downloads.isCurrent && !model.sttEngineModels.isEmpty
                    ) {
                        model.setSpeechModel(choice.id)
                    }
                }
            }
        }
    }

    private var customAndStorageCard: some View {
        GroupCard(
            header: L10n.text("Files and cache"),
            headerCaption: storageUsed
        ) {
            GroupRow(
                label: L10n.text("Custom Whisper weights"),
                sub: L10n.text("Use a local .bin or .gguf file in place without copying.")
            ) {
                Button(L10n.text("Choose File…")) { chooseWhisperModel() }
                    .buttonStyle(.capsule)
            }
            GroupDivider()
            GroupRow(
                label: L10n.text("Model cache folder"),
                sub: L10n.text("Downloaded weights and prepared caches on this Mac.")
            ) {
                Button(L10n.text("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([ModelStorage.hubURL])
                }
                .buttonStyle(.capsule)
            }
        }
    }

    private var writingModelsCard: some View {
        let writingFooter = model.nativeCleanupEnabled
            ? "LFM3 Native is active below. Turn it off to switch between standard writing models."
            : "Writing models polish grammar and structure after transcription. Save memory unloads the model while idle; speech models stay ready."
        return GroupCard(
            header: L10n.text("Writing model"),
            headerCaption: L10n.text(model.cleanupLoaded ? "Loaded" : "Standby"),
            footer: writingFooter
        ) {
            if model.nativeCleanupEnabled {
                GroupRow(
                    label: "LFM3 Native",
                    sub: L10n.text("Active for all writing tasks.")
                ) {
                    Text(L10n.text("Active"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VeloraBrand.accent)
                }
            } else if cleanupChoices.isEmpty {
                let fallback = model.cleanupModel.isEmpty
                    ? L10n.text("Automatic (on-device)")
                    : shortName(model.cleanupModel)
                GroupRow(
                    label: fallback,
                    sub: L10n.text(model.cleanupLoaded
                        ? "Loaded and ready on this Mac."
                        : "Selected automatically based on this Mac's memory.")
                ) {
                    Text(L10n.text("On-device"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(cleanupChoices.enumerated()), id: \.element.id) { index, choice in
                    if index > 0 { GroupDivider() }
                    modelCatalogRow(
                        choice: choice,
                        kind: .cleanup,
                        isSelected: choice.id == model.cleanupModel,
                        disabled: model.nativeCleanupSwitching || !model.downloads.isCurrent
                    ) {
                        model.setCleanupModel(choice.id)
                    }
                }
            }
            GroupDivider()
            GroupRow(label: L10n.text("Idle memory policy")) {
                CapsuleOptionMenu(
                    L10n.text("Writing model readiness"),
                    value: model.cleanupMemoryPolicy.title,
                    selection: $model.cleanupMemoryPolicy,
                    items: CleanupMemoryPolicy.allCases.map { CapsuleMenuItem($0, title: $0.title) }
                )
            }
            if model.cleanupMemoryPolicy == .saveMemory {
                GroupDivider()
                GroupRow(label: L10n.text("Release after idle")) {
                    Stepper("\(Int(model.cleanupIdleMinutes)) min",
                            value: $model.cleanupIdleMinutes, in: 1...120, step: 1)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private var downloadBannerCard: some View {
        GroupCard(header: L10n.text("Active downloads")) {
            VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                DownloadRecoveryView(state: model.downloads)
                if let pending = model.downloads.pending[.stt] {
                    Text("Preparing speech model: \(shortName(pending))…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let pending = model.downloads.pending[.cleanup] {
                    Text("Preparing writing model: \(shortName(pending))…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach([DownloadKind.stt, .cleanup], id: \.rawValue) { kind in
                    if let error = model.downloads.selectionErrors[kind] {
                        Text(error).font(.caption).foregroundStyle(VeloraStatus.warningText)
                    }
                }
                if let error = model.storageError {
                    Text(error).font(.caption).foregroundStyle(VeloraStatus.warningText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, VeloraSpacing.m)
        }
    }

    @ViewBuilder
    private var nativeCleanupSection: some View {
        if model.nativeCleanupSelection.isVisible {
            GroupCard(
                header: L10n.text("Experimental writing model"),
                footer: "LFM3 handles every writing task and never switches models automatically. It is tuned for dictation; editing and translation may be less reliable."
            ) {
                SettingsToggleRow(
                    title: "LFM3 Native",
                    subtitle: "Runs natively without switching models.",
                    isOn: nativeCleanupBinding,
                    disabled: !model.canChangeNativeCleanup)
                if model.nativeCleanupSwitching {
                    GroupDivider()
                    HStack(spacing: VeloraSpacing.s) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(L10n.text(model.nativeCleanupSelection.pendingEnabled == false
                             ? "Switching to the saved writing model…"
                             : "Waiting for the engine to confirm the change…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, VeloraSpacing.s)
                }
                if !model.nativeCleanupConnected {
                    GroupDivider()
                    Text(L10n.text("Reconnect to the engine to change this choice."))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, VeloraSpacing.s)
                } else if !model.nativeCleanupAvailable && model.nativeCleanupEnabled {
                    GroupDivider()
                    Text(L10n.text("LFM3 Native is unavailable. Restore the local package or turn this off to choose another writing model."))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, VeloraSpacing.s)
                }
                if let error = model.nativeCleanupError {
                    GroupDivider()
                    Text(error)
                        .font(.caption).foregroundStyle(VeloraStatus.warningText)
                        .padding(.horizontal, 14).padding(.vertical, VeloraSpacing.s)
                }
            }
        }
    }

    // MARK: Model catalog row

    private func modelCatalogRow(
        choice: Choice,
        kind: DownloadKind,
        isSelected: Bool,
        disabled: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        let cached = cachedByID[choice.id]
        let download = model.downloads.downloads.first { $0.model == choice.id && $0.kind == kind }
        let canRemove = cached.map { ModelStorage.canRemove($0, protected: activeModelIDs) } ?? false

        return HStack(alignment: .center, spacing: VeloraSpacing.s) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: VeloraSpacing.m) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected
                                         ? AnyShapeStyle(VeloraBrand.accent)
                                         : AnyShapeStyle(.tertiary))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(choice.name)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if choice.isRecommended {
                                modelBadge("Recommended", tint: VeloraBrand.accent)
                            }
                            if cached != nil && !isSelected {
                                modelBadge("On Mac", tint: .secondary)
                            }
                        }
                        if !choice.detail.isEmpty {
                            Text(choice.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let download, download.state != .ready {
                            downloadProgressLine(download)
                        }
                    }
                    Spacer(minLength: VeloraSpacing.s)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)

            VStack(alignment: .trailing, spacing: 2) {
                if !choice.size.isEmpty {
                    Text(choice.size)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if isSelected {
                    Text(L10n.text("Active"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(VeloraBrand.accent)
                }
            }

            if canRemove {
                Button {
                    removalCandidate = choice.id
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.downloads.isCurrent)
                .help(L10n.text("Remove downloaded copy"))
                .accessibilityLabel(L10n.format("Remove %@", choice.name))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? VeloraBrand.accent.opacity(0.06) : Color.clear)
    }

    private func modelBadge(_ text: String, tint: Color) -> some View {
        Text(L10n.text(text))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    @ViewBuilder
    private func downloadProgressLine(_ download: ModelDownload) -> some View {
        switch download.state {
        case .downloading:
            HStack(spacing: 6) {
                if let fraction = download.fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 120)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                    Text(L10n.text("Downloading…"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        case .queued, .verifying, .loading, .retry_wait:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L10n.text(download.state == .loading ? "Loading…" : "Preparing…"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        case .failed:
            Text(download.error?.message ?? L10n.text("Download failed"))
                .font(.system(size: 10.5))
                .foregroundStyle(VeloraStatus.warningText)
                .padding(.top, 2)
        case .ready:
            EmptyView()
        }
    }

    private var nativeCleanupBinding: Binding<Bool> {
        Binding(get: { model.nativeCleanupEnabled }, set: { model.setNativeCleanupEnabled($0) })
    }

    // MARK: Storage

    private func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    private func refreshStorage() async {
        let scanned = await ModelStorage.scan()
        cachedModels = scanned
        storageUsed = Self.sizeLabel(scanned, empty: "No models downloaded")
    }

    private static func sizeLabel(_ models: [ModelStorage.CachedModel], empty: String) -> String {
        let total = models.reduce(Int64(0)) { $0 + $1.bytes }
        if total == 0 { return empty }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

// MARK: - Advanced

/// Advanced: meeting preferences, terminal cleanup, and the tools a power
/// user reaches for (settings file, CLI, logs, the Setup Assistant). Every
/// row here used to live somewhere more prominent. Updates live in General.
struct AdvancedSettingsView: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @ObservedObject var model: SettingsModel
    @ObservedObject var coordinator: MeetingCoordinator
    let openSetupAssistant: () -> Void

    @State private var editingNotesPrompt = false

    var body: some View {
        SettingsScrollCanvas {
            SettingsColumnPair {
                meetingsCard
                diagnosticsCard
            } right: {
                retentionCard
                developerToolsCard
            }
        }
        .onAppear { model.refreshAgentIntegration() }
        .sheet(isPresented: $editingNotesPrompt) {
            MeetingNotesPromptEditor(model: model)
        }
    }

    private var meetingsCard: some View {
        GroupCard(
            header: L10n.text("Meetings"),
            footer: MeetingPreferenceRows.footer
        ) {
            MeetingPreferenceRows(model: model, coordinator: coordinator)
            GroupDivider()
            GroupRow(
                label: L10n.text("Notes prompt"),
                sub: L10n.text(model.meetingNotesPrompt.isEmpty ? "Using default guidance." : "Using custom prompt.")
            ) {
                Button(L10n.text("Edit…")) { editingNotesPrompt = true }
                    .buttonStyle(.capsule)
            }
        }
    }

    private var retentionCard: some View {
        GroupCard(header: L10n.text("Storage and retention")) {
            RetentionSettingsView(model: model)
        }
    }

    private var developerToolsCard: some View {
        GroupCard(
            header: L10n.text("Terminals and developer tools"),
            footer: "Export copies your preferences, shortcuts and speech model. History, recordings, dictionary and permissions stay on this Mac, and local agents open no network port."
        ) {
            SettingsToggleRow(
                title: "Smart cleanup in terminals",
                subtitle: "Prose is cleaned up. Short commands land exactly as heard.",
                isOn: $model.smartTerminal)
            GroupDivider()
            settingsFileRow
            GroupDivider()
            SettingsToggleRow(
                title: "Allow local CLI and agents",
                subtitle: "Expose an owner-only local control socket for scripts and agents.",
                isOn: $model.localAgentAccess)
            GroupDivider()
            AgentCapabilitySettingsView(enabled: model.localAgentAccess)
            if model.localAgentAccess {
                GroupDivider()
                agentIntegrationRow(
                    title: "Command-line tool",
                    detail: model.cliInstallPath ?? "Puts a “velora” command on your PATH.",
                    buttonTitle: model.cliInstallPath == nil ? "Install" : "Reinstall"
                ) { model.installCLITool() }
                GroupDivider()
                agentIntegrationRow(
                    title: "Agent skill",
                    detail: model.agentSkillInstalled
                        ? "Installed. Claude Code knows what it can ask Velora."
                        : "Teaches local agents (Claude Code) where to look and what they can ask.",
                    buttonTitle: model.agentSkillInstalled ? "Reinstall" : "Install"
                ) { model.installAgentSkill() }
                if let error = model.agentIntegrationError {
                    GroupDivider()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(VeloraStatus.warningText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, VeloraSpacing.s)
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        GroupCard(header: L10n.text("Diagnostics and setup")) {
            GroupRow(
                label: L10n.text("Engine logs"),
                sub: L10n.text("Open the local speech engine log folder in Finder.")
            ) {
                Button(L10n.text("Show in Finder")) { Self.revealEngineLog() }
                    .buttonStyle(.capsule)
            }
            GroupDivider()
            GroupRow(
                label: L10n.text("Setup Assistant"),
                sub: L10n.text("Re-check permissions, microphone input, and model setup.")
            ) {
                Button(L10n.text("Run Setup Assistant…"), action: openSetupAssistant)
                    .buttonStyle(.capsule)
            }
            GroupDivider()
            SettingsDisclosureRow(title: "Recent support events") {
                ActivityView()
            }
        }
    }

    /// Export/Import plus the last result and the file's path.
    private var settingsFileRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            GroupRow(
                label: L10n.text("Settings file"),
                sub: "~/.velora/settings.json"
            ) {
                HStack(spacing: VeloraSpacing.xs) {
                    Button(L10n.text("Export…")) { model.exportSettings() }
                        .buttonStyle(.capsule)
                    Button(L10n.text("Import…")) { model.importSettings() }
                        .buttonStyle(.capsule)
                }
            }
            if let result = model.settingsTransferResult {
                Group {
                    if result.hasPrefix("Import failed") || result.hasPrefix("Export failed") {
                        Label(result, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(VeloraStatus.warningText)
                    } else {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.bottom, VeloraSpacing.s)
            }
        }
    }

    /// Title + status caption on the left, install action on the right.
    private func agentIntegrationRow(
        title: String, detail: String, buttonTitle: String, action: @escaping () -> Void
    ) -> some View {
        GroupRow(label: L10n.text(title), sub: L10n.text(detail)) {
            Button(L10n.text(buttonTitle), action: action)
                .buttonStyle(.capsule)
        }
    }

    /// Selects the engine log in Finder (falls back to the ~/.velora folder
    /// before the engine has written one).
    private static func revealEngineLog() {
        let log = AppConfig.veloraDirectory.appendingPathComponent("engine.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([AppConfig.veloraDirectory])
    }
}

// MARK: - Shortcuts

/// Shortcuts: one grouped section per voice feature, in the Form idiom the
/// other tabs use. Each section opens with the feature's name and what it
/// does (its master toggle where it has one), then its shortcut. The Music
/// permission row appears only while the user can actually act on it: a
/// permanently "Allowed" status row is dead weight.
///
///     ┌──────────────────────────────────────────┐
///     │ Stream Typing                       (●)  │  toggle + caption
///     │ Your words appear at the cursor…         │
///     │ Shortcut                        [⌃][⇧][S]│
///     └──────────────────────────────────────────┘
///     Velora swaps in the polished text…          footer
struct ShortcutsSettingsView: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @ObservedObject var model: SettingsModel
    @State private var musicPermission: NativeMediaPermission?
    @State private var requestingMusicPermission = false

    var body: some View {
        SettingsScrollCanvas {
            dictationHeroCard
            SettingsColumnPair {
                dictateAndSendCard
                streamTypingCard
                proofreadCard
            } right: {
                voiceEditCard
                actionModeCard
            }
        }
        .onAppear(perform: refreshMusicPermission)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refreshMusicPermission()
        }
    }

    // MARK: Dictation hero card

    private var dictationHeroCard: some View {
        GroupCard(
            header: L10n.text("Primary dictation"),
            headerLink: (L10n.text("Restore defaults"), { model.restoreDictationShortcutDefaults() }),
            footer: model.hotkeyMode == .hold ? "A quick tap locks recording on; tap again to finish." : nil
        ) {
            GroupRow(
                label: L10n.text("Dictation shortcut"),
                sub: L10n.text("Press your shortcut and speak, anywhere you can type. Esc cancels.")
            ) {
                HotkeyRecorderView(
                    hotkey: $model.hotkey, showsQuickPicks: false, feature: "Dictation")
            }
            GroupDivider()
            GroupRow(label: L10n.text("When pressed")) {
                Picker(L10n.text("When pressed"), selection: $model.hotkeyMode) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(L10n.text(mode.displayName)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            GroupDivider()
            SettingsToggleRow(
                title: "Use a second dictation shortcut",
                subtitle: "Keep an alternate key handy for one-handed or external keyboards.",
                isOn: $model.secondDictationEnabled)
            if model.secondDictationEnabled {
                GroupDivider()
                shortcutCardRow(for: "Second dictation shortcut", hotkey: $model.secondDictationHotkey)
                if model.secondDictationConflict {
                    conflictLabel("Choose a shortcut that is not assigned to another feature.")
                }
            }
            if let error = model.dictationShortcutRestoreError {
                GroupDivider()
                conflictLabel(error)
            }
        }
    }

    // MARK: Voice mode cards (same monochrome symbol idiom as Home › Ways to talk)

    private var dictateAndSendCard: some View {
        GroupCard(
            footer: "Mail, Outlook, and Superhuman paste as a draft without auto-sending. If focus moves, Velora copies instead."
        ) {
            HStack(alignment: .center, spacing: VeloraSpacing.m) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.dictateAndSendEnabled ? AnyShapeStyle(VeloraBrand.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Dictate & Send"))
                        .font(.system(size: 13, weight: .medium))
                    Text(L10n.text("Hold to see your words live, then release to paste and press Return. Esc cancels."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: VeloraSpacing.s)
                Toggle(L10n.text("Dictate & Send"), isOn: $model.dictateAndSendEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, VeloraSpacing.m)
            GroupDivider()
            Group {
                shortcutCardRow(for: "Dictate & Send", hotkey: $model.dictateAndSendHotkey)
                if model.dictateAndSendHotkeyConflict {
                    conflictLabel("Dictate & Send needs a shortcut of its own.")
                }
                GroupDivider()
                GroupRow(label: L10n.text("Send key")) {
                    Picker(L10n.text("Send key"), selection: $model.autoSendKey) {
                        ForEach(AutoSendKey.allCases) { key in
                            Text(L10n.text(key.title)).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .disabled(!model.dictateAndSendEnabled)
            .opacity(model.dictateAndSendEnabled ? 1 : 0.5)
        }
    }

    private var streamTypingCard: some View {
        modeCard(
            title: "Stream Typing",
            symbol: "text.cursor",
            caption: "Your words appear at the cursor while you speak.",
            footer: "Velora swaps in the polished text when you finish. If you type or move the cursor, it stops and copies the final text instead.",
            isOn: $model.streamTypingEnabled,
            hotkey: $model.streamTypingHotkey,
            conflict: model.streamTypingHotkeyConflict ? "Stream Typing needs a shortcut of its own." : nil)
    }

    private var voiceEditCard: some View {
        modeCard(
            title: "Voice Edit",
            symbol: "wand.and.stars",
            caption: "Select text, press the shortcut, and say the change: \u{201C}make this more formal\u{201D}. \u{2318}Z undoes it.",
            isOn: $model.voiceEdit,
            hotkey: $model.editHotkey,
            conflict: model.editHotkeyConflict ? "Dictation and Voice Edit need different shortcuts." : nil)
    }

    private var proofreadCard: some View {
        modeCard(
            title: "Proofread",
            symbol: "text.badge.checkmark",
            caption: "Fix spelling and grammar in selected text, no microphone needed.",
            isOn: $model.proofreadEnabled,
            hotkey: $model.proofreadHotkey,
            conflict: model.proofreadHotkeyConflict ? "Proofread needs a shortcut of its own." : nil)
    }

    private var actionModeCard: some View {
        GroupCard(
            footer: "Action Mode needs Accessibility permission and runs entirely on this Mac."
        ) {
            HStack(alignment: .center, spacing: VeloraSpacing.m) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.actionsEnabled ? AnyShapeStyle(VeloraBrand.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: VeloraSpacing.s) {
                        Text(L10n.text("Action Mode"))
                            .font(.system(size: 13, weight: .medium))
                        ExperimentalBadge()
                    }
                    Text(L10n.text("Hold the shortcut and say what to do: \u{201C}message Priya on Slack that I\u{2019}m running late\u{201D}. Say \u{201C}draft\u{201D} to stop before it sends."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: VeloraSpacing.s)
                Toggle(L10n.text("Action Mode"), isOn: $model.actionsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, VeloraSpacing.m)
            GroupDivider()
            Group {
                shortcutCardRow(for: "Action Mode", hotkey: $model.actionHotkey)
                if model.actionHotkeyConflict {
                    conflictLabel("Action Mode needs a shortcut of its own.")
                }
                if CuaDriver.isInstalled {
                    GroupDivider()
                    SettingsToggleRow(
                        title: "Work in the background",
                        subtitle: "Velora works in the target app\u{2019}s window while yours stays in front.",
                        isOn: $model.backgroundActions)
                }
                musicPermissionRow
            }
            .disabled(!model.actionsEnabled)
            .opacity(model.actionsEnabled ? 1 : 0.5)
        }
    }

    private func modeCard(
        title: String,
        symbol: String,
        caption: String,
        footer: String? = nil,
        isOn: Binding<Bool>,
        hotkey: Binding<Hotkey>,
        conflict: String?
    ) -> some View {
        GroupCard(footer: footer) {
            HStack(alignment: .center, spacing: VeloraSpacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue ? AnyShapeStyle(VeloraBrand.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title))
                        .font(.system(size: 13, weight: .medium))
                    Text(L10n.text(caption))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: VeloraSpacing.s)
                Toggle(L10n.text(title), isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, VeloraSpacing.m)
            GroupDivider()
            Group {
                shortcutCardRow(for: title, hotkey: hotkey)
                if let conflict {
                    conflictLabel(conflict)
                }
            }
            .disabled(!isOn.wrappedValue)
            .opacity(isOn.wrappedValue ? 1 : 0.5)
        }
    }

    @ViewBuilder
    private var musicPermissionRow: some View {
        let actionable: [NativeMediaPermission?] = [.needsConsent, .denied, .unavailable]
        if actionable.contains(musicPermission) {
            GroupDivider()
            GroupRow(
                label: L10n.text("Music control"),
                sub: L10n.text("Allow once to play or pause Music without bringing it forward.")
            ) {
                switch musicPermission {
                case .needsConsent:
                    Button(requestingMusicPermission ? "Waiting…" : "Allow…",
                           action: requestMusicPermission)
                        .buttonStyle(.capsule)
                        .disabled(requestingMusicPermission)
                case .denied:
                    Button(L10n.text("Open Settings")) {
                        Permissions.openAutomationSettings()
                    }
                    .buttonStyle(.capsule)
                default:
                    Text(L10n.text("Open Music, then return here"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Shared rows

    private func shortcutCardRow(for feature: String, hotkey: Binding<Hotkey>) -> some View {
        GroupRow(label: L10n.text("Shortcut")) {
            HotkeyRecorderView(hotkey: hotkey, showsQuickPicks: false, feature: feature)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("%@ shortcut", L10n.text(feature)))
    }

    private func conflictLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(VeloraStatus.warningText)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
    }

    private func refreshMusicPermission() {
        NativeMediaAutomation.shared.readMusicPermission { permission in
            musicPermission = permission
        }
    }

    private func requestMusicPermission() {
        requestingMusicPermission = true
        NativeMediaAutomation.shared.requestMusicPermission { permission in
            musicPermission = permission
            requestingMusicPermission = false
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @ObservedObject var model: SettingsModel

    private var version: String { VeloraAppInfo.shortVersion }

    private var build: String? { VeloraAppInfo.buildNumber }

    /// The real bundled app icon — the About pane must show exactly what sits
    /// in the Dock/Finder, not an SF Symbol stand-in.
    private var appIcon: NSImage { VeloraAppInfo.icon }

    var body: some View {
        VStack(spacing: VeloraSpacing.m) {
            Spacer(minLength: VeloraSpacing.xl)
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            Text(L10n.text("Velora"))
                .font(.title2.weight(.semibold))
            Text(build.map { "Version \(version) (\($0))" } ?? "Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(L10n.text("Open-source, local-first dictation.\nYour voice never leaves this Mac."))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            UpdateActionRow(model: model, checkLabel: "Check for Updates")
                .padding(.top, VeloraSpacing.xs)

            // Email Support is a text link like the ones below: a prominent
            // button here outranked the update action and used a second
            // primary style (the Update window uses `.primaryCapsule`).
            if let supportURL = VeloraLinks.supportEmailURL {
                Link("Email Support", destination: supportURL)
                    .accessibilityHint("Opens a new support email to \(VeloraLinks.supportEmailAddress)")
                    .padding(.top, VeloraSpacing.xs)
            }

            HStack(spacing: VeloraSpacing.l) {
                link("Website", VeloraLinks.websiteURL)
                link("GitHub", VeloraLinks.repositoryURL)
                link("Star Velora", VeloraLinks.starURL)
                link("Report an Issue", VeloraLinks.issuesURL)
            }
            .padding(.top, VeloraSpacing.xs)

            Spacer()

            Text(L10n.text("Built with parakeet-mlx, mlx-whisper, and mlx-lm."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, VeloraSpacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Link that quietly renders nothing if a destination cannot be formed.
    @ViewBuilder
    private func link(_ title: String, _ url: URL?) -> some View {
        if let url {
            Link(title, destination: url)
        }
    }
}
