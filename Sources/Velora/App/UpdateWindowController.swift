import AppKit
import Combine
import SwiftUI

/// When a daily check may open the update window, and which releases the
/// automatic install path may touch. Both decisions are scoped to the exact
/// version, so a newer release never inherits a choice made about an older
/// one.
///
///     daily check finds 1.2.3
///        │
///        ├─ skipped 1.2.3? ──────────▶ stay quiet, stage nothing
///        ├─ prompted 1.2.3 < 24 h ago ▶ stay quiet (staging still allowed)
///        └─ otherwise ───────────────▶ open the window, stamp the prompt
///
/// Storage reuses `AppConfig.deferredUpdateVersion` / `deferredUpdateUntil`:
/// the version last prompted and the moment the next automatic prompt for it
/// is allowed.
enum UpdatePromptPolicy {
    /// An automatic prompt for one version repeats at most this often.
    /// Same as the checker's cadence: a 24 h prompt gate over a 20 h check
    /// gate lands the next check just short of the gate and skips a day.
    static let promptInterval: TimeInterval = UpdateChecker.checkInterval

    static func shouldPrompt(
        version: String,
        skippedVersion: String?,
        promptedVersion: String?,
        promptedUntil: Date,
        now: Date = Date()
    ) -> Bool {
        if skippedVersion == version {
            return false
        }
        if promptedVersion != version {
            return true
        }
        return now >= promptedUntil
    }

    /// Background staging, launch adoption, and quit-time install proceed for
    /// every release except a skipped one. Closing the window is not a
    /// decision about the bytes.
    static func allowsAutomaticInstall(
        version: String, skippedVersion: String?
    ) -> Bool {
        skippedVersion != version
    }

    // MARK: Persistence — every mutation of the machine-local prompt state
    // lives here. The disposable-copy E2E shares the production defaults
    // domain, so a local feed must never write real Skip decisions.

    static func markPrompted(_ version: String, now: Date = Date()) {
        guard UpdateChecker.persistentStateAllowed else { return }
        let config = AppConfig.shared
        config.deferredUpdateVersion = version
        config.deferredUpdateUntil = now.addingTimeInterval(promptInterval)
    }

    static func skip(_ version: String) {
        guard UpdateChecker.persistentStateAllowed else { return }
        AppConfig.shared.skippedUpdateVersion = version
    }

    /// An explicit install of a skipped release un-skips it, so the menubar
    /// and quit-time paths agree with what the user just asked for.
    static func clearSkip(of version: String) {
        guard UpdateChecker.persistentStateAllowed,
              AppConfig.shared.skippedUpdateVersion == version
        else { return }
        AppConfig.shared.skippedUpdateVersion = nil
    }
}

/// One reusable window for a newer release, opened by a daily check, a
/// manual check, the menubar, or Settings. A daily check surfaces it without
/// activating the app; every explicit path brings it to the front.
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    static let shared = UpdateWindowController()

    static let contentSize = NSSize(width: 640, height: 580)
    private static let minimumSize = NSSize(width: 560, height: 480)

    private let model = UpdateWindowModel()
    private var holdsActivation = false

    private init() {
        let root = UpdateWindowView(model: model)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        // Same chrome as the main and Settings windows: hidden title, traffic
        // lights over the canvas, so the updater is not a third design.
        MainWindowController.applyShellChrome(to: window, title: "Velora Update")
        window.setContentSize(Self.contentSize)
        window.contentMinSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()

        super.init(window: window)
        window.delegate = self
        model.onDismiss = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Manual checks and explicit menu/Settings actions activate the window.
    func show(_ release: UpdateChecker.Release) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard present(release) else { return }
        MainWindowController.presentShell(self, holding: &holdsActivation)
    }

    /// A daily check surfaces the window at most once a day per version and
    /// never for a skipped one, without stealing keyboard focus.
    func showAutomatically(_ release: UpdateChecker.Release) {
        dispatchPrecondition(condition: .onQueue(.main))
        let config = AppConfig.shared
        guard UpdatePromptPolicy.shouldPrompt(
            version: release.version,
            skippedVersion: config.skippedUpdateVersion,
            promptedVersion: config.deferredUpdateVersion,
            promptedUntil: config.deferredUpdateUntil)
        else { return }
        guard present(release) else { return }
        UpdatePromptPolicy.markPrompted(release.version)
        window?.orderFrontRegardless()
    }

    /// Loads the release into the window and holds regular activation while
    /// it is open. False when the release is not newer than the running app.
    private func present(_ release: UpdateChecker.Release) -> Bool {
        guard Self.shouldPresent(
            releaseVersion: release.version,
            currentVersion: VeloraAppInfo.shortVersion)
        else { return false }
        model.present(release)
        if !holdsActivation {
            holdsActivation = true
            AppActivation.acquireRegular()
        }
        return true
    }

    static func shouldPresent(
        releaseVersion: String,
        currentVersion: String
    ) -> Bool {
        UpdateChecker.isNewer(releaseVersion, than: currentVersion)
    }

    /// Closing the window decides nothing: a staged update stays staged and
    /// the daily prompt returns tomorrow unless the user skipped the version.
    func windowWillClose(_ notification: Notification) {
        if holdsActivation {
            holdsActivation = false
            AppActivation.releaseRegular()
        }
    }
}

final class UpdateWindowModel: ObservableObject {
    struct PrimaryAction: Equatable {
        let title: String
        let disabled: Bool
    }

    /// Fixed installer facts for the headless snapshot renderer, which has no
    /// live installer to observe.
    struct Preview {
        let installerState: UpdateInstaller.State
        let installsWhenReady: Bool
        let installBlocker: String?
    }

    @Published private(set) var release: UpdateChecker.Release?
    @Published private(set) var installerState: UpdateInstaller.State
    @Published private(set) var installsWhenReady: Bool

    var onDismiss: (() -> Void)?

    private let preview: Preview?
    private var installerObserver: NSObjectProtocol?

    init(preview: Preview? = nil) {
        self.preview = preview
        installerState = preview?.installerState ?? UpdateInstaller.shared.state
        installsWhenReady = preview?.installsWhenReady
            ?? UpdateInstaller.shared.installsWhenReady
        guard preview == nil else { return }
        installerObserver = NotificationCenter.default.addObserver(
            forName: .veloraUpdateStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let installerObserver {
            NotificationCenter.default.removeObserver(installerObserver)
        }
    }

    func present(_ release: UpdateChecker.Release) {
        self.release = release
        refresh()
    }

    /// Mirrors the installer. The window has no state of its own about the
    /// install: one flag on the installer serves the window, Settings, and
    /// the menubar alike.
    private func refresh() {
        guard preview == nil else { return }
        let installer = UpdateInstaller.shared
        installerState = installer.state
        installsWhenReady = Self.installsWhenReady(
            installer.installsWhenReady, state: installer.state, releaseVersion: release?.version)
    }

    /// The installer's one intent flag, narrowed to the release this window
    /// shows: a pending install of 1.2.3 must not disable Install and Skip
    /// for 1.2.4. An installing state has no version and always counts.
    static func installsWhenReady(
        _ installsWhenReady: Bool, state: UpdateInstaller.State, releaseVersion: String?
    ) -> Bool {
        guard installsWhenReady else { return false }
        guard let active = state.version else { return true }
        return active == releaseVersion
    }

    var currentVersion: String { VeloraAppInfo.shortVersion }

    var isUpdateAvailable: Bool {
        guard let release else { return false }
        return UpdateChecker.isNewer(release.version, than: currentVersion)
    }

    private var installBlocker: String? {
        if let preview { return preview.installBlocker }
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

    /// Skip is offered until the user commits to an install.
    var canSkip: Bool {
        guard isUpdateAvailable, !installsWhenReady else { return false }
        if case .installing = installerState { return false }
        return true
    }

    /// A committed install can be withdrawn until the swap helper spawns.
    var canCancelInstall: Bool {
        guard installsWhenReady else { return false }
        switch installerState {
        case .downloading, .verifying, .ready:
            return true
        case .idle, .installing, .failed:
            return false
        }
    }

    var primaryAction: PrimaryAction {
        Self.primaryAction(
            releaseVersion: release?.version,
            isUpdateAvailable: isUpdateAvailable,
            canInstallInPlace: canInstallInPlace,
            installerState: installerState,
            installsWhenReady: installsWhenReady)
    }

    static func primaryAction(
        releaseVersion: String?,
        isUpdateAvailable: Bool,
        canInstallInPlace: Bool,
        installerState: UpdateInstaller.State,
        installsWhenReady: Bool
    ) -> PrimaryAction {
        guard isUpdateAvailable else {
            return PrimaryAction(title: "Done", disabled: false)
        }
        guard canInstallInPlace else {
            return PrimaryAction(title: UpdateCopy.releasesPageTitle, disabled: false)
        }
        switch installerState {
        case .idle:
            return PrimaryAction(title: UpdateCopy.installTitle, disabled: false)
        case .ready(let activeVersion) where activeVersion != releaseVersion:
            // Another release is staged; this one is a fresh install.
            return PrimaryAction(title: UpdateCopy.installTitle, disabled: false)
        case .ready:
            if installsWhenReady {
                return PrimaryAction(title: UpdateCopy.waitingTitle, disabled: true)
            }
            return PrimaryAction(title: UpdateCopy.restartTitle, disabled: false)
        case .downloading(let activeVersion, _), .verifying(let activeVersion):
            guard activeVersion == releaseVersion else {
                return PrimaryAction(
                    title: "Finishing Velora \(activeVersion)…", disabled: true)
            }
            if installsWhenReady {
                return PrimaryAction(title: UpdateCopy.installingTitle, disabled: true)
            }
            return PrimaryAction(title: UpdateCopy.installTitle, disabled: false)
        case .installing:
            return PrimaryAction(title: UpdateCopy.installingTitle, disabled: true)
        case .failed:
            return PrimaryAction(title: UpdateCopy.tryAgainTitle, disabled: false)
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
        refresh()
    }

    func cancelInstall() {
        UpdateInstaller.shared.cancelPendingInstall()
        refresh()
    }

    /// Skip hides this exact version from daily prompts and stops any
    /// background work on it. The next release prompts again.
    func skip() {
        guard let release, canSkip else { return }
        UpdatePromptPolicy.skip(release.version)
        UpdateInstaller.shared.abandon(version: release.version)
        onDismiss?()
    }

    func dismiss() {
        onDismiss?()
    }

    func openReleasePage() {
        guard let release else { return }
        NSWorkspace.shared.open(release.page)
    }
}

/// Internal so the headless snapshot harness renders the production surface.
///
///     ┌────────────────────────────────────────────┐
///     │ ●●●                                        │
///     │  [icon]  Velora 1.2.3 is available.        │  serif headline
///     │          You have 1.2.2 · Released 8 Sep   │
///     │  WHAT'S NEW                View on GitHub  │
///     │  ┌──────────────────────────────────────┐  │
///     │  │ release notes (scrolls)              │  │  card
///     │  └──────────────────────────────────────┘  │
///     │  ▸ status caption / progress               │
///     │  [Skip This Version]     [Not Now] [Install]│  capsules
///     └────────────────────────────────────────────┘
struct UpdateWindowView: View {
    @ObservedObject var model: UpdateWindowModel

    /// Clears the traffic lights, which sit over the canvas under
    /// `.fullSizeContentView`.
    private static let headerTop: CGFloat = 44
    private static let iconSide: CGFloat = 64
    private static let sectionLabelSize: CGFloat = 11.5

    var body: some View {
        ZStack {
            VeloraPanel.canvas
            WindowGlow()
            if let release = model.release {
                content(for: release)
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private func content(for release: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.l) {
            header(for: release)
            notes(for: release)
            footer
        }
        .padding(.horizontal, VeloraSpacing.xl + VeloraSpacing.xs)
        .padding(.top, Self.headerTop)
        .padding(.bottom, VeloraSpacing.xl)
    }

    private func header(for release: UpdateChecker.Release) -> some View {
        HStack(alignment: .top, spacing: VeloraSpacing.l) {
            Image(nsImage: VeloraAppInfo.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSide, height: Self.iconSide)
                .shadow(color: .black.opacity(0.18), radius: 7, y: 3)

            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                SerifHeadline("Velora \(release.version) is available")
                Text(Self.subtitle(current: model.currentVersion, publishedAt: release.publishedAt))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "You have 1.2.2 · Released 8 September 2026"; the date drops out when
    /// the feed carried none.
    static func subtitle(current: String, publishedAt: Date?) -> String {
        guard let publishedAt else { return "You have \(current)" }
        return "You have \(current) · Released \(publishedAt.formatted(date: .long, time: .omitted))"
    }

    private func notes(for release: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            HStack {
                Text("What’s new")
                    .textCase(.uppercase)
                    .font(.system(size: Self.sectionLabelSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("View on GitHub") { model.openReleasePage() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, VeloraSpacing.xs)

            ScrollView {
                ReleaseNotesContentView(notes: release.notes)
                    .padding(VeloraSpacing.l)
            }
            .background(
                RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                    .fill(VeloraPanel.card))
            .overlay(
                RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                    .strokeBorder(VeloraPanel.hairline, lineWidth: 1))
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            installerStatus

            HStack(spacing: VeloraSpacing.s) {
                if model.canSkip {
                    Button(UpdateCopy.skipTitle) { model.skip() }
                        .buttonStyle(.capsule)
                } else if model.canCancelInstall {
                    Button(UpdateCopy.cancelInstallTitle) { model.cancelInstall() }
                        .buttonStyle(.capsule)
                }
                Spacer()
                if model.isUpdateAvailable {
                    Button(model.installsWhenReady ? "Close" : UpdateCopy.notNowTitle) {
                        model.dismiss()
                    }
                    .buttonStyle(.capsule)
                    .keyboardShortcut(.cancelAction)
                }
                Button(model.primaryAction.title) { model.install() }
                    .buttonStyle(.primaryCapsule)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.primaryAction.disabled)
            }
        }
    }

    /// One caption line from the shared vocabulary; downloads add a bar and
    /// blockers turn the line into a warning.
    @ViewBuilder
    private var installerStatus: some View {
        switch model.installerState {
        case .idle:
            if let reason = model.installUnavailableReason {
                warning(reason)
            }
        case .downloading(_, let progress):
            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                ProgressView(value: progress)
                caption(UpdateCopy.caption(
                    for: model.installerState, installsWhenReady: model.installsWhenReady))
            }
        case .verifying, .installing:
            HStack(spacing: VeloraSpacing.s) {
                ProgressView().controlSize(.small)
                caption(UpdateCopy.caption(
                    for: model.installerState, installsWhenReady: model.installsWhenReady))
            }
        case .ready:
            Label {
                caption(UpdateCopy.caption(
                    for: model.installerState, installsWhenReady: model.installsWhenReady))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(VeloraBrand.accent)
            }
        case .failed(let reason):
            warning(reason)
        }
    }

    private func caption(_ text: String?) -> some View {
        Text(text ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(VeloraStatus.warning)
            .textSelection(.enabled)
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
                            in: RoundedRectangle(cornerRadius: VeloraRadius.control))
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
