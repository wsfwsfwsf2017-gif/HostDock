import AppKit
import HostDockCore
import SwiftUI

struct JumpServerAccessPicker: View {
    @ObservedObject var app: AppModel
    @Binding var draft: ConnectionFormDraft
    @Binding var access: JumpServerAccessProfile?
    @Binding var secret: String
    var requestUnlock = false
    @ViewState private var editing: JumpServerAccessProfile?
    @ViewState private var needsUnlock = false
    @ViewState private var keyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("使用堡垒机").font(.system(size: 12)).foregroundStyle(DockTheme.secondary)
                    if let access { Text(access.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(access.displayName) }
                    else { Text("先配置堡垒机，之后新增服务器即可复用").font(.system(size: 12)) }
                }
                Spacer(minLength: 8)
                if app.catalog.accessProfiles.count > 1 {
                    Menu {
                        ForEach(app.catalog.accessProfiles) { item in Button(item.displayName) { select(item); app.rememberAccessSelection(item) } }
                        Divider()
                        Button("新增堡垒机…") { editing = JumpServerAccessProfile() }
                    } label: { Image(systemName: "chevron.up.chevron.down").frame(width: 32, height: 32) }
                        .menuStyle(.borderlessButton).frame(width: 32, height: 32).accessibilityLabel("选择堡垒机").modifier(DockHoverCursor())
                }
                Button("配置堡垒机…") { editing = access ?? JumpServerAccessProfile() }.buttonStyle(DockButtonStyle())
            }
            if let access {
                Label("已选择密钥：" + URL(fileURLWithPath: access.privateKeyPath).lastPathComponent, systemImage: "key.horizontal")
                    .font(.system(size: 11)).foregroundStyle(DockTheme.secondary).lineLimit(1)
            }
            if needsUnlock || requestUnlock {
                DockFormField(title: "密钥口令") { SecureField("解锁本机私钥所需的口令", text: $secret).accessibilityLabel("密钥口令") }
            }
            if let keyError { DockNotice(text: keyError) }
        }.padding(16).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 9))
            .onAppear {
                if let access { select(access) }
                else if let saved = app.catalog.accessProfiles.first(where: { $0.id == draft.jumpServer.accessProfileID }) ?? app.preferredAccessProfile { select(saved) }
                else if draft.profile.authenticationKind == .rsaKey, !(draft.profile.privateKeyPath ?? "").isEmpty {
                    let legacy = JumpServerAccessProfile(profile: (try? draft.validated()) ?? draft.profile)
                    select(legacy)
                }
            }
            .task(id: access?.authenticationIdentity) {
                needsUnlock = false; keyError = nil
                guard let current = access else { return }
                do {
                    let info = try await Task.detached { try RSAKeyInfo.inspect(path: current.privateKeyPath) }.value
                    try Task.checkCancellation()
                    guard access?.authenticationIdentity == current.authenticationIdentity else { return }
                    access?.keyRequiresPassphrase = info.requiresPassphrase
                    draft.profile.keyRequiresPassphrase = info.requiresPassphrase
                    if info.requiresPassphrase { needsUnlock = !(await app.hasSavedPassphrase(profile: draft.profile, access: current)) }
                } catch is CancellationError {} catch { keyError = error.localizedDescription }
            }
            .sheet(item: $editing) { value in
                JumpServerAccessEditor(app: app, access: value, asset: (try? draft.validated()) ?? draft.profile, startNew: { editing = JumpServerAccessProfile() }) { selected, passphrase in
                    select(selected); secret = passphrase ?? ""; editing = nil
                } cancel: { editing = nil }
                    .id(value.id)
            }
    }
    private func select(_ value: JumpServerAccessProfile) {
        access = value; draft.useAccess(value); secret = ""
    }
}

struct JumpServerAccessEditor: View {
    @ObservedObject var app: AppModel
    let asset: ConnectionProfile
    let original: JumpServerAccessProfile?
    let saved: (JumpServerAccessProfile, String?) -> Void
    let cancel: () -> Void
    let startNew: (() -> Void)?
    @ViewState private var access: JumpServerAccessProfile
    @ViewState private var address: String
    @ViewState private var gateway: String
    @ViewState private var port: String
    @ViewState private var secret = ""
    @ViewState private var encrypted = false
    @ViewState private var needsUnlock = false
    @ViewState private var details = false
    @ViewState private var selectedAssetID: UUID?
    @ViewState private var operation: Task<Void, Never>?
    @ViewState private var error: String?
    @ViewState private var keyError: String?
    @ViewState private var showingHelp = false
    @ViewState private var deleting = false
    private var assets: [ConnectionProfile] { app.catalog.profiles.filter { $0.jumpServer?.accessProfileID == access.id } }
    private var busy: Bool { operation != nil }

    init(app: AppModel, access: JumpServerAccessProfile, asset: ConnectionProfile, startNew: (() -> Void)? = nil, saved: @escaping (JumpServerAccessProfile, String?) -> Void, cancel: @escaping () -> Void) {
        self.app = app; self.asset = asset; self.saved = saved; self.cancel = cancel
        self.startNew = startNew
        original = app.catalog.accessProfiles.first { $0.id == access.id }
        _access = ViewState(initialValue: access)
        _address = ViewState(initialValue: access.portalURL ?? access.host)
        _gateway = ViewState(initialValue: (try? JumpServerAddress(access.portalURL ?? access.host).host) == access.host ? "" : access.host)
        _port = ViewState(initialValue: String(access.port))
        _selectedAssetID = ViewState(initialValue: app.catalog.profiles.first { $0.jumpServer?.accessProfileID == access.id }?.id)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("堡垒机配置").font(.system(size: 20, weight: .semibold))
                Spacer()
                if original != nil, let startNew { Button("新增配置…", action: startNew).buttonStyle(DockButtonStyle()).disabled(busy) }
                Button { showingHelp.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(DockButtonStyle()).accessibilityLabel("JumpServer 连接帮助")
                    .popover(isPresented: $showingHelp) { JumpServerHelpView() }
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Group {
                    DockFormField(title: "配置名称") { TextField("例如：公司堡垒机", text: $access.name).accessibilityLabel("配置名称") }
                    DockFormField(title: "堡垒机地址") { TextField("登录网址、IP 或域名", text: $address).accessibilityLabel("堡垒机地址") }
                    DockFormField(title: "堡垒机账号") { TextField("你登录 JumpServer 的账号", text: $access.username).accessibilityLabel("堡垒机账号") }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SSH 密钥").font(.system(size: 12, weight: .medium))
                            Text(access.privateKeyPath.isEmpty ? "选择本机已有私钥" : "已选择密钥：" + URL(fileURLWithPath: access.privateKeyPath).lastPathComponent)
                                .font(.system(size: 12)).foregroundStyle(DockTheme.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(access.privateKeyPath.isEmpty ? "选择私钥…" : "更换…", action: chooseKey).buttonStyle(DockButtonStyle()).accessibilityLabel("选择或更换 SSH 私钥")
                    }.padding(.vertical, 4)
                    if encrypted && needsUnlock {
                        DockFormField(title: "密钥口令") { SecureField("解锁本机私钥所需的口令", text: $secret).accessibilityLabel("密钥口令") }
                    }
                    if encrypted {
                        HStack {
                            Toggle("记住密钥口令", isOn: $access.rememberPassphrase).toggleStyle(.checkbox)
                            Spacer()
                            if !needsUnlock { Button("重新输入口令…") { needsUnlock = true }.buttonStyle(DockButtonStyle()) }
                        }.font(.system(size: 12))
                    }
                    DisclosureGroup("连接详情", isExpanded: $details) {
                        VStack(alignment: .leading, spacing: 14) {
                            DockFormField(title: "SSH 网关") { TextField("默认从堡垒机地址提取", text: $gateway).accessibilityLabel("SSH 网关") }
                            DockFormField(title: "SSH 端口") { TextField("2222", text: $port).accessibilityLabel("SSH 端口") }
                            if !access.privateKeyPath.isEmpty { Text("密钥位置：" + access.privateKeyPath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                        }.padding(.top, 14)
                    }.font(.system(size: 12)).foregroundStyle(DockTheme.secondary)
                    if assets.count > 1 {
                        Picker("验证目标", selection: $selectedAssetID) {
                            ForEach(assets) { profile in Text(profile.name + " · " + profile.displayAddress).tag(Optional(profile.id)) }
                        }.frame(minHeight: 36)
                    } else if let target = assets.first {
                        Text("验证目标：\(target.name) · \(target.displayAddress)").font(.system(size: 12)).foregroundStyle(DockTheme.secondary)
                    }
                    if original != nil { Text("关联服务器下次连接使用更新后的配置，当前会话继续运行。")
                        .font(.system(size: 12)).foregroundStyle(DockTheme.secondary) }
                    if let keyError { DockNotice(text: keyError) }
                    if let error { DockNotice(text: error) }
                    }.disabled(busy)
                    if let session = app.accessValidationSession { AccessValidationStatus(session: session) }
                }.padding(24)
            }
            Divider()
            HStack(spacing: 12) {
                if let original, assets.isEmpty {
                    Button("删除配置", role: .destructive) { deleting = true }
                        .buttonStyle(DockButtonStyle()).disabled(busy || app.catalog.recent.contains { $0.jumpServer?.accessProfileID == original.id })
                        .help("只有没有服务器及历史引用的配置才可删除")
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("取消") {
                    if showingHelp { showingHelp = false }
                    else { operation?.cancel(); secret = ""; cancel() }
                }.keyboardShortcut(.cancelAction).buttonStyle(DockButtonStyle())
                Button(original == nil ? "使用此配置" : "保存配置", action: submit)
                    .keyboardShortcut(.defaultAction).buttonStyle(DockButtonStyle(prominent: true)).disabled(busy || keyError != nil || access.privateKeyPath.isEmpty)
            }.padding(24)
        }.frame(width: 620, height: 620).foregroundStyle(DockTheme.text).background(DockTheme.surface).tint(DockTheme.accent)
            .interactiveDismissDisabled(busy)
            .confirmationDialog("删除这份堡垒机配置？", isPresented: $deleting) {
                Button("删除“\(access.displayName)”", role: .destructive) {
                    guard let original else { return }
                    operation = Task {
                        do { try await app.removeAccessProfile(original); cancel() }
                        catch { self.error = error.localizedDescription }; operation = nil
                    }
                }
            } message: { Text("删除接入信息及保存的口令，本机私钥文件继续保留。") }
            .task(id: [access.privateKeyPath, address, gateway, port, access.username].joined(separator: "\0")) {
                secret = ""; keyError = nil; encrypted = false; needsUnlock = false
                guard !access.privateKeyPath.isEmpty else { return }
                let path = access.privateKeyPath
                do {
                    let info = try await Task.detached { try RSAKeyInfo.inspect(path: path) }.value
                    try Task.checkCancellation()
                    guard access.privateKeyPath == path else { return }
                    encrypted = info.requiresPassphrase; access.keyRequiresPassphrase = info.requiresPassphrase
                    var candidate = access
                    if let parsed = try? JumpServerAddress(address) { candidate.host = gateway.isEmpty ? parsed.host : gateway }
                    candidate.port = Int(port) ?? access.port
                    if info.requiresPassphrase { needsUnlock = !(await app.hasSavedPassphrase(profile: asset, access: candidate)) }
                } catch is CancellationError {} catch { keyError = error.localizedDescription }
            }
            .onDisappear { operation?.cancel(); secret = "" }
    }
    private func submit() {
        error = nil
        do {
            let parsed = try JumpServerAddress(address)
            guard let number = Int(port) else { throw HostDockError("请输入有效的 SSH 端口。") }
            var candidate = access
            candidate.host = gateway.isEmpty ? parsed.host : gateway; candidate.port = number; candidate.portalURL = parsed.portalURL
            candidate.keyRequiresPassphrase = encrypted
            candidate = try candidate.validated()
            let changed = original.map { $0.authenticationIdentity != candidate.authenticationIdentity || $0.rememberPassphrase != candidate.rememberPassphrase || $0.keyRequiresPassphrase != candidate.keyRequiresPassphrase } ?? true
            if !changed { try app.saveAccessDetails(candidate); saved(candidate, nil); return }
            candidate.lastValidatedAt = nil
            guard original != nil, let target = assets.first(where: { $0.id == selectedAssetID }) ?? assets.first else {
                saved(candidate, secret.isEmpty ? nil : secret); secret = ""; return
            }
            let phrase = secret.isEmpty ? nil : secret; secret = ""
            operation = Task {
                do {
                    try await app.validateAndSaveAccess(candidate, asset: target, password: phrase)
                    guard !Task.isCancelled, let committed = app.catalog.accessProfiles.first(where: { $0.id == candidate.id }) else { throw CancellationError() }
                    saved(committed, nil)
                } catch {
                    if !(error is CancellationError) { self.error = error.localizedDescription; if encrypted { needsUnlock = true } }
                }
                operation = nil
            }
        } catch { self.error = error.localizedDescription }
    }
    private func chooseKey() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = "选择私钥文件；.pub 是上传到 JumpServer 的公钥，不能用于本机认证。"
        panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { access.privateKeyPath = url.path } }
    }
}

private struct AccessValidationStatus: View {
    @ObservedObject var session: SessionModel
    var body: some View {
        if let request = session.hostTrustRequest { HostTrustCard(request: request, trust: session.trustHost) }
        else { Text(session.status).font(.system(size: 12)).foregroundStyle(DockTheme.secondary) }
    }
}
