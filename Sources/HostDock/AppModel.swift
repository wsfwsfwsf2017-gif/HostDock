import AppKit
import Combine
import Foundation
import HostDockCore

enum ConnectionPickerTab: String, CaseIterable {
    case saved = "已保存", recent = "最近连接", new = "新建连接"
}

enum ConnectionPickerSelection: Hashable {
    case saved(UUID?), recent(String?), new
    var tab: ConnectionPickerTab {
        switch self { case .saved: return .saved; case .recent: return .recent; case .new: return .new }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let catalog: ConnectionCatalog
    private let credentials: any CredentialStore
    private let makeConnection: () -> any SessionConnection
    private let preferences: UserDefaults
    @Published var appearance: AppAppearance {
        didSet {
            preferences.set(appearance.rawValue, forKey: AppAppearance.preferenceKey)
            NSApplication.shared.appearance = appearance.nsAppearance
        }
    }
    let editors: RemoteEditors
    let reservations = TransferReservations()
    lazy var automation = AutomationController(app: self)
    @Published private(set) var sessions: [SessionModel] = []
    @Published private(set) var backgroundSessions: [SessionModel] = []
    var allSessions: [SessionModel] { sessions + backgroundSessions }
    @Published var workspace = WorkspaceArrangement()
    @Published var selectedSessionID: UUID? {
        didSet {
            if let id = selectedSessionID, let index = workspace.slots.prefix(workspace.layout.rawValue).firstIndex(of: id) { workspace.focus(index) }
        }
    }
    @Published var pickerEditing = false
    @Published var pickerAuthenticating = false
    @Published var closingSessionID: UUID?
    @Published var closeAllConfirmationPresented = false
    @Published private(set) var closingTabs = false
    @Published var workspaceNotice: String?
    @Published var pickerSelection: ConnectionPickerSelection
    @Published var connectionPickerPresented = false {
        didSet { if oldValue && !connectionPickerPresented { cancelPickerAttempts() } }
    }
    @Published private(set) var pickerCancelling = false
    @Published private(set) var pickerSessionID: UUID?
    @Published private(set) var newProfile = ConnectionProfile(name: "", endpoint: ConnectionEndpoint(host: "", port: 22, username: ""))
    @Published private(set) var newAccessProfile: JumpServerAccessProfile?
    @Published private(set) var updatingRecords = false
    @Published private(set) var shuttingDown = false
    @Published private(set) var maximizeRequest = 0
    @Published private(set) var readyProfileIDs: Set<UUID> = []
    @Published private(set) var accessValidationSession: SessionModel?
    private var observations: [UUID: AnyCancellable] = [:]
    private var recentDrafts: [String: ConnectionProfile] = [:]
    private var pickerConnectionSelection: ConnectionPickerSelection?
    private var pickerReconnectID: UUID?
    // true 表示弹窗新建的运行项，取消时移除；已有断开会话则保留。
    private var pickerAttempts: [UUID: Bool] = [:]
    private var pickerCleanupTask: Task<Void, Never>?
    private var credentialRefresh = UUID()
    private var credentialRefreshTask: Task<Void, Never>?
    private var closeAllSelection: [SessionModel]?
    private var closeAllTask: Task<Void, Never>?

    init(catalog: ConnectionCatalog? = nil, credentials: any CredentialStore = EncryptedFileCredentialStore(),
         preferences: UserDefaults = .standard,
         editors: RemoteEditors? = nil,
         makeConnection: @escaping () -> any SessionConnection = { LiveSessionConnection() }) {
        let catalog = catalog ?? ConnectionCatalog()
        self.catalog = catalog
        self.credentials = credentials
        self.makeConnection = makeConnection
        self.preferences = preferences
        appearance = AppAppearance(rawValue: preferences.string(forKey: AppAppearance.preferenceKey) ?? "") ?? .system
        self.editors = editors ?? .shared
        pickerSelection = .new
        Task { await refreshSavedConnections() }
    }

    var savedProfiles: [ConnectionProfile] { catalog.profiles.filter { readyProfileIDs.contains($0.id) } }
    var pendingProfiles: [ConnectionProfile] { catalog.profiles.filter { !readyProfileIDs.contains($0.id) } }
    var preferredAccessProfile: JumpServerAccessProfile? {
        catalog.accessProfiles.first { $0.id.uuidString == preferences.string(forKey: "HostDock.PreferredJumpServerAccess") } ?? catalog.accessProfiles.first
    }
    func rememberAccessSelection(_ access: JumpServerAccessProfile) {
        if catalog.accessProfiles.contains(where: { $0.id == access.id }) { preferences.set(access.id.uuidString, forKey: "HostDock.PreferredJumpServerAccess") }
    }

    func refreshSavedConnections() async {
        let previous = credentialRefreshTask
        let refresh = UUID()
        credentialRefresh = refresh
        let task = Task { @MainActor [self] in
            await previous?.value
            var ready: Set<UUID> = []
            for var profile in catalog.profiles {
                guard let resolved = try? catalog.resolve(profile) else { continue }
                var secret: String?
                for account in catalog.authenticationAccounts(profile: resolved.profile, access: resolved.access) {
                    if let saved = try? await credentials.read(account: account) { secret = saved; break }
                }
                guard catalog.profiles.first(where: { $0.id == profile.id }) == profile else { continue }
                let authentication = resolved.profile
                let usable = profile.rememberPassword && (authentication.authenticationKind == .password ? secret != nil
                    : FileManager.default.isReadableFile(atPath: ((authentication.privateKeyPath ?? "") as NSString).expandingTildeInPath)
                        && (!authentication.keyRequiresPassphrase || secret != nil))
                guard usable else { continue }
                if profile.lastValidatedAt == nil,
                   let recent = catalog.recent.first(where: { $0.endpoint == profile.endpoint }) {
                    profile.lastValidatedAt = recent.lastConnected
                    try? catalog.save(profile)
                }
                if profile.lastValidatedAt != nil { ready.insert(profile.id) }
            }
            readyProfileIDs = ready
        }
        credentialRefreshTask = task
        await task.value
        if credentialRefresh == refresh { credentialRefreshTask = nil }
    }

    func useDraft(_ profile: ConnectionProfile, accessProfile: JumpServerAccessProfile? = nil) {
        guard !pickerBusy else { return }
        newProfile = profile
        newAccessProfile = accessProfile
        pickerSelection = .new
    }

    var selectedSession: SessionModel? { sessions.first { $0.id == selectedSessionID } }
    var pickerProfile: ConnectionProfile? {
        switch pickerSelection {
        case .saved(let id): return catalog.profiles.first { $0.id == id }
        case .recent(let id):
            guard let recent = catalog.recent.first(where: { $0.id == id }) else { return nil }
            if let saved = catalog.profile(for: recent.endpoint) { return saved }
            if let draft = recentDrafts[recent.id] { return draft }
            let draft = recent.draft()
            recentDrafts[recent.id] = draft
            return draft
        case .new: return newProfile
        }
    }
    var pickerSession: SessionModel? {
        if pickerConnectionSelection == pickerSelection, let id = pickerSessionID {
            return sessions.first { $0.id == id }
        }
        return sessions.first { $0.id == pickerReconnectID }
    }
    var pickerBusy: Bool { pickerCancelling || updatingRecords || pickerSession?.connecting == true || pickerSession?.disconnecting == true }
    var hasTransfers: Bool { allSessions.contains { $0.transferring } }
    func isActive(_ profile: ConnectionProfile) -> Bool {
        allSessions.contains { $0.profile.id == profile.id && ($0.connected || $0.busy) }
    }

    func showConnections() {
        guard !shuttingDown, !closingTabs, !closeAllConfirmationPresented, !pickerCancelling, !connectionPickerPresented else { return }
        newProfile = ConnectionProfile(name: "", endpoint: ConnectionEndpoint(host: "", port: 22, username: ""))
        newAccessProfile = nil
        pickerReconnectID = nil
        pickerSelection = .new
        pickerEditing = false
        pickerAuthenticating = false
        connectionPickerPresented = true
    }

    func showConnection(_ session: SessionModel, authenticating: Bool = false) {
        guard !shuttingDown, !closingTabs, !closeAllConfirmationPresented, !pickerCancelling else { return }
        if readyProfileIDs.contains(session.profile.id) { pickerSelection = .saved(session.profile.id) }
        else { useDraft(session.profile) }
        pickerReconnectID = session.id
        pickerEditing = false
        pickerAuthenticating = authenticating
        connectionPickerPresented = true
    }

    func canReconnect(_ session: SessionModel) -> Bool {
        session.origin == .interactive && sessions.contains(where: { $0 === session }) && !session.connected && !session.busy
            && !shuttingDown && !closingTabs && !closeAllConfirmationPresented && !updatingRecords && !pickerCancelling && !connectionPickerPresented
    }

    func reconnect(_ session: SessionModel) {
        guard canReconnect(session) else { return }
        do {
            let profile = catalog.profiles.first { $0.id == session.profile.id } ?? session.profile
            try connect(profile: profile, password: nil, rememberPassword: profile.rememberPassword, reusing: session)
        } catch { session.connectionError = error.localizedDescription }
    }

    func showProfile(_ profile: ConnectionProfile, editing: Bool = false, authenticating: Bool = false) {
        guard !shuttingDown, !closingTabs, !closeAllConfirmationPresented, !pickerBusy else { return }
        if catalog.profiles.contains(where: { $0.id == profile.id }) { pickerSelection = .saved(profile.id) }
        else { useDraft(profile) }
        pickerReconnectID = nil
        pickerEditing = editing
        pickerAuthenticating = authenticating
        connectionPickerPresented = true
    }

    func openProfile(_ profile: ConnectionProfile) throws {
        if readyProfileIDs.contains(profile.id) { _ = try connect(profile: profile, password: nil, rememberPassword: true) }
        else { showProfile(profile) }
    }

    func setLayout(_ layout: WorkspaceLayout) {
        workspace.setLayout(layout, tabs: sessions.map(\.id))
        selectedSessionID = workspace.slots[workspace.activeSlot]
    }

    func selectTab(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        workspace.select(id)
        selectedSessionID = id
    }

    func focusPane(_ index: Int) {
        guard (0..<workspace.layout.rawValue).contains(index) else { return }
        workspace.focus(index)
        selectedSessionID = workspace.slots[index]
    }

    func removeFromSplit(_ index: Int) {
        guard workspace.layout != .single, (0..<workspace.layout.rawValue).contains(index) else { return }
        workspace.clear(index)
        selectedSessionID = nil
    }

    func tabTitle(_ session: SessionModel) -> String {
        let siblings = sessions.filter { $0.profile.name == session.profile.name }
        guard siblings.count > 1, let index = siblings.firstIndex(where: { $0.id == session.id }) else { return session.profile.name }
        return "\(session.profile.name) · \(index + 1)"
    }

    func requestCloseTab(_ session: SessionModel) {
        guard session.origin == .interactive, !closingTabs, !closeAllConfirmationPresented, !shuttingDown else { return }
        if session.transferring || editors.hasUnuploadedEdits(in: session) { closingSessionID = session.id }
        else { Task { await closeTab(session) } }
    }

    func closeTab(_ session: SessionModel) async {
        guard !closingTabs else { return }
        defer { editors.finishClosing([session]) }
        do { try editors.closeEditors(in: [session]) }
        catch { workspaceNotice = "草稿未能保存，会话已保留：" + error.localizedDescription; closingSessionID = nil; return }
        await closeSession(session)
        closingSessionID = nil
    }

    var canCloseAllTabs: Bool { !sessions.isEmpty && !closingTabs && !shuttingDown && !connectionPickerPresented && !pickerCancelling && closingSessionID == nil }

    func requestCloseAllTabs() {
        guard canCloseAllTabs, !closeAllConfirmationPresented else { return }
        let targets = sessions
        if targets.contains(where: { $0.transferring || editors.hasUnuploadedEdits(in: $0) }) {
            closeAllSelection = targets
            closeAllConfirmationPresented = true
        } else { _ = startClosingTabs(targets) }
    }

    func cancelCloseAllTabs() { closeAllSelection = nil; closeAllConfirmationPresented = false }

    func closeAllTabs() async {
        if let closeAllTask { await closeAllTask.value; return }
        guard canCloseAllTabs else { return }
        let targets = closeAllSelection ?? sessions
        closeAllSelection = nil; closeAllConfirmationPresented = false
        await startClosingTabs(targets).value
    }

    private func startClosingTabs(_ targets: [SessionModel]) -> Task<Void, Never> {
        closeAllSelection = nil; closeAllConfirmationPresented = false
        closingTabs = true
        let task = Task { @MainActor [self] in
            defer { editors.finishClosing(targets); closingTabs = false; closeAllTask = nil }
            do { try editors.closeEditors(in: targets) }
            catch { workspaceNotice = "草稿未能保存，关闭全部已取消：" + error.localizedDescription; return }
            await withTaskGroup(of: Void.self) { group in
                for session in targets { group.addTask { await self.closeSession(session) } }
            }
        }
        closeAllTask = task
        return task
    }

    @discardableResult
    func connectBackground(profile: ConnectionProfile) throws -> SessionModel {
        guard !shuttingDown, !updatingRecords else { throw HostDockError("应用正在处理连接资料，请稍后重试。") }
        let resolved = try catalog.resolve(profile)
        _ = try catalog.validate(resolved.profile)
        let session = SessionModel(profile: resolved.profile, catalog: catalog, credentials: credentials,
                                   connection: makeConnection(), reservations: reservations, origin: .automation)
        backgroundSessions.append(session)
        observations[session.id] = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        session.connect(profile: resolved.profile, password: nil, rememberPassword: true, accessProfile: resolved.access)
        return session
    }

    func selectPickerTab(_ tab: ConnectionPickerTab) {
        guard !pickerBusy else { return }
        pickerReconnectID = nil
        switch tab {
        case .saved: pickerSelection = .saved(savedProfiles.first?.id)
        case .recent: pickerSelection = .recent(catalog.recent.first?.id)
        case .new: pickerSelection = .new
        }
    }

    @discardableResult
    func connectFromPicker(profile: ConnectionProfile, password: String?, rememberPassword: Bool, accessProfile: JumpServerAccessProfile? = nil) throws -> SessionModel {
        guard connectionPickerPresented, !pickerBusy else { throw HostDockError("正在处理连接，请稍后重试。") }
        let profile = try catalog.resolve(profile, accessProfile: accessProfile).profile
        let previous = sessions.first { $0.id == pickerReconnectID }
        let selected = selectedSessionID
        let arrangement = workspace
        let result = try connect(profile: profile, password: password, rememberPassword: rememberPassword, accessProfile: accessProfile, reusing: previous)
        if result.connected {
            connectionPickerPresented = false
        } else {
            workspace = arrangement
            selectedSessionID = selected
            pickerConnectionSelection = pickerSelection
            pickerSessionID = result.id
            pickerAttempts[result.id] = pickerAttempts[result.id] ?? (previous == nil)
        }
        return result
    }

    private func cancelPickerAttempts() {
        let attempts = pickerAttempts.compactMap { id, created in sessions.first { $0.id == id }.map { ($0, created) } }
        pickerAttempts = [:]
        pickerSessionID = nil
        pickerConnectionSelection = nil
        let unfinished = attempts.filter { !$0.0.connected }
        for (session, _) in unfinished { session.cancelConnection() }
        guard !unfinished.isEmpty else { return }
        pickerCancelling = true
        pickerCleanupTask = Task {
            for (session, created) in unfinished {
                if created { await closeSession(session) } else { await session.shutdown() }
            }
            pickerCancelling = false
            pickerCleanupTask = nil
        }
    }

    @discardableResult
    func connect(profile requested: ConnectionProfile, password: String?, rememberPassword: Bool, accessProfile: JumpServerAccessProfile? = nil, reusing previous: SessionModel? = nil) throws -> SessionModel {
        guard !shuttingDown, !closingTabs, !closeAllConfirmationPresented, !updatingRecords, !pickerCancelling else { throw HostDockError("正在处理连接，请稍后重试。") }
        if let previous {
            guard sessions.contains(where: { $0 === previous }) else { throw HostDockError("原会话已关闭，请重新打开连接。") }
            if previous.connected || previous.busy { selectTab(previous.id); return previous }
        }
        let resolved = try catalog.resolve(requested, accessProfile: accessProfile)
        var profile = resolved.profile
        if !catalog.profiles.contains(where: { $0.id == profile.id }), let saved = catalog.profile(for: profile.endpoint) {
            profile.id = saved.id
        }
        _ = try catalog.validate(profile)
        let session: SessionModel
        if let previous { session = previous }
        else {
            session = SessionModel(profile: profile, catalog: catalog, credentials: credentials,
                                   connection: makeConnection(), reservations: reservations)
            session.terminal.view.onFocus = { [weak self, weak session] in
                guard let self, let session, !self.shuttingDown, !self.closingTabs, self.selectedSessionID != session.id,
                      let index = self.workspace.slots.prefix(self.workspace.layout.rawValue).firstIndex(of: session.id),
                      self.workspace.expandedSessionID == nil || self.workspace.expandedSessionID == session.id else { return }
                self.focusPane(index)
            }
            session.terminal.view.onMount = { [weak self, weak session] in
                guard let self, let session, !self.shuttingDown, self.selectedSessionID == session.id else { return }
                focusWorkspaceSession(self, id: session.id)
            }
            session.onConnected = { [weak self] id in
                guard let self else { return }
                Task { await self.refreshSavedConnections() }
                if let access = self.catalog.accessProfiles.first(where: { $0.id == self.sessions.first(where: { $0.id == id })?.profile.jumpServer?.accessProfileID }) {
                    self.rememberAccessSelection(access)
                }
                if self.pickerAttempts.removeValue(forKey: id) != nil {
                    self.selectTab(id)
                    self.connectionPickerPresented = false
                }
                if self.selectedSessionID == id { self.maximizeRequest += 1 }
            }
            sessions.append(session)
            observations[session.id] = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }
        if previous != nil, let index = workspace.slots.prefix(workspace.layout.rawValue).firstIndex(of: session.id) { focusPane(index) }
        else { selectTab(session.id) }
        session.connect(profile: profile, password: password, rememberPassword: rememberPassword, accessProfile: resolved.access)
        return session
    }

    func hasSavedPassphrase(profile: ConnectionProfile, access: JumpServerAccessProfile) async -> Bool {
        for account in catalog.authenticationAccounts(profile: profile, access: access) {
            if (try? await credentials.read(account: account)) != nil { return true }
        }
        return false
    }

    func validateAndSaveAccess(_ access: JumpServerAccessProfile, asset: ConnectionProfile, password: String?) async throws {
        guard !updatingRecords, !shuttingDown else { throw HostDockError("正在处理连接，请稍后重试。") }
        let profile = try access.applying(to: asset)
        updatingRecords = true
        let session = SessionModel(profile: profile, catalog: catalog, credentials: credentials, connection: makeConnection(), reservations: reservations)
        accessValidationSession = session
        defer { accessValidationSession = nil; updatingRecords = false }
        session.connect(profile: profile, password: password, rememberPassword: true, accessProfile: access, validationOnly: true)
        do {
            while session.connecting {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            guard session.connected else { throw HostDockError(session.connectionError ?? "堡垒机验证未完成。") }
            await session.shutdown()
            await refreshSavedConnections()
        } catch { session.cancelConnection(); await session.shutdown(); throw error }
    }

    func saveAccessDetails(_ access: JumpServerAccessProfile) throws {
        guard !updatingRecords, !shuttingDown, let previous = catalog.accessProfiles.first(where: { $0.id == access.id }),
              previous.authenticationIdentity == access.authenticationIdentity,
              previous.rememberPassphrase == access.rememberPassphrase else { throw HostDockError("接入认证改变后需要验证并保存。") }
        try catalog.saveAccessProfile(access)
    }

    func removeAccessProfile(_ access: JumpServerAccessProfile) async throws {
        guard !updatingRecords, !shuttingDown else { throw HostDockError("正在处理连接，请稍后重试。") }
        guard !catalog.profiles.contains(where: { $0.jumpServer?.accessProfileID == access.id }),
              !catalog.recent.contains(where: { $0.jumpServer?.accessProfileID == access.id }),
              !allSessions.contains(where: { $0.profile.jumpServer?.accessProfileID == access.id && ($0.connected || $0.busy) }) else {
            throw HostDockError("堡垒机仍被服务器或历史记录使用，暂不能删除。")
        }
        updatingRecords = true; defer { updatingRecords = false }
        let old = try await credentials.read(account: access.credentialAccount)
        try await credentials.remove(account: access.credentialAccount)
        do { try catalog.removeAccessProfile(access) }
        catch { if let old { try? await credentials.save(old, account: access.credentialAccount) }; throw error }
    }

    func saveProfile(_ requested: ConnectionProfile) async throws {
        guard !updatingRecords, !shuttingDown else { throw HostDockError("正在保存，请稍后重试。") }
        var profile = try catalog.validate(requested)
        guard catalog.profiles.contains(where: { $0.id == profile.id }) else {
            throw HostDockError("新连接请先验证并保存认证。")
        }
        if isActive(profile) { throw HostDockError("请先断开这台服务器，再编辑连接记录。") }
        updatingRecords = true
        defer { updatingRecords = false }
        if let previous = catalog.profiles.first(where: { $0.id == profile.id }),
           previous.endpoint != profile.endpoint || previous.authenticationKind != profile.authenticationKind || previous.privateKeyPath != profile.privateKeyPath {
            throw HostDockError("认证或连接身份改变后，请使用验证并保存，原连接资料已保留。")
        }
        let oldSecret = !profile.rememberPassword ? try await credentials.read(account: profile.credentialAccount) : nil
        if !profile.rememberPassword {
            try await credentials.remove(account: profile.credentialAccount)
            if profile.authenticationKind == .password || profile.keyRequiresPassphrase { profile.lastValidatedAt = nil }
        }
        do { try catalog.save(profile) }
        catch {
            if let oldSecret { try? await credentials.save(oldSecret, account: profile.credentialAccount) }
            throw error
        }
        await refreshSavedConnections()
        for session in allSessions.filter({ $0.profile.id == profile.id }) { await closeSession(session) }
    }

    func removeProfile(_ profile: ConnectionProfile) async throws {
        guard !updatingRecords, !shuttingDown, !isActive(profile) else { throw HostDockError("请先断开这台服务器，再删除记录。") }
        guard catalog.loadError == nil else { throw HostDockError("原连接记录读取失败，已停止删除。") }
        updatingRecords = true
        defer { updatingRecords = false }
        try await credentials.remove(account: profile.credentialAccount)
        try catalog.remove(profile)
        await refreshSavedConnections()
        for session in allSessions.filter({ $0.profile.id == profile.id }) { await closeSession(session) }
        if pickerSelection == .saved(profile.id) { pickerSelection = .saved(catalog.profiles.first?.id) }
    }

    func closeSession(_ session: SessionModel) async {
        await session.shutdown()
        sessions.removeAll { $0.id == session.id }
        backgroundSessions.removeAll { $0.id == session.id }
        if session.origin == .interactive {
            workspace.remove(session.id)
            if sessions.isEmpty { workspace = WorkspaceArrangement() }
        }
        observations.removeValue(forKey: session.id)
        pickerAttempts.removeValue(forKey: session.id)
        if selectedSessionID == session.id {
            selectedSessionID = workspace.slots[workspace.activeSlot]
            if workspace.layout == .single, let next = sessions.first { selectTab(next.id) }
        }
    }

    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        await closeAllTask?.value
        await automation.shutdown()
        accessValidationSession?.cancelConnection()
        await accessValidationSession?.shutdown()
        connectionPickerPresented = false
        await pickerCleanupTask?.value
        await withTaskGroup(of: Void.self) { group in
            for session in allSessions { group.addTask { await session.shutdown() } }
        }
    }
}
