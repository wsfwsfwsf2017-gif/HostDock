import AppKit
import HostDockCore
import SwiftUI

struct ConnectionPickerView: View {
    @ObservedObject var app: AppModel
    @ViewState private var showingJumpHelp = false
    @ViewState private var deleting: ConnectionProfile?
    @ViewState private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HostDockMark().frame(width: 25, height: 25)
                Text(app.pickerEditing ? "编辑服务器" : app.pickerSelection.tab == .new ? "新建连接" : "连接服务器")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("关闭") {
                    if showingJumpHelp { showingJumpHelp = false }
                    else { app.connectionPickerPresented = false }
                }.keyboardShortcut(.cancelAction).buttonStyle(DockButtonStyle()).disabled(app.updatingRecords)
            }.padding(.horizontal, 24).frame(height: 68)
            Rectangle().fill(DockTheme.border).frame(height: 1)
            if let error = app.catalog.loadError { DockNotice(text: error).padding(12) }
            if let notice { DockNotice(text: notice).padding(12) }
            if let profile = app.pickerProfile {
                if app.pickerEditing {
                    ScrollView {
                        ProfileEditor(app: app, profile: profile, showingHelp: $showingJumpHelp,
                                      saved: { app.connectionPickerPresented = false },
                                      cancel: { app.pickerEditing = false }).padding(.vertical, 8)
                    }
                } else {
                    ConnectionForm(app: app, profile: profile, session: app.pickerSession, showingHelp: $showingJumpHelp,
                                   edit: { app.pickerEditing = true }, remove: { deleting = profile }).id(profile)
                }
            }
        }
        .frame(width: 780, height: 670)
        .background(DockTheme.surface).foregroundStyle(DockTheme.text).tint(DockTheme.accent)
        .background(ConnectionPickerWindow())
        .interactiveDismissDisabled(app.updatingRecords)
        .confirmationDialog("删除服务器记录及已保存的认证？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let profile = deleting {
                Button("删除“\(profile.name)”", role: .destructive) {
                    Task {
                        do { try await app.removeProfile(profile); app.connectionPickerPresented = false }
                        catch { notice = error.localizedDescription }
                        deleting = nil
                    }
                }
            }
        }
    }
}

private struct ConnectionPickerWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowReader() }
    func updateNSView(_ view: NSView, context: Context) {}
    final class WindowReader: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 退出由 AppDelegate 确认并清理会话，连接弹窗不能先拦截退出请求。
            window?.preventsApplicationTerminationWhenModal = false
        }
    }
}

struct SidebarLabel: View {
    let name: String
    let address: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(DockTheme.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(address).font(.system(size: 10, design: .monospaced)).foregroundStyle(DockTheme.secondary).lineLimit(1).truncationMode(.middle)
            }
        }.contentShape(Rectangle()).help(name + "\n" + address)
    }
}

struct SessionPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: SessionModel
    var compact = false
    var body: some View {
        if session.connected {
            if compact {
                VStack(spacing: 0) {
                    if let conflict = session.conflictRequest { FileConflictCard(app: session, conflict: conflict) }
                    TerminalPane(app: session, showHeader: false)
                    if session.transferring { HStack {
                        Text(session.transferLabel).lineLimit(1)
                        ProgressView(value: session.progress).frame(width: 70)
                        Button("取消", action: session.cancelTransfer)
                    }.font(.caption).padding(8) }
                }
            } else {
                ContentView(app: session, showConnections: { app.reconnect(session) }).id(session.id)
                    .onChange(of: session.workspaceMode) { _, mode in
                        guard let window = session.terminal.view.window else { return }
                        if mode == .files {
                            if window.firstResponder === session.terminal.view { window.makeFirstResponder(nil) }
                        } else {
                            DispatchQueue.main.async { [weak window, weak responder = window.firstResponder] in
                                guard let window, session.workspaceMode == .terminal, window.firstResponder === responder else { return }
                                window.contentView?.layoutSubtreeIfNeeded()
                                focusWorkspaceSession(app, id: session.id)
                            }
                        }
                    }
            }
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "server.rack").font(.system(size: 32, weight: .light)).foregroundStyle(DockTheme.accent)
                    Text(session.profile.name).font(.system(size: 20, weight: .semibold)).lineLimit(1).help(session.profile.name)
                    Text(session.profile.displaySubtitle).font(.system(size: 12, design: .monospaced)).foregroundStyle(DockTheme.secondary)
                    if let request = session.hostTrustRequest {
                        HostTrustCard(request: request, trust: session.trustHost)
                        Button("取消连接", action: session.cancelConnection).buttonStyle(DockButtonStyle())
                    }
                    else {
                        if session.busy { ProgressView().controlSize(.small) }
                        Text(session.connectionError ?? session.status).font(.system(size: 13)).foregroundStyle(DockTheme.secondary).textSelection(.enabled)
                        if session.connecting { Button("取消连接", action: session.cancelConnection).buttonStyle(DockButtonStyle()) }
                        else {
                            HStack(spacing: 12) {
                                Button("重新连接") { app.reconnect(session) }.buttonStyle(DockButtonStyle(prominent: true))
                                    .disabled(!app.canReconnect(session))
                                if session.needsAuthentication {
                                    Button("修改认证…") { app.showConnection(session, authenticating: true) }
                                        .buttonStyle(DockButtonStyle()).disabled(session.busy || app.closingTabs || app.shuttingDown)
                                }
                            }
                        }
                    }
                }.padding(28).frame(maxWidth: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ConnectionIdentityFields: View {
    @ObservedObject var app: AppModel
    @Binding var draft: ConnectionFormDraft
    @Binding var secret: String
    @Binding var showingHelp: Bool
    @Binding var access: JumpServerAccessProfile?
    var requestUnlock = false
    private var isJumpServer: Bool { draft.profile.connectionMode == .jumpServer }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                DockTabs(options: ConnectionMode.allCases.map { ($0, $0.title) },
                         selection: Binding(get: { draft.profile.connectionMode }, set: { draft.changeMode(to: $0, secret: &secret) }))
                    .frame(width: 290).accessibilityLabel("连接方式")
                if isJumpServer {
                    Button { showingHelp.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 17)) }
                        .buttonStyle(DockButtonStyle()).accessibilityLabel("JumpServer 连接帮助")
                        .help("使用已有 RSA 私钥。查看查找密钥、生成密钥及配置公钥的步骤。")
                        .popover(isPresented: $showingHelp, arrowEdge: .bottom) { JumpServerHelpView() }
                }
                Spacer(minLength: 0)
            }
            if isJumpServer {
                if draft.profile.authenticationKind == .rsaKey {
                    JumpServerAccessPicker(app: app, draft: $draft, access: $access, secret: $secret, requestUnlock: requestUnlock)
                }
                field("自定义名称", placeholder: "例如：开发服务器", text: $draft.profile.name)
                ViewThatFits(in: .horizontal) { HStack(alignment: .top, spacing: 16) {
                    field("目标服务器 IP", placeholder: "要操作的服务器 IP", text: $draft.jumpServer.targetHost)
                    field("目标登录账号", placeholder: "ssta", text: $draft.jumpServer.targetUsername)
                }; VStack(spacing: 16) {
                    field("目标服务器 IP", placeholder: "要操作的服务器 IP", text: $draft.jumpServer.targetHost)
                    field("目标登录账号", placeholder: "ssta", text: $draft.jumpServer.targetUsername)
                } }
                if draft.profile.authenticationKind == .password {
                    field("堡垒机地址", placeholder: "已有密码型连接的网关地址", text: $draft.gatewayAddress)
                    field("堡垒机账号", placeholder: "JumpServer 账号", text: $draft.jumpServer.username)
                    field("SSH 端口", placeholder: "2222", text: $draft.port)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    field("自定义名称", placeholder: "例如：开发服务器", text: $draft.profile.name)
                    field("服务器 IP 或域名", placeholder: "例如：192.0.2.10", text: $draft.profile.endpoint.host)
                }
                HStack(alignment: .top, spacing: 16) {
                    field("服务器账号", placeholder: "root", text: $draft.profile.endpoint.username)
                    field("SSH 端口", placeholder: "22", text: $draft.port)
                }
            }
        }.font(.system(size: 13))
    }
    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        DockFormField(title: label) { TextField(placeholder, text: text).accessibilityLabel(label) }
    }
}

struct JumpServerHelpView: View {
    private let findCommand = "ls -la ~/.ssh/*.pub"
    private let generateCommand = "ssh-keygen -t rsa -b 3072 -f ~/.ssh/id_rsa_hostdock -C hostdock"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("准备 JumpServer 连接", systemImage: "info.circle").font(.headline)
                Text("1 · 确认已有密钥").fontWeight(.semibold)
                Text("在访达按 ⇧⌘G 打开 ~/.ssh，或在本机终端运行以下命令。以 .pub 结尾的是公钥，同名但没有 .pub 后缀的是私钥。已有 RSA 密钥可以直接使用。")
                command(findCommand)
                Text("2 · 没有密钥时手动生成").fontWeight(.semibold)
                Text("推荐 3072 位 RSA。先确认输出路径不存在；若提示覆盖，选择不覆盖。按终端提示设置密钥口令，HostDock 不会替你生成或修改密钥。")
                command(generateCommand)
                Text("3 · 把公钥配置到堡垒机").fontWeight(.semibold)
                Text("登录堡垒机网页，在设置／个人信息／认证设置中找到 SSH 公钥设置（部分版本位于 API Key 附近）。粘贴 .pub 文件中的完整单行文本，保留 ssh-rsa 前缀；不要粘贴私钥。")
                Link("官方公钥设置说明 ↗", destination: URL(string: "https://docs.fit2cloud.com/jumpserver/manual/common/profile/")!)
                Text("4 · 在 HostDock 填写目标").fontWeight(.semibold)
                Text("选择对应私钥，填写堡垒机账号、目标 IP 和目标账号（默认 ssta）。有密钥口令时再填写口令。网页密码、目标密码和密钥口令是不同的内容；这里不需要前两者。")
                Text("RSA 是密钥算法，不要求把中文账号改成英文。默认 OpenSSH RSA 与 PEM RSA 格式均受支持。连接前接通所需 VPN，并确认已有资产的 SSH／SFTP 权限。")
                    .foregroundStyle(DockTheme.secondary)
                Link("OpenSSH 密钥说明 ↗", destination: URL(string: "https://man.openbsd.org/ssh-keygen")!)
            }.font(.system(size: 12)).lineSpacing(3).padding(22)
        }.frame(width: 450, height: 580).foregroundStyle(DockTheme.text).background(DockTheme.surface).tint(DockTheme.accent)
    }
    private func command(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Button("复制命令") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
                .buttonStyle(DockButtonStyle())
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct ConnectionForm: View {
    @ObservedObject var app: AppModel
    let profile: ConnectionProfile
    let session: SessionModel?
    let edit: (() -> Void)?
    let remove: (() -> Void)?
    @Binding var showingHelp: Bool
    @ViewState private var draft: ConnectionFormDraft
    @ViewState private var localDirectory: String
    @ViewState private var remoteDirectory: String
    @ViewState private var password = ""
    @ViewState private var access: JumpServerAccessProfile?
    @ViewState private var directoriesExpanded = true
    @ViewState private var remember: Bool
    @ViewState private var changingAuthentication: Bool
    @ViewState private var error: String?
    @FocusState private var passwordFocused: Bool

    init(app: AppModel, profile: ConnectionProfile, session: SessionModel?, showingHelp: Binding<Bool>, edit: (() -> Void)?, remove: (() -> Void)?) {
        self.app = app; self.profile = profile; self.session = session; self.edit = edit; self.remove = remove
        _showingHelp = showingHelp
        _draft = ViewState(initialValue: ConnectionFormDraft(profile))
        _localDirectory = ViewState(initialValue: profile.localStartDirectory ?? "")
        _remoteDirectory = ViewState(initialValue: profile.remoteStartDirectory ?? "")
        _remember = ViewState(initialValue: profile.rememberPassword)
        _changingAuthentication = ViewState(initialValue: app.pickerAuthenticating || !app.readyProfileIDs.contains(profile.id))
        _access = ViewState(initialValue: app.newAccessProfile?.id == profile.jumpServer?.accessProfileID ? app.newAccessProfile : app.catalog.accessProfiles.first { $0.id == profile.jumpServer?.accessProfileID })
    }
    private var isNew: Bool { app.pickerSelection.tab == .new }
    private var busy: Bool { app.pickerBusy || app.shuttingDown }
    private var usesPassword: Bool { draft.profile.authenticationKind == .password }
    private var sharedJump: Bool { draft.profile.connectionMode == .jumpServer && !usesPassword }
    private var passwordLabel: String { usesPassword ? (draft.profile.connectionMode == .jumpServer ? "堡垒机登录密码" : "连接密码") : "密钥口令" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !isNew {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(profile.name).font(.system(size: 24, weight: .semibold)).lineLimit(1).help(profile.name)
                            Text(profile.displaySubtitle).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DockTheme.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        if let edit, app.catalog.profiles.contains(where: { $0.id == profile.id }) {
                            Button(action: edit) { Image(systemName: "pencil") }.help("编辑服务器").disabled(app.isActive(profile))
                            if let remove { Button(action: remove) { Image(systemName: "trash") }.help("删除服务器").disabled(app.isActive(profile)) }
                        }
                    }.buttonStyle(DockButtonStyle()).disabled(busy)
                }
                if isNew || changingAuthentication {
                    ConnectionIdentityFields(app: app, draft: $draft, secret: $password, showingHelp: $showingHelp, access: $access, requestUnlock: session?.passwordRequired == true).disabled(busy && app.accessValidationSession == nil)
                }
                if let request = session?.hostTrustRequest { HostTrustCard(request: request, trust: { session?.trustHost() }) }
                else {
                    if session?.connected != true && (changingAuthentication || isNew) && !sharedJump {
                        VStack(alignment: .leading, spacing: 10) {
                            if !usesPassword {
                                HStack {
                                    TextField("RSA 私钥路径", text: Binding(get: { draft.profile.privateKeyPath ?? "" }, set: { draft.profile.privateKeyPath = $0 }))
                                        .textFieldStyle(DockTextFieldStyle()).accessibilityLabel("RSA 私钥路径")
                                    Button("选择私钥…") { choosePrivateKey() }.buttonStyle(DockButtonStyle())
                                }
                            }
                            DockFormField(title: passwordLabel) {
                            SecureField(usesPassword ? "输入密码，验证成功后保存" : "私钥没有口令时留空", text: $password)
                                .accessibilityLabel(passwordLabel)
                                .textFieldStyle(.plain).padding(.horizontal, 11).frame(height: 36).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(passwordFocused ? DockTheme.accent : DockTheme.border))
                                .focused($passwordFocused).onSubmit(connect)
                            }
                            Toggle(usesPassword ? "记住密码" : "记住密钥口令", isOn: $remember).toggleStyle(.checkbox).font(.system(size: 12)).padding(.leading, 116)
                        }.disabled(busy)
                    } else if session?.connected != true && !(changingAuthentication || isNew) {
                        if sharedJump {
                            JumpServerAccessPicker(app: app, draft: $draft, access: $access, secret: $password, requestUnlock: session?.passwordRequired == true).disabled(busy && app.accessValidationSession == nil)
                        } else {
                        HStack {
                            Label("已保存\(profile.authenticationKind.title)认证，可直接连接", systemImage: "checkmark.shield")
                                .font(.system(size: 12)).foregroundStyle(DockTheme.secondary)
                            Spacer()
                            Button("修改认证") { changingAuthentication = true }.buttonStyle(DockButtonStyle()).disabled(busy)
                        }
                        }
                    }
                    if sharedJump && session?.connected == true && !(changingAuthentication || isNew) {
                        JumpServerAccessPicker(app: app, draft: $draft, access: $access, secret: $password).disabled(busy && app.accessValidationSession == nil)
                    }
                    DisclosureGroup("默认目录", isExpanded: $directoriesExpanded) {
                        StartDirectoryFields(local: $localDirectory, remote: $remoteDirectory).padding(.top, 14)
                    }.font(.system(size: 12)).disabled(busy || session?.connected == true)
                }
                if let error { DockNotice(text: error) }
                if let error = session?.connectionError { DockNotice(text: error) }
                if let notice = session?.credentialNotice { DockNotice(text: notice) }
                if session?.passwordRequired == true && session?.connectionError == nil && session?.credentialNotice == nil {
                    DockNotice(text: usesPassword ? "尚无可用密码，请修改认证并验证保存。" : "请提供正确的密钥口令。")
                }
            }.padding(isNew ? 20 : 28).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity)
        }.background(DockTheme.surface)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if session?.connecting == true {
                            ProgressView().controlSize(.small)
                            Text("正在连接…").font(.system(size: 12)).foregroundStyle(DockTheme.secondary)
                            Spacer()
                            Button("取消") { session?.cancelConnection() }.buttonStyle(DockButtonStyle())
                        } else {
                            Button(session?.connected == true ? "打开已有会话" : (isNew || changingAuthentication) ? "验证并连接" : "连接服务器", action: connect)
                                .buttonStyle(DockButtonStyle(prominent: true)).disabled(busy)
                            Spacer()
                        }
                    }
                }.padding(.horizontal, 28).padding(.vertical, 14).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity)
                    .background(DockTheme.surface).overlay(alignment: .top) { Rectangle().fill(DockTheme.border).frame(height: 1) }
            }
            .onAppear { if session?.passwordRequired == true { passwordFocused = true } }
            .onChange(of: session?.passwordRequired) { _, value in if value == true && !sharedJump { changingAuthentication = true; passwordFocused = true } }
            .onChange(of: draft.profile.privateKeyPath) { _, _ in if !sharedJump { password = ""; draft.profile.keyRequiresPassphrase = false } }
            .onDisappear { password = "" }
    }
    private func connect() {
        guard !busy else { return }
        error = nil
        defer { password = "" }
        draft.profile.localStartDirectory = localDirectory.isEmpty ? nil : localDirectory
        draft.profile.remoteStartDirectory = remoteDirectory.isEmpty ? nil : remoteDirectory
        do {
            if sharedJump && access == nil { throw HostDockError("请先配置堡垒机，再连接目标服务器。") }
            try app.connectFromPicker(profile: draft.validated(), password: password.isEmpty ? nil : password,
                                      rememberPassword: sharedJump ? true : remember, accessProfile: sharedJump ? access : nil)
        }
        catch { self.error = error.localizedDescription }
    }
    private func choosePrivateKey() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = "选择已有的 RSA 私钥；HostDock 不复制或修改原文件。"
        panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { draft.profile.privateKeyPath = url.path } }
    }
}

struct StartDirectoryFields: View {
    @Binding var local: String
    @Binding var remote: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DockFormField(title: "本机目录") { HStack {
                TextField("留空进入主目录", text: $local).accessibilityLabel("默认本地目录").font(.system(size: 12, design: .monospaced))
                Button("选择文件夹…", action: chooseLocal).buttonStyle(DockButtonStyle())
            } }
            DockFormField(title: "服务器目录") { TextField("例如 /var/www 或 ~/projects", text: $remote).accessibilityLabel("默认远端目录").font(.system(size: 12, design: .monospaced)) }
        }
    }
    private func chooseLocal() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "选择本地目录"
        panel.beginSheetModal(for: window) { response in if response == .OK, let url = panel.url { local = url.path } }
    }
}

struct HostTrustCard: View {
    let request: HostTrustRequest
    let trust: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.previous == nil ? "确认服务器指纹" : "服务器指纹发生变化", systemImage: "checkmark.shield")
                .font(.system(size: 13, weight: .semibold))
            Text("\(request.challenge.host):\(request.challenge.port) · \(request.challenge.algorithm)")
                .font(.system(size: 11)).foregroundStyle(DockTheme.secondary)
            Text(request.challenge.fingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            if let previous = request.previous {
                Text("此前：\(previous)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.orange)
            }
            Button("核对后信任", action: trust).buttonStyle(DockButtonStyle(prominent: true))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(DockTheme.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DockTheme.accent.opacity(0.5)))
    }
}

private struct ProfileEditor: View {
    @ObservedObject var app: AppModel
    let profile: ConnectionProfile
    let saved: () -> Void
    let cancel: () -> Void
    @Binding var showingHelp: Bool
    @ViewState private var draft: ConnectionFormDraft
    @ViewState private var secret = ""
    @ViewState private var access: JumpServerAccessProfile?
    @ViewState private var directoriesExpanded = true
    @ViewState private var localDirectory: String
    @ViewState private var remoteDirectory: String
    @ViewState private var error: String?
    @ViewState private var saving = false

    init(app: AppModel, profile: ConnectionProfile, showingHelp: Binding<Bool>, saved: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.app = app; self.profile = profile; self.saved = saved; self.cancel = cancel
        _showingHelp = showingHelp
        _draft = ViewState(initialValue: ConnectionFormDraft(profile))
        _access = ViewState(initialValue: app.catalog.accessProfiles.first { $0.id == profile.jumpServer?.accessProfileID })
        _localDirectory = ViewState(initialValue: profile.localStartDirectory ?? "")
        _remoteDirectory = ViewState(initialValue: profile.remoteStartDirectory ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("编辑服务器").font(.system(size: 22, weight: .semibold))
            ConnectionIdentityFields(app: app, draft: $draft, secret: $secret, showingHelp: $showingHelp, access: $access).disabled(saving)
            DisclosureGroup("默认目录", isExpanded: $directoriesExpanded) {
                StartDirectoryFields(local: $localDirectory, remote: $remoteDirectory).padding(.top, 14)
            }.font(.system(size: 12)).disabled(saving)
            if draft.profile.authenticationKind == .password {
                Toggle("记住密码", isOn: $draft.profile.rememberPassword).toggleStyle(.checkbox).font(.system(size: 12)).disabled(saving)
            }
            Text("名称和目录直接保存；连接身份变化后，需重新验证，成功后才替换原记录。")
                .font(.system(size: 11)).foregroundStyle(DockTheme.secondary)
            if let error { DockNotice(text: error) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") {
                    if showingHelp { showingHelp = false }
                    else { cancel() }
                }.keyboardShortcut(.cancelAction).buttonStyle(DockButtonStyle()).disabled(saving)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(DockButtonStyle(prominent: true)).disabled(saving)
            }
        }.padding(28).frame(maxWidth: 660).background(DockTheme.surface).foregroundStyle(DockTheme.text).tint(DockTheme.accent)
            .interactiveDismissDisabled(saving)
    }
    private func save() {
        draft.profile.localStartDirectory = localDirectory.isEmpty ? nil : localDirectory
        draft.profile.remoteStartDirectory = remoteDirectory.isEmpty ? nil : remoteDirectory
        do {
            let resolved = try draft.resolved()
            if resolved.authenticationKind != profile.authenticationKind || resolved.connectionMode != profile.connectionMode
                || resolved.jumpServer?.targetHost != profile.jumpServer?.targetHost || resolved.jumpServer?.targetUsername != profile.jumpServer?.targetUsername
                || resolved.jumpServer?.accessProfileID != profile.jumpServer?.accessProfileID
                || (resolved.connectionMode == .direct && resolved.endpoint != profile.endpoint) {
                app.useDraft(resolved, accessProfile: access); cancel(); return
            }
            var edited = profile
            edited.name = resolved.name; edited.localStartDirectory = resolved.localStartDirectory; edited.remoteStartDirectory = resolved.remoteStartDirectory
            edited.rememberPassword = resolved.rememberPassword
            saving = true
            Task {
                do { try await app.saveProfile(edited); saved() }
                catch { self.error = error.localizedDescription }
                saving = false
            }
        } catch { self.error = error.localizedDescription }
    }
}
