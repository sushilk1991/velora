import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Keeps the Settings toggle and the update-window checkbox coherent when
    /// both windows are open.
    static let veloraUpdatePreferencesChanged =
        Notification.Name("VeloraUpdatePreferencesChanged")
}

/// Automatic update actions are version-scoped. A newly published release
/// must not inherit "Later" or "Skip" from the previous version.
enum UpdatePromptPolicy {
    static let reminderInterval: TimeInterval = 24 * 60 * 60

    static func shouldPresent(
        version: String,
        skippedVersion: String?,
        deferredVersion: String?,
        deferredUntil: Date,
        now: Date = Date()
    ) -> Bool {
        guard skippedVersion != version else { return false }
        guard deferredVersion == version else { return true }
        return now >= deferredUntil
    }

    /// Skip and an unexpired reminder suppress the entire automatic path for
    /// that exact release: prompt, background stage, adoption, and quit-time
    /// install. Manual checks and an explicit Install always remain available.
    static func allowsAutomaticAction(
        version: String,
        skippedVersion: String?,
        deferredVersion: String?,
        deferredUntil: Date,
        now: Date = Date()
    ) -> Bool {
        shouldPresent(
            version: version,
            skippedVersion: skippedVersion,
            deferredVersion: deferredVersion,
            deferredUntil: deferredUntil,
            now: now)
    }

    /// Explicit install intent overrides a prior Skip/Later choice for this
    /// release only. Keeping the mutation rule here lets every install surface
    /// (window, Settings, and status menu) share identical behavior.
    static func clearSuppression(
        for version: String,
        skippedVersion: inout String?,
        deferredVersion: inout String?,
        deferredUntil: inout Date
    ) {
        if skippedVersion == version {
            skippedVersion = nil
        }
        if deferredVersion == version {
            deferredVersion = nil
            deferredUntil = .distantPast
        }
    }

    /// "Remind Me Later" replaces a previous Skip choice for this release.
    /// Otherwise Skip would win forever in `shouldPresent`, contradicting the
    /// new reminder deadline the user just selected.
    static func setReminder(
        for version: String,
        skippedVersion: inout String?,
        deferredVersion: inout String?,
        deferredUntil: inout Date,
        now: Date = Date()
    ) {
        if skippedVersion == version {
            skippedVersion = nil
        }
        deferredVersion = version
        deferredUntil = now.addingTimeInterval(reminderInterval)
    }
}

enum UpdateWindowPresentation: Equatable {
    case manual
    case automatic

    var defersOnClose: Bool { self == .automatic }

    static func resolved(
        current: Self,
        incoming: Self,
        windowIsVisible: Bool
    ) -> Self {
        // An automatic check may refresh the content of a changelog the user
        // already opened, but it must not reinterpret that same window's close
        // as Remind Me Later and discard staged work.
        if windowIsVisible, current == .manual, incoming == .automatic {
            return .manual
        }
        return incoming
    }
}

/// One reusable release window for automatic discoveries, manual checks, and
/// Settings changelog viewing. Automatic presentation deliberately does not
/// activate the app or steal keyboard focus from the user's current app.
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    static let shared = UpdateWindowController()

    private let model = UpdateWindowModel()
    private var holdsActivation = false
    private var closingProgrammatically = false
    private var presentation: UpdateWindowPresentation = .manual

    private init() {
        let root = UpdateWindowView(model: model)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Software Update"
        window.setContentSize(NSSize(width: 760, height: 600))
        window.minSize = NSSize(width: 680, height: 520)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()

        super.init(window: window)
        window.delegate = self
        model.onDismiss = { [weak self] in self?.dismissWindow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Manual checks and explicit menu/Settings actions activate the window.
    func show(_ release: UpdateChecker.Release) {
        show(release, presentation: .manual)
    }

    /// Daily checks respect Skip/Later and surface the window without stealing
    /// focus. The user can click it when convenient.
    func showAutomatically(_ release: UpdateChecker.Release) {
        let config = AppConfig.shared
        guard UpdatePromptPolicy.shouldPresent(
            version: release.version,
            skippedVersion: config.skippedUpdateVersion,
            deferredVersion: config.deferredUpdateVersion,
            deferredUntil: config.deferredUpdateUntil)
        else { return }
        show(release, presentation: .automatic)
    }

    private func show(
        _ release: UpdateChecker.Release,
        presentation: UpdateWindowPresentation
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let resolvedPresentation = UpdateWindowPresentation.resolved(
            current: self.presentation,
            incoming: presentation,
            windowIsVisible: window?.isVisible == true)
        self.presentation = resolvedPresentation
        model.present(release)
        if !holdsActivation {
            holdsActivation = true
            AppActivation.acquireRegular()
        }
        closingProgrammatically = false
        if presentation == .manual {
            NSApp.activate(ignoringOtherApps: true)
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        } else if resolvedPresentation == .automatic {
            window?.orderFrontRegardless()
        }
    }

    private func dismissWindow() {
        closingProgrammatically = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if Self.shouldDeferOnClose(
            presentation: presentation,
            closingProgrammatically: closingProgrammatically) {
            model.deferAfterWindowClose()
        }
        closingProgrammatically = false
        presentation = .manual
        if holdsActivation {
            holdsActivation = false
            AppActivation.releaseRegular()
        }
    }

    static func shouldDeferOnClose(
        presentation: UpdateWindowPresentation,
        closingProgrammatically: Bool
    ) -> Bool {
        !closingProgrammatically && presentation.defersOnClose
    }
}

final class UpdateWindowModel: ObservableObject {
    struct PrimaryAction: Equatable {
        let title: String
        let disabled: Bool
    }

    @Published private(set) var release: UpdateChecker.Release?
    @Published private(set) var installerState = UpdateInstaller.shared.state
    @Published var installsAutomatically = AppConfig.shared.autoInstallUpdates {
        didSet {
            guard !syncingPreferences,
                  installsAutomatically != AppConfig.shared.autoInstallUpdates
            else { return }
            AppConfig.shared.autoInstallUpdates = installsAutomatically
            NotificationCenter.default.post(
                name: .veloraUpdatePreferencesChanged, object: nil)
        }
    }

    var onDismiss: (() -> Void)?

    private var installerObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private var syncingPreferences = false
    @Published private(set) var userRequestedInstall = false
    private let installBlockerOverride: String?
    private let usesInstallBlockerOverride: Bool

    init(installBlockerOverride: String? = nil, usesInstallBlockerOverride: Bool = false) {
        self.installBlockerOverride = installBlockerOverride
        self.usesInstallBlockerOverride = usesInstallBlockerOverride
        installerObserver = NotificationCenter.default.addObserver(
            forName: .veloraUpdateStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.installerState = UpdateInstaller.shared.state
            if case .failed = self.installerState {
                self.userRequestedInstall = false
            } else if case .idle = self.installerState {
                self.userRequestedInstall = false
            } else if let version = self.release?.version {
                self.userRequestedInstall = Self.installIntentApplies(
                    to: version,
                    installerState: self.installerState,
                    explicitInstallRequested:
                        UpdateInstaller.shared.explicitInstallRequested)
            } else {
                self.userRequestedInstall = false
            }
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .veloraUpdatePreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let current = AppConfig.shared.autoInstallUpdates
            guard self.installsAutomatically != current else { return }
            self.syncingPreferences = true
            self.installsAutomatically = current
            self.syncingPreferences = false
        }
    }

    deinit {
        if let installerObserver {
            NotificationCenter.default.removeObserver(installerObserver)
        }
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
    }

    func present(_ release: UpdateChecker.Release) {
        self.release = release
        installerState = UpdateInstaller.shared.state
        userRequestedInstall = Self.installIntentApplies(
            to: release.version,
            installerState: installerState,
            explicitInstallRequested:
                UpdateInstaller.shared.explicitInstallRequested)
        syncAutomaticPreference()
    }

    /// Headless visual regression harness only; production state always comes
    /// from UpdateInstaller notifications.
    func configureSnapshot(
        installerState: UpdateInstaller.State,
        userRequestedInstall: Bool
    ) {
        self.installerState = installerState
        self.userRequestedInstall = userRequestedInstall
    }

    static func installIntentApplies(
        to releaseVersion: String,
        installerState: UpdateInstaller.State,
        explicitInstallRequested: Bool
    ) -> Bool {
        guard explicitInstallRequested else { return false }
        switch installerState {
        case .downloading(let version, _), .verifying(let version), .ready(let version):
            return version == releaseVersion
        case .installing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var currentVersion: String { VeloraAppInfo.shortVersion }

    var isUpdateAvailable: Bool {
        guard let release else { return false }
        return UpdateChecker.isNewer(release.version, than: currentVersion)
    }

    var installBlocker: String? {
        if usesInstallBlockerOverride { return installBlockerOverride }
        return UpdateInstaller.installBlocker()
    }

    var canInstallInPlace: Bool {
        guard let release, installBlocker == nil else { return false }
        if release.asset != nil { return true }
        if case .ready(let version) = installerState {
            return version == release.version
        }
        return false
    }

    var installUnavailableReason: String? {
        guard isUpdateAvailable else { return nil }
        if release?.asset == nil {
            return "This release does not include a Velora DMG — install it from the releases page"
        }
        return installBlocker
    }

    var canDefer: Bool {
        guard let release, isUpdateAvailable, !userRequestedInstall else {
            return false
        }
        switch installerState {
        case .idle, .ready, .failed:
            return true
        case .downloading(let version, _), .verifying(let version):
            return version == release.version
        case .installing:
            return false
        }
    }

    var primaryAction: PrimaryAction {
        Self.primaryAction(
            releaseVersion: release?.version,
            isUpdateAvailable: isUpdateAvailable,
            canInstallInPlace: canInstallInPlace,
            installerState: installerState,
            userRequestedInstall: userRequestedInstall)
    }

    static func primaryAction(
        releaseVersion: String?,
        isUpdateAvailable: Bool,
        canInstallInPlace: Bool,
        installerState: UpdateInstaller.State,
        userRequestedInstall: Bool
    ) -> PrimaryAction {
        guard isUpdateAvailable else {
            return PrimaryAction(title: "Done", disabled: false)
        }
        guard canInstallInPlace else {
            return PrimaryAction(title: "Open Releases Page", disabled: false)
        }
        switch installerState {
        case .idle:
            return PrimaryAction(title: "Install Update", disabled: false)
        case .ready:
            return userRequestedInstall
                ? PrimaryAction(title: "Waiting to Install…", disabled: true)
                : PrimaryAction(title: "Install Update", disabled: false)
        case .downloading(let activeVersion, _), .verifying(let activeVersion):
            guard activeVersion == releaseVersion else {
                return PrimaryAction(
                    title: "Finishing Velora \(activeVersion)…", disabled: true)
            }
            return userRequestedInstall
                ? PrimaryAction(title: "Installing…", disabled: true)
                : PrimaryAction(title: "Install Update", disabled: false)
        case .installing:
            return PrimaryAction(title: "Installing…", disabled: true)
        case .failed:
            return PrimaryAction(title: "Try Again", disabled: false)
        }
    }

    func install() {
        guard let release else { return }
        guard isUpdateAvailable else {
            onDismiss?()
            return
        }
        guard canInstallInPlace else {
            NSWorkspace.shared.open(release.page)
            return
        }
        UpdateInstaller.shared.beginAndInstall(release)
        switch UpdateInstaller.shared.state {
        case .downloading(let version, _), .verifying(let version), .ready(let version):
            userRequestedInstall = version == release.version
        case .installing:
            userRequestedInstall = true
        case .idle, .failed:
            userRequestedInstall = false
        }
    }

    func cancelDownload() {
        UpdateInstaller.shared.cancelDownload()
        userRequestedInstall = false
    }

    func cancelPendingInstall() {
        UpdateInstaller.shared.cancelPendingInstall()
        userRequestedInstall = false
    }

    func skip() {
        guard let release, canDefer else { return }
        let config = AppConfig.shared
        config.skippedUpdateVersion = release.version
        if config.deferredUpdateVersion == release.version {
            config.deferredUpdateVersion = nil
            config.deferredUpdateUntil = .distantPast
        }
        UpdateInstaller.shared.suppressAutomaticAttempt(for: release.version)
        onDismiss?()
    }

    func remindLater() {
        guard let release, canDefer else { return }
        deferPrompt(for: release.version)
        onDismiss?()
    }

    func deferAfterWindowClose() {
        guard let release, isUpdateAvailable, !userRequestedInstall else { return }
        deferPrompt(for: release.version)
    }

    func openReleasePage() {
        guard let release else { return }
        NSWorkspace.shared.open(release.page)
    }

    private func deferPrompt(for version: String) {
        let config = AppConfig.shared
        var skippedVersion = config.skippedUpdateVersion
        var deferredVersion = config.deferredUpdateVersion
        var deferredUntil = config.deferredUpdateUntil
        UpdatePromptPolicy.setReminder(
            for: version,
            skippedVersion: &skippedVersion,
            deferredVersion: &deferredVersion,
            deferredUntil: &deferredUntil)
        if skippedVersion != config.skippedUpdateVersion {
            config.skippedUpdateVersion = skippedVersion
        }
        config.deferredUpdateVersion = deferredVersion
        config.deferredUpdateUntil = deferredUntil
        UpdateInstaller.shared.suppressAutomaticAttempt(for: version)
    }

    private func syncAutomaticPreference() {
        let current = AppConfig.shared.autoInstallUpdates
        guard installsAutomatically != current else { return }
        syncingPreferences = true
        installsAutomatically = current
        syncingPreferences = false
    }
}

/// Internal so the headless snapshot harness renders the production surface.
struct UpdateWindowView: View {
    @ObservedObject var model: UpdateWindowModel

    var body: some View {
        Group {
            if let release = model.release {
                content(for: release)
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func content(for release: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: VeloraSpacing.l) {
                Image(nsImage: VeloraAppInfo.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.18), radius: 7, y: 3)

                VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                    Text(model.isUpdateAvailable
                         ? "A new version of Velora is available"
                         : "What’s new in Velora \(release.version)")
                        .font(.title2.weight(.semibold))
                    Text(model.isUpdateAvailable
                         ? "Velora \(release.version) is available — you have \(model.currentVersion)."
                         : "You’re using the latest version.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    if let publishedAt = release.publishedAt {
                        Text("Released \(publishedAt.formatted(date: .long, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, VeloraSpacing.xl)
            .padding(.top, VeloraSpacing.xl)
            .padding(.bottom, VeloraSpacing.l)

            VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                HStack {
                    Text("Release Notes")
                        .font(.headline)
                    Spacer()
                    Button("View on GitHub") { model.openReleasePage() }
                        .buttonStyle(.link)
                }

                ScrollView {
                    ReleaseNotesContentView(notes: release.notes)
                        .padding(VeloraSpacing.m)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor))
                }
            }
            .padding(.horizontal, VeloraSpacing.xl)
            .frame(maxHeight: .infinity)

            Divider()
                .padding(.top, VeloraSpacing.l)

            VStack(alignment: .leading, spacing: VeloraSpacing.m) {
                installerStatus

                if model.isUpdateAvailable {
                    Toggle(
                        "Automatically download and install updates in the future",
                        isOn: $model.installsAutomatically)
                }

                HStack(spacing: VeloraSpacing.m) {
                    if model.canDefer {
                        Button("Skip This Version") { model.skip() }
                    } else if case .downloading = model.installerState {
                        Button("Cancel Download") { model.cancelDownload() }
                    } else if model.userRequestedInstall {
                        switch model.installerState {
                        case .verifying, .ready:
                            Button("Cancel Install") { model.cancelPendingInstall() }
                        case .idle, .downloading, .installing, .failed:
                            EmptyView()
                        }
                    }
                    Spacer()
                    if model.canDefer {
                        Button("Remind Me Later") { model.remindLater() }
                    }
                    Button(model.primaryAction.title) { model.install() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.primaryAction.disabled)
                }
            }
            .padding(.horizontal, VeloraSpacing.xl)
            .padding(.vertical, VeloraSpacing.l)
        }
    }

    @ViewBuilder
    private var installerStatus: some View {
        switch model.installerState {
        case .idle:
            if let reason = model.installUnavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case .downloading(let version, let progress):
            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                ProgressView(value: progress)
                Text("Downloading Velora \(version) — \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .verifying(let version):
            HStack(spacing: VeloraSpacing.s) {
                ProgressView().controlSize(.small)
                Text("Verifying Velora \(version)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready(let version):
            Label(model.userRequestedInstall
                  ? "Velora \(version) is ready and will restart when current work finishes."
                  : "Velora \(version) is downloaded, verified, and ready to install.",
                  systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .installing:
            HStack(spacing: VeloraSpacing.s) {
                ProgressView().controlSize(.small)
                Text("Installing and restarting Velora…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

}

/// Shared by the dedicated update window and Settings' inline changelog.
struct ReleaseNotesContentView: View {
    private let blocks: [Block]

    init(notes: String) {
        blocks = Self.cachedBlocks(notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Self.inertInlineMarkdown(text))
                        .font(level == 1 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, level == 1 ? VeloraSpacing.xs : 0)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: VeloraSpacing.s) {
                        Text("•")
                        Text(Self.inertInlineMarkdown(text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, VeloraSpacing.s)
                case .numbered(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: VeloraSpacing.s) {
                        Text(marker)
                            .foregroundStyle(.secondary)
                        Text(Self.inertInlineMarkdown(text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, VeloraSpacing.s)
                case .quote(let text):
                    Text(Self.inertInlineMarkdown(text))
                        .foregroundStyle(.secondary)
                        .padding(.leading, VeloraSpacing.m)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(width: 3)
                        }
                case .code(let text):
                    Text(text)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(VeloraSpacing.s)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                case .paragraph(let text):
                    Text(Self.inertInlineMarkdown(text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .divider:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(String)
        case numbered(marker: String, text: String)
        case quote(String)
        case code(String)
        case paragraph(String)
        case divider
    }

    private final class ParsedNotes: NSObject {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }

    private static let parsedNotesCache: NSCache<NSString, ParsedNotes> = {
        let cache = NSCache<NSString, ParsedNotes>()
        cache.countLimit = 8
        cache.totalCostLimit = 2 * UpdateChecker.maximumReleaseNotesBytes
        return cache
    }()

    private static func cachedBlocks(_ notes: String) -> [Block] {
        let key = notes as NSString
        if let cached = parsedNotesCache.object(forKey: key) {
            return cached.blocks
        }
        let blocks = parseBlocks(notes)
        parsedNotesCache.setObject(
            ParsedNotes(blocks), forKey: key, cost: notes.utf8.count)
        return blocks
    }

    /// GitHub release bodies are block Markdown. `Text(AttributedString)` keeps
    /// inline emphasis but discards block layout, joining headings and bullets
    /// together. This deliberately small inert parser restores the common
    /// release-note blocks without evaluating HTML or scripts.
    private static func parseBlocks(_ notes: String) -> [Block] {
        let lines = notes.components(separatedBy: .newlines)
        var result: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var insideCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            result.append(.code(codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph()
                if insideCode { flushCode() }
                insideCode.toggle()
                continue
            }
            if insideCode {
                codeLines.append(raw)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line == "---" || line == "***" {
                flushParagraph()
                result.append(.divider)
                continue
            }
            if line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" }).count
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    flushParagraph()
                    result.append(.heading(level: min(hashes, 3), text: text))
                    continue
                }
            }
            if let text = listItem(in: line) {
                flushParagraph()
                result.append(.bullet(text))
                continue
            }
            if let numbered = numberedItem(in: line) {
                flushParagraph()
                result.append(.numbered(marker: numbered.marker, text: numbered.text))
                continue
            }
            if line.hasPrefix("> ") {
                flushParagraph()
                result.append(.quote(String(line.dropFirst(2))))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        flushCode()
        return result.isEmpty ? [.paragraph(notes)] : result
    }

    private static func listItem(in line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func numberedItem(in line: String) -> (marker: String, text: String)? {
        guard let period = line.firstIndex(of: "."),
              period != line.startIndex,
              line[..<period].allSatisfy(\.isNumber)
        else { return nil }
        let afterPeriod = line.index(after: period)
        guard afterPeriod < line.endIndex, line[afterPeriod] == " " else { return nil }
        let marker = String(line[...period])
        let text = String(line[line.index(after: afterPeriod)...])
        return text.isEmpty ? nil : (marker, text)
    }

    static func inertInlineMarkdown(_ source: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(source) }
        // Keep emphasis/code styling, but release-body links are plain labels.
        // The only trusted navigation target in this window is the separately
        // validated GitHub release-page button.
        for run in attributed.runs where run.link != nil {
            attributed[run.range].link = nil
        }
        return attributed
    }
}
