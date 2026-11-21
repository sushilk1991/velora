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
        SettingsCanvas { isWide in
            SettingsAdaptiveColumns(isWide: isWide) {
                appearanceCard
                soundsCard
            } right: {
                updatesCard
                pillCard
            }
        }
    }

    private var appearanceCard: some View {
        SettingsCard(title: "Appearance", symbol: "paintbrush", tint: VeloraBrand.accent) {
            SettingsRow(title: "Theme") {
                Picker(L10n.text("Appearance"), selection: $model.appearance) {
                    Text(L10n.text("System")).tag("system")
                    Text(L10n.text("Light")).tag("light")
                    Text(L10n.text("Dark")).tag("dark")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            GroupDivider()
            SettingsRow(
                title: "Interface language",
                subtitle: "Changes menus and settings. Dictation language is set separately."
            ) {
                Picker(L10n.text("Interface language"), selection: $model.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
            }
            GroupDivider()
            SettingsToggleRow(
                title: "Launch Velora at login",
                subtitle: "Start quietly in the menu bar when you sign in.",
                isOn: $model.launchAtLogin)
        }
    }

    private var pillCard: some View {
        SettingsCard(
            title: "Dictation Pill",
            symbol: "capsule.inset.filled",
            tint: VeloraBrand.warm,
            footer: "You can also hide it from its right-click menu."
        ) {
            SettingsRow(title: "Show pill") {
                Picker(L10n.text("Show pill"), selection: pillVisibility) {
                    ForEach(PillVisibility.allCases) { choice in
                        Text(L10n.text(choice.title)).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
            }
            GroupDivider()
            DisclosureGroup(L10n.text("Preview the pill")) {
                HUDPreviewView(model: model)
                    .padding(.top, VeloraSpacing.s)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var soundsCard: some View {
        SettingsCard(title: "Sound & Feedback", symbol: "speaker.wave.2", tint: VeloraBrand.accent) {
            SettingsToggleRow(
                title: "Play sounds",
                subtitle: "Subtle cues for recording start, release, completion, and errors.",
                isOn: $model.soundsEnabled)
            if model.soundsEnabled {
                GroupDivider()
                SettingsRow(title: "Sound set") {
                    Picker(L10n.text("Sound set"), selection: $model.soundSet) {
                        ForEach(SoundSet.allCases) { soundSet in
                            Text(soundSet.title).tag(soundSet)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
                GroupDivider()
                SettingsRow(title: "Sound volume") {
                    HStack(spacing: VeloraSpacing.s) {
                        Slider(value: $model.soundVolume, in: 0...100)
                            .frame(width: 150)
                            .accessibilityLabel(L10n.text("Sound volume"))
                        Text("\(Int(model.soundVolume.rounded()))%")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                GroupDivider()
                VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                    Text(L10n.text("Preview cues"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: VeloraSpacing.xs) {
                        Button(L10n.text("Start")) { previewSounds.play(.start, preview: true) }
                        Button(L10n.text("Release")) { previewSounds.play(.preStop, preview: true) }
                        Button(L10n.text("Stop")) { previewSounds.play(.stop, preview: true) }
                        Button(L10n.text("No speech")) { previewSounds.play(.noResult, preview: true) }
                        Button(L10n.text("Error")) { previewSounds.play(.error, preview: true) }
                    }
                    .buttonStyle(.settingsChip)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var updatesCard: some View {
        SettingsCard(
            title: "Updates",
            symbol: "arrow.down.circle",
            tint: VeloraStatus.success,
            footer: "Checks GitHub once a day and sends nothing about you or what you dictate. Before installing an update, Velora checks Apple's signature and notarization."
        ) {
            HStack(alignment: .center, spacing: VeloraSpacing.m) {
                Image(nsImage: VeloraAppInfo.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("Version %@", VeloraAppInfo.shortVersion))
                        .font(.system(size: 13.5, weight: .semibold))
                    if let status = model.updateCheckStatus {
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: VeloraSpacing.s)
                UpdateActionRow(model: model, checkStatusPlacement: .caller)
                    .buttonStyle(.settingsChip)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
            SettingsRow(title: "Release notes") {
                Button(L10n.text("View Release History…")) { model.openReleaseHistory() }
                    .buttonStyle(.settingsChip)
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

    /// Whisper language codes, weighted toward the most-spoken languages.
    private static let languages: [(String, String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("hi", "Hindi"),
        ("es", "Spanish"), ("zh", "Mandarin Chinese"), ("ar", "Arabic"),
        ("fr", "French"), ("pt", "Portuguese"), ("de", "German"),
        ("it", "Italian"), ("ja", "Japanese"),
    ]

    var body: some View {
        SettingsCanvas { isWide in
            SettingsAdaptiveColumns(isWide: isWide) {
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .veloraAudioInputDevicesChanged)) { _ in
            inputDevices = AudioInputDevices.displayList()
        }
    }

    private var inputCard: some View {
        SettingsCard(
            title: "Microphone & Audio",
            symbol: "mic",
            tint: VeloraBrand.accent,
            footer: "Velora keeps using a chosen microphone when AirPods or another input connect."
        ) {
            SettingsRow(title: "Microphone") {
                Picker(L10n.text("Microphone"), selection: $model.inputDeviceUID) {
                    Text(L10n.text("System Default")).tag(String?.none)
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                    if let uid = model.inputDeviceUID,
                       !inputDevices.contains(where: { $0.uid == uid }) {
                        Text(L10n.text("Chosen Microphone (Not Connected)")).tag(String?.some(uid))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            GroupDivider()
            SettingsRow(title: "Language") {
                Picker(L10n.text("Language"), selection: $model.language) {
                    ForEach(Self.languages, id: \.0) { code, name in
                        Text(L10n.text(name)).tag(code)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }
            GroupDivider()
            SettingsToggleRow(
                title: "Quiet other audio while recording",
                subtitle: "Lowers volume on shared Bluetooth headsets and other audio; pauses Music or Spotify.",
                isOn: $model.duckOtherAudio)
        }
    }

    private var deliveryCard: some View {
        SettingsCard(
            title: "Delivery",
            symbol: "text.insert",
            tint: VeloraBrand.warm
        ) {
            SettingsRow(
                title: "Result",
                subtitle: "If insertion is blocked, your words stay on the clipboard. A copy you make during delivery always wins."
            ) {
                Picker(L10n.text("Result"), selection: $model.dictationDelivery) {
                    ForEach(DictationDelivery.allCases) { choice in
                        Text(L10n.text(choice.title)).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            GroupDivider()
            SettingsToggleRow(
                title: "Show provisional words while speaking",
                subtitle: "Displays live speech feedback inside the dictation pill.",
                isOn: $model.showLiveWords)
        }
    }

    private var writingCard: some View {
        SettingsCard(
            title: "Writing & Cleanup",
            symbol: "wand.and.stars",
            tint: Color.purple
        ) {
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
        SettingsCard(
            title: "Screen Context",
            symbol: "text.viewfinder",
            tint: VeloraBrand.accent,
            footer: "While you dictate, Velora reads text near the cursor to spell names and terms right, and has no switch to turn this off. Nothing it reads is saved, password fields are skipped, and Screen Recording only adds on-device reading of text in images."
        ) {
            SettingsRow(
                title: "On-device screen text recognition",
                subtitle: "Helps spell names and technical terms visible on screen."
            ) {
                Button(L10n.text("Allow Access…")) {
                    Permissions.requestScreenText()
                }
                .buttonStyle(.settingsChip)
            }
        }
    }

    private var recordingsCard: some View {
        SettingsCard(
            title: "Audio Archive",
            symbol: "waveform.circle",
            tint: VeloraStatus.success,
            footer: recordingsFooter,
            headerTrailing: {
                if archiveSize != "…" {
                    SettingsStatusPill(text: archiveSize, tint: .secondary)
                }
            }
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

/// Models: the two models in use, each with a "Change…" that unfolds the
/// choices in place, and the storage they occupy.
///
///     On this Mac
///     Speech to text                                   [Change…]
///       Whisper Turbo · 1.6 GB
///       ○ Parakeet v3 / Fastest. English and 24 … (only while unfolded)
///     Cleanup                                          [Change…]
///       Quality · 5.2 GB
struct ModelSettingsView: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @ObservedObject var model: SettingsModel
    @State private var storageUsed: String = Self.calculating
    @State private var cachedModels: [ModelStorage.CachedModel] = []
    @State private var changing: Slot?
    @State private var removalCandidate: String?
    @State private var modelSearch = ""
    @State private var installedOnly = false
    @State private var modelSort = "recommended"

    /// Which "Change…" is unfolded (at most one at a time).
    private enum Slot { case speech, cleanup }

    /// Shown in the storage rows until the first disk scan finishes; a bare
    /// "…" read as missing data.
    private static let calculating = "Calculating…"

    /// One row in the picker / catalog. Prefers the engine's advertised models
    /// (so newly-shipped models appear without an app update); falls back to the
    /// static catalog before the first `status` reply lands.
    private struct Choice: Identifiable {
        let id: String
        let name: String
        let detail: String
        let size: String
    }

    private var speechChoices: [Choice] {
        let engine = model.sttEngineModels
        let recommended = model.recommendedSTTModel
        if !engine.isEmpty {
            return engine.map {
                Choice(
                    id: $0.id, name: $0.displayName,
                    detail: $0.id == recommended
                        ? "Recommended for your language choice. \($0.description)"
                        : $0.description,
                    size: $0.size)
            }
        }
        return STTModel.all.map {
            Choice(id: $0.id, name: $0.displayName, detail: $0.languages, size: $0.size)
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

    /// Cleanup models the engine advertises (smallest first).
    private var cleanupChoices: [Choice] {
        model.cleanupEngineModels.map {
            let recommended = $0.id == model.recommendedCleanupModel
            return Choice(
                id: $0.id, name: $0.displayName,
                detail: recommended ? "Recommended for this Mac. \($0.description)" : $0.description,
                size: $0.size)
        }
    }

    /// Selected choices and in-flight models remain protected from deletion.
    private var activeModelIDs: Set<String> {
        Set([model.sttModel, model.cleanupModel].filter { !$0.isEmpty })
            .union(model.downloads.protectedModels)
    }

    private var unusedModels: [ModelStorage.CachedModel] {
        cachedModels.filter { !activeModelIDs.contains($0.id) }
    }

    var body: some View {
        SettingsCanvas { isWide in
            SettingsAdaptiveColumns(isWide: isWide) {
                speechModelCard
                storageCard
            } right: {
                writingModelCard
                nativeCleanupSection
                downloadStatusCard
            }
        }
        .task(id: model.storageRevision) { await refreshStorage() }
        .onAppear { model.requestStatus() }
        .onChange(of: model.nativeCleanupSwitching) { _, switching in
            if switching && changing == .cleanup { changing = nil }
        }
        .onChange(of: model.nativeCleanupEnabled) { _, enabled in
            if enabled && changing == .cleanup { changing = nil }
        }
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

    private var speechModelCard: some View {
        let active = speechChoices.first { $0.id == speechBinding.wrappedValue }
        return SettingsCard(
            title: "Speech to Text",
            symbol: "waveform",
            tint: VeloraBrand.accent,
            footer: "Changing the language choice re-selects the recommended speech model for it. Models download once, then run on this Mac.",
            headerTrailing: {
                if let size = active?.size, !size.isEmpty {
                    SettingsStatusPill(text: size, tint: VeloraBrand.accent)
                }
            }
        ) {
            SettingsRow(title: "Languages you dictate") {
                Picker(L10n.text("Languages you dictate"), selection: $model.languageScope) {
                    Text(L10n.text("English only")).tag("english")
                    Text(L10n.text("English and other languages")).tag("multilingual")
                }
                .labelsHidden()
                .frame(maxWidth: 210)
            }
            GroupDivider()
            slotRow(
                title: "Active model", slot: .speech, choices: speechChoices,
                selection: speechBinding)
            GroupDivider()
            SettingsRow(
                title: "Custom Whisper weights",
                subtitle: "Use a local .bin or .gguf file in place without copying."
            ) {
                Button(L10n.text("Choose File…")) { chooseWhisperModel() }
                    .buttonStyle(.settingsChip)
            }
        }
    }

    private var writingModelCard: some View {
        let active = cleanupChoices.first { $0.id == cleanupBinding.wrappedValue }
        let loaded = model.cleanupLoaded
        return SettingsCard(
            title: "Writing & Cleanup",
            symbol: "sparkles",
            tint: VeloraBrand.warm,
            footer: "Automatic uses Velora's memory policy. Save memory releases the writing model while idle; speech models stay ready.",
            headerTrailing: {
                SettingsStatusPill(
                    text: loaded ? "Loaded" : "Standby",
                    tint: loaded ? VeloraStatus.success : .secondary,
                    dot: true)
            }
        ) {
            if model.nativeCleanupEnabled {
                SettingsRow(
                    title: "Writing model",
                    subtitle: "Turn off LFM3 Native to use or change the saved writing model."
                ) {
                    SettingsStatusPill(text: "LFM3 Native", tint: VeloraBrand.warm)
                }
                if !cleanupChoices.isEmpty { GroupDivider() }
            }
            if !cleanupChoices.isEmpty {
                slotRow(
                    title: model.nativeCleanupEnabled ? "Saved writing model" : "Active model",
                    slot: .cleanup, choices: cleanupChoices,
                    selection: cleanupBinding)
                    .disabled(model.nativeCleanupEnabled || model.nativeCleanupSwitching)
                    .opacity((model.nativeCleanupEnabled || model.nativeCleanupSwitching) ? 0.55 : 1)
                GroupDivider()
            } else if !model.nativeCleanupEnabled {
                let fallback = model.cleanupModel.isEmpty
                    ? "Automatic (on-device)"
                    : shortName(model.cleanupModel)
                SettingsRow(
                    title: "Active model",
                    subtitle: active?.name ?? fallback
                ) {
                    SettingsStatusPill(text: "On-device", tint: .secondary)
                }
                GroupDivider()
            }
            SettingsRow(title: "Idle memory policy") {
                Picker(L10n.text("Writing model readiness"), selection: $model.cleanupMemoryPolicy) {
                    ForEach(CleanupMemoryPolicy.allCases) { policy in Text(policy.title).tag(policy) }
                }
                .labelsHidden()
                .frame(maxWidth: 165)
            }
            if model.cleanupMemoryPolicy == .saveMemory {
                GroupDivider()
                SettingsRow(title: "Release after idle") {
                    Stepper("\(Int(model.cleanupIdleMinutes)) min",
                            value: $model.cleanupIdleMinutes, in: 1...120, step: 1)
                        .monospacedDigit()
                }
            }
        }
    }

    private var downloadStatusCard: some View {
        SettingsCard(
            title: "Engine & Downloads",
            symbol: "arrow.down.circle.dotted",
            tint: VeloraBrand.accent
        ) {
            VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                DownloadRecoveryView(state: model.downloads)
                if let pending = model.downloads.pending[.stt] {
                    Text("Requested speech model: \(shortName(pending)); not adopted yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let pending = model.downloads.pending[.cleanup] {
                    Text("Requested writing model: \(shortName(pending)); not adopted yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach([DownloadKind.stt, .cleanup], id: \.rawValue) { kind in
                    if let error = model.downloads.selectionErrors[kind] {
                        Text(error).font(.caption).foregroundStyle(VeloraStatus.warningText)
                    }
                }
                Text(L10n.text(model.nativeCleanupEnabled
                     ? model.cleanupLoaded ? "LFM3 Native is loaded for all writing tasks." : "LFM3 Native is selected but not loaded."
                     : model.cleanupLoaded ? "Selected writing model is loaded." : "Selected writing model is not loaded. Dictation can still transcribe speech."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var storageCard: some View {
        SettingsCard(
            title: "On-Disk Storage",
            symbol: "internaldrive",
            tint: Color.secondary,
            footer: "Sizes include downloaded weights and prepared caches, but not the app bundle. Removal never deletes shared Hub files, included resources, or imported models.",
            headerTrailing: {
                SettingsStatusPill(text: storageUsed, tint: .secondary)
            }
        ) {
            SettingsRow(title: "Model cache folder") {
                Button(L10n.text("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([ModelStorage.hubURL])
                }
                .buttonStyle(.settingsChip)
            }
            ForEach(cachedModels) { item in
                GroupDivider()
                SettingsRow(
                    title: shortName(item.id),
                    subtitle: ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
                ) {
                    if ModelStorage.canRemove(item, protected: activeModelIDs) {
                        Button(L10n.text("Remove…")) { removalCandidate = item.id }
                            .buttonStyle(.settingsChip)
                            .disabled(!model.downloads.isCurrent)
                    } else if activeModelIDs.contains(item.id) {
                        SettingsStatusPill(
                            text: model.nativeCleanupEnabled && item.id == model.cleanupModel
                                ? "Saved choice" : "In use",
                            tint: VeloraStatus.success)
                    } else {
                        SettingsStatusPill(text: "Shared", tint: .secondary)
                    }
                }
            }
            if let error = model.storageError {
                GroupDivider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(VeloraStatus.warningText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var nativeCleanupSection: some View {
        if model.nativeCleanupSelection.isVisible {
            SettingsCard(
                title: "Experimental Writing Model",
                symbol: "flask",
                tint: VeloraStatus.warning,
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
                    .padding(.vertical, 10)
                }
                if !model.nativeCleanupConnected {
                    GroupDivider()
                    Text(L10n.text("Reconnect to the engine to change this choice."))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                } else if !model.nativeCleanupAvailable && model.nativeCleanupEnabled {
                    GroupDivider()
                    Text(L10n.text("LFM3 Native is unavailable. Restore the local package or turn this off to choose another writing model."))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                if let error = model.nativeCleanupError {
                    GroupDivider()
                    Text(error)
                        .font(.caption).foregroundStyle(VeloraStatus.warningText)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: Slot rows

    /// Title, the active model's caption, and "Change…"; while unfolded,
    /// every choice as a selectable row beneath.
    @ViewBuilder
    private func slotRow(
        title: String, slot: Slot, choices: [Choice], selection: Binding<String>
    ) -> some View {
        let active = choices.first { $0.id == selection.wrappedValue }
        SettingsRow(
            title: title,
            subtitle: caption(for: active, fallback: selection.wrappedValue)
        ) {
            Button(changing == slot ? L10n.text("Done") : L10n.text("Change…")) {
                changing = changing == slot ? nil : slot
            }
            .buttonStyle(.settingsChip)
        }
        if changing == slot {
            GroupDivider()
            VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                SettingsSearchBox(prompt: "Search models or languages", query: $modelSearch)
                HStack(spacing: VeloraSpacing.m) {
                    Toggle(L10n.text("Installed only"), isOn: $installedOnly)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    Spacer()
                    Picker(L10n.text("Sort"), selection: $modelSort) {
                        Text(L10n.text("Recommended")).tag("recommended")
                        Text(L10n.text("Name")).tag("name")
                        Text(L10n.text("Download size")).tag("size")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
                let visibleChoices = filteredChoices(choices, selection: selection.wrappedValue, slot: slot)
                if visibleChoices.isEmpty {
                    Text(L10n.text("No models match. Clear the search or show all models."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleChoices) { choice in
                        let isSelected = choice.id == selection.wrappedValue
                        Button {
                            selection.wrappedValue = choice.id
                        } label: {
                            HStack(alignment: .top, spacing: VeloraSpacing.s) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(isSelected
                                                     ? AnyShapeStyle(VeloraBrand.accent)
                                                     : AnyShapeStyle(.tertiary))
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.name)
                                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                    Text(choice.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: VeloraSpacing.s)
                                if !choice.size.isEmpty {
                                    Text(choice.size)
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? VeloraBrand.accent.opacity(0.10) : Color.clear))
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.downloads.isCurrent)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func filteredChoices(_ choices: [Choice], selection: String, slot: Slot) -> [Choice] {
        let cached = Set(cachedModels.map(\.id))
        let query = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let recommended = slot == .speech ? model.recommendedSTTModel : model.recommendedCleanupModel
        return choices.filter { choice in
            (!installedOnly || cached.contains(choice.id) || choice.id == selection)
                && (query.isEmpty || (choice.name + " " + choice.detail).localizedCaseInsensitiveContains(query))
        }.sorted { lhs, rhs in
            if modelSort == "size" {
                let left = ModelChoiceOrder.downloadBytes(lhs.size)
                let right = ModelChoiceOrder.downloadBytes(rhs.size)
                if left != right { return left < right }
            } else if modelSort == "recommended", (lhs.id == recommended) != (rhs.id == recommended) {
                return lhs.id == recommended
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// "Whisper Turbo · 1.6 GB". The description shows only on the
    /// unfolded choices, so the folded row stays one line.
    private func caption(for choice: Choice?, fallback id: String) -> String {
        guard let choice else { return id.isEmpty ? "Not chosen" : shortName(id) }
        return [choice.name, choice.size]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var speechBinding: Binding<String> {
        Binding(get: { model.sttModel }, set: { model.setSpeechModel($0) })
    }

    private var cleanupBinding: Binding<String> {
        Binding(get: { model.cleanupModel }, set: {
            guard !model.nativeCleanupEnabled && !model.nativeCleanupSwitching else { return }
            model.setCleanupModel($0)
        })
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
        SettingsCanvas { isWide in
            SettingsAdaptiveColumns(isWide: isWide) {
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
        SettingsCard(
            title: "Meetings",
            symbol: "person.2.wave.2",
            tint: VeloraBrand.accent,
            footer: MeetingPreferenceRows.footer
        ) {
            MeetingPreferenceRows(model: model, coordinator: coordinator)
            GroupDivider()
            SettingsRow(title: "Notes prompt") {
                HStack(spacing: VeloraSpacing.s) {
                    SettingsStatusPill(
                        text: model.meetingNotesPrompt.isEmpty ? "Default" : "Custom",
                        tint: model.meetingNotesPrompt.isEmpty ? .secondary : VeloraBrand.accent)
                    Button(L10n.text("Edit…")) { editingNotesPrompt = true }
                        .buttonStyle(.settingsChip)
                }
            }
        }
    }

    private var retentionCard: some View {
        SettingsCard(
            title: "Storage & Retention",
            symbol: "clock.arrow.circlepath",
            tint: VeloraBrand.warm
        ) {
            RetentionSettingsView(model: model)
        }
    }

    private var developerToolsCard: some View {
        SettingsCard(
            title: "Terminals & Developer Tools",
            symbol: "terminal",
            tint: Color.purple,
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
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        SettingsCard(
            title: "Diagnostics & Setup",
            symbol: "wrench.and.screwdriver",
            tint: Color.secondary
        ) {
            SettingsRow(
                title: "Engine logs",
                subtitle: "Open the local speech engine log folder in Finder."
            ) {
                Button(L10n.text("Show in Finder")) { Self.revealEngineLog() }
                    .buttonStyle(.settingsChip)
            }
            GroupDivider()
            SettingsRow(
                title: "Setup Assistant",
                subtitle: "Re-check permissions, microphone input, and model setup."
            ) {
                Button(L10n.text("Run Setup Assistant…"), action: openSetupAssistant)
                    .buttonStyle(.settingsChip)
            }
            GroupDivider()
            DisclosureGroup(L10n.text("Recent support events")) {
                ActivityView()
                    .padding(.top, VeloraSpacing.s)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// Export/Import plus the last result and the file's path.
    private var settingsFileRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: VeloraSpacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Settings file"))
                        .font(.system(size: 13))
                    Text(L10n.text("~/.velora/settings.json"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(L10n.text("Export…")) { model.exportSettings() }
                    .buttonStyle(.settingsChip)
                Button(L10n.text("Import…")) { model.importSettings() }
                    .buttonStyle(.settingsChip)
            }
            if let result = model.settingsTransferResult {
                if result.hasPrefix("Import failed") || result.hasPrefix("Export failed") {
                    Label(result, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(VeloraStatus.warningText)
                } else {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Title + status caption on the left, install action on the right.
    private func agentIntegrationRow(
        title: String, detail: String, buttonTitle: String, action: @escaping () -> Void
    ) -> some View {
        SettingsRow(title: title, subtitle: detail) {
            Button(buttonTitle, action: action)
                .buttonStyle(.settingsChip)
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
        SettingsCanvas { isWide in
            dictationHeroCard(isWide: isWide)
            SettingsAdaptiveColumns(isWide: isWide) {
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

    private func dictationHeroCard(isWide: Bool) -> some View {
        SettingsCard(
            title: "Primary Dictation",
            symbol: "mic.fill",
            tint: VeloraBrand.accent,
            footer: model.hotkeyMode == .hold ? "A quick tap locks recording on; tap again to finish." : nil,
            headerTrailing: {
                Button(L10n.text("Restore defaults")) {
                    model.restoreDictationShortcutDefaults()
                }
                .buttonStyle(.settingsChip)
            }
        ) {
            SettingsRow(
                title: "Dictation shortcut",
                subtitle: "Press your shortcut and speak, anywhere you can type. Esc cancels."
            ) {
                HotkeyRecorderView(
                    hotkey: $model.hotkey, showsQuickPicks: false, feature: "Dictation")
            }
            GroupDivider()
            SettingsRow(title: "When pressed") {
                Picker(L10n.text("When pressed"), selection: $model.hotkeyMode) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(L10n.text(mode.displayName)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: isWide ? 280 : 230)
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

    // MARK: Voice Mode bento cards

    private var streamTypingCard: some View {
        modeCard(
            title: "Stream Typing",
            symbol: "textformat",
            tint: VeloraBrand.accent,
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
            tint: Color.purple,
            caption: "Select text, press the shortcut, and say the change: \u{201C}make this more formal\u{201D}. \u{2318}Z undoes it.",
            isOn: $model.voiceEdit,
            hotkey: $model.editHotkey,
            conflict: model.editHotkeyConflict ? "Dictation and Voice Edit need different shortcuts." : nil)
    }

    private var proofreadCard: some View {
        modeCard(
            title: "Proofread",
            symbol: "text.badge.checkmark",
            tint: VeloraStatus.success,
            caption: "Fix spelling and grammar in selected text, no microphone needed.",
            isOn: $model.proofreadEnabled,
            hotkey: $model.proofreadHotkey,
            conflict: model.proofreadHotkeyConflict ? "Proofread needs a shortcut of its own." : nil)
    }

    private var actionModeCard: some View {
        SettingsCard(
            footer: "Action Mode needs Accessibility permission and runs entirely on this Mac."
        ) {
            HStack(alignment: .top, spacing: VeloraSpacing.m) {
                IconTile(symbol: "sparkles", color: VeloraBrand.warm, side: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: VeloraSpacing.s) {
                        Text(L10n.text("Action Mode"))
                            .font(.system(size: 13.5, weight: .semibold))
                        ExperimentalBadge()
                    }
                    Text(L10n.text("Hold the shortcut and say what to do: \u{201C}message Priya on Slack that I\u{2019}m running late\u{201D}. Say \u{201C}draft\u{201D} to stop before it sends."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: VeloraSpacing.s)
                Toggle("", isOn: $model.actionsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("Action Mode"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
        tint: Color,
        caption: String,
        footer: String? = nil,
        isOn: Binding<Bool>,
        hotkey: Binding<Hotkey>,
        conflict: String?
    ) -> some View {
        SettingsCard(footer: footer) {
            HStack(alignment: .top, spacing: VeloraSpacing.m) {
                IconTile(symbol: symbol, color: tint, side: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(title))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(L10n.text(caption))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: VeloraSpacing.s)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text(title))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
            SettingsRow(
                title: "Music control",
                subtitle: "Allow once to play or pause Music without bringing it forward."
            ) {
                switch musicPermission {
                case .needsConsent:
                    Button(requestingMusicPermission ? "Waiting…" : "Allow…",
                           action: requestMusicPermission)
                        .buttonStyle(.settingsChip)
                        .disabled(requestingMusicPermission)
                case .denied:
                    Button(L10n.text("Open Settings")) {
                        Permissions.openAutomationSettings()
                    }
                    .buttonStyle(.settingsChip)
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
        HStack {
            Text(L10n.text("Shortcut"))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.format("%@ shortcut", L10n.text(feature)))
            Spacer()
            HotkeyRecorderView(hotkey: hotkey, showsQuickPicks: false, feature: feature)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
