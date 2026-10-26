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
    let reservations = TransferReservations()
    lazy var automation = AutomationController(app: self)
    @Published private(set) var sessions: [SessionModel] = []
    @Published var selectedSessionID: UUID?
    @Published var pickerSelection: ConnectionPickerSelection
    @Published var connectionPickerPresented = true {
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
    // true 表示弹窗新建的运行项，取消时移除；已有断开会话则保留。
    private var pickerAttempts: [UUID: Bool] = [:]
    private var pickerCleanupTask: Task<Void, Never>?
    private var credentialRefresh = UUID()
    private var credentialRefreshTask: Task<Void, Never>?

    init(catalog: ConnectionCatalog? = nil, credentials: any CredentialStore = EncryptedFileCredentialStore(),
         preferences: UserDefaults = .standard,
         makeConnection: @escaping () -> any SessionConnection = { LiveSessionConnection() }) {
        let catalog = catalog ?? ConnectionCatalog()
        self.catalog = catalog
        self.credentials = credentials
        self.makeConnection = makeConnection
        self.preferences = preferences
        pickerSelection = catalog.profiles.first.map { .saved($0.id) } ?? .new
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
            if !pickerBusy, case .saved(let id) = pickerSelection, id == nil || !ready.contains(id!) {
                pickerSelection = savedProfiles.first.map { .saved($0.id) } ?? .new
            }
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
        guard let profile = pickerProfile else { return nil }
        return sessions.first { $0.profile.id == profile.id || $0.profile.endpoint == profile.endpoint }
    }
    var pickerBusy: Bool { pickerCancelling || updatingRecords || pickerSession?.connecting == true || pickerSession?.disconnecting == true }
    var hasTransfers: Bool { sessions.contains { $0.transferring } }
    func isActive(_ profile: ConnectionProfile) -> Bool {
        sessions.contains { $0.profile.id == profile.id && ($0.connected || $0.busy) }
    }

    func showConnections() {
        guard !shuttingDown, !pickerCancelling, !connectionPickerPresented else { return }
        newProfile = ConnectionProfile(name: "", endpoint: ConnectionEndpoint(host: "", port: 22, username: ""))
        newAccessProfile = nil
        pickerSelection = savedProfiles.first.map { .saved($0.id) } ?? .new
        connectionPickerPresented = true
    }

    func showConnection(_ session: SessionModel) {
        guard !shuttingDown, !pickerCancelling else { return }
        if readyProfileIDs.contains(session.profile.id) { pickerSelection = .saved(session.profile.id) }
        else { useDraft(session.profile) }
        connectionPickerPresented = true
    }

    func selectPickerTab(_ tab: ConnectionPickerTab) {
        guard !pickerBusy else { return }
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
        let endpoint = profile.endpoint
        let previous = sessions.first { $0.profile.id == profile.id || $0.profile.endpoint == endpoint }
        let selected = selectedSessionID
        let result = try connect(profile: profile, password: password, rememberPassword: rememberPassword, accessProfile: accessProfile)
        if result.connected {
            connectionPickerPresented = false
        } else {
            selectedSessionID = selected
            pickerConnectionSelection = pickerSelection
            pickerSessionID = result.id
            pickerAttempts[result.id] = pickerAttempts[result.id] ?? (previous == nil)
        }
        return result
    }

    func presentPendingAutomation(_ session: SessionModel, created: Bool) {
        pickerSelection = .saved(session.profile.id)
        pickerConnectionSelection = pickerSelection
        pickerSessionID = session.id
        pickerAttempts[session.id] = created
        connectionPickerPresented = true
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
    func connect(profile requested: ConnectionProfile, password: String?, rememberPassword: Bool, accessProfile: JumpServerAccessProfile? = nil) throws -> SessionModel {
        guard !shuttingDown, !updatingRecords, !pickerCancelling else { throw HostDockError("正在处理连接，请稍后重试。") }
        if let existing = sessions.first(where: { $0.profile.id == requested.id }), existing.connected || existing.busy {
            selectedSessionID = existing.id; return existing
        }
        let resolved = try catalog.resolve(requested, accessProfile: accessProfile)
        var profile = resolved.profile
        if let existing = sessions.first(where: { $0.profile.endpoint == profile.endpoint }), existing.connected || existing.busy {
            selectedSessionID = existing.id
            return existing
        }
        if !catalog.profiles.contains(where: { $0.id == profile.id }), let saved = catalog.profile(for: profile.endpoint) {
            profile.id = saved.id
        }
        _ = try catalog.validate(profile)
        let session: SessionModel
        if let previous = sessions.first(where: { $0.profile.id == profile.id || $0.profile.endpoint == profile.endpoint }) { session = previous }
        else {
            session = SessionModel(profile: profile, catalog: catalog, credentials: credentials,
                                   connection: makeConnection(), reservations: reservations)
            session.onConnected = { [weak self] id in
                guard let self else { return }
                Task { await self.refreshSavedConnections() }
                if let access = self.catalog.accessProfiles.first(where: { $0.id == self.sessions.first(where: { $0.id == id })?.profile.jumpServer?.accessProfileID }) {
                    self.rememberAccessSelection(access)
                }
                if self.pickerAttempts.removeValue(forKey: id) != nil {
                    self.selectedSessionID = id
                    self.connectionPickerPresented = false
                }
                if self.selectedSessionID == id { self.maximizeRequest += 1 }
            }
            sessions.append(session)
            observations[session.id] = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }
        selectedSessionID = session.id
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
              !sessions.contains(where: { $0.profile.jumpServer?.accessProfileID == access.id && ($0.connected || $0.busy) }) else {
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
        for session in sessions.filter({ $0.profile.id == profile.id }) { await closeSession(session) }
    }

    func removeProfile(_ profile: ConnectionProfile) async throws {
        guard !updatingRecords, !shuttingDown, !isActive(profile) else { throw HostDockError("请先断开这台服务器，再删除记录。") }
        guard catalog.loadError == nil else { throw HostDockError("原连接记录读取失败，已停止删除。") }
        updatingRecords = true
        defer { updatingRecords = false }
        try await credentials.remove(account: profile.credentialAccount)
        try catalog.remove(profile)
        await refreshSavedConnections()
        for session in sessions.filter({ $0.profile.id == profile.id }) { await closeSession(session) }
        if pickerSelection == .saved(profile.id) { pickerSelection = .saved(catalog.profiles.first?.id) }
    }

    func closeSession(_ session: SessionModel) async {
        await session.shutdown()
        sessions.removeAll { $0.id == session.id }
        observations.removeValue(forKey: session.id)
        pickerAttempts.removeValue(forKey: session.id)
        if selectedSessionID == session.id { selectedSessionID = sessions.first?.id }
    }

    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        await automation.shutdown()
        accessValidationSession?.cancelConnection()
        await accessValidationSession?.shutdown()
        connectionPickerPresented = false
        await pickerCleanupTask?.value
        await withTaskGroup(of: Void.self) { group in
            for session in sessions { group.addTask { await session.shutdown() } }
        }
    }
}
