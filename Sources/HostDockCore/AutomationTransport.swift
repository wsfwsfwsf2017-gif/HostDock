import Darwin
import Foundation
import NIOCore
import NIOPosix

public enum ControlSocket {
    public static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HostDock/automation.sock")
    }
    static func sameUser(_ channel: Channel) throws -> Bool {
        try channel.pipeline.syncOperations.withUnsafeTransportIfAvailable(of: Int32.self) { fd in
            var user: uid_t = 0, group: gid_t = 0
            return getpeereid(fd, &user, &group) == 0 && user == geteuid()
        } ?? false
    }
}

private final class ControlServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let perform: @Sendable (ControlRequest) async -> ControlResponse
    var buffer = Data()
    var task: Task<Void, Never>?
    init(_ perform: @escaping @Sendable (ControlRequest) async -> ControlResponse) { self.perform = perform }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard task == nil else { context.close(promise: nil); return }
        let bytes = unwrapInboundIn(data)
        buffer.append(contentsOf: bytes.readableBytesView)
        guard buffer.count <= 1_048_576 else { context.close(promise: nil); return }
        guard buffer.last == 10 else { return }
        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: buffer)

        } catch {
            respond(ControlResponse(UUID(), error: error as? ControlFailure ?? ControlFailure("INVALID_REQUEST", "无效的 JSON 请求。")), context: context)
            return
        }
        guard request.version == 1 else {
            respond(ControlResponse(request.id, error: ControlFailure("UNSUPPORTED_VERSION", "命令行与应用协议版本不兼容。")), context: context)
            return
        }
        let perform = perform
        task = Task {
            let response = await perform(request)
            context.eventLoop.execute { self.respond(response, context: context) }
        }
    }
    private func respond(_ response: ControlResponse, context: ChannelHandlerContext) {
        guard let data = try? JSONEncoder().encode(response) else { context.close(promise: nil); return }
        var output = context.channel.allocator.buffer(capacity: data.count + 1)
        output.writeBytes(data); output.writeInteger(UInt8(10))
        context.writeAndFlush(wrapOutboundOut(output)).whenComplete { _ in context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { task?.cancel(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { task?.cancel(); context.close(promise: nil) }
}

public final class ControlServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var ownsSocket = false
    private var stopped = false
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: Channel] = [:]
    public let url: URL
    public init(url: URL = ControlSocket.url) { self.url = url }
    public func start(_ perform: @escaping @Sendable (ControlRequest) async -> ControlResponse) async throws {
        do {
            guard url.path.utf8.count < 104 else { throw ControlFailure("SOCKET_PATH", "本机账户目录过长，无法创建自动化接口。") }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR else { throw ControlFailure("SOCKET_PATH", "自动化资料目录必须属于当前用户且不能为符号链接。") }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if lstat(url.path, &info) == 0 {
                guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw ControlFailure("SOCKET_PATH", "自动化路径被其他文件占用，原文件已保留。") }
                // 只移除已停止监听且属于当前用户的旧 socket。
                let probe = try? await ClientBootstrap(group: group).connect(unixDomainSocketPath: url.path).get()
                if let probe { try? await probe.close().get(); throw ControlFailure("BUSY", "已有 HostDock 自动化接口正在运行。") }
                try FileManager.default.removeItem(at: url)
            }
            channel = try await ServerBootstrap(group: group).serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelInitializer { [self] child in
                    do {
                        guard try ControlSocket.sameUser(child) else { return child.eventLoop.makeFailedFuture(ControlFailure("FORBIDDEN", "仅当前用户可访问。")) }
                        lock.lock(); clients[ObjectIdentifier(child)] = child; lock.unlock()
                        child.closeFuture.whenComplete { [self, weak child] _ in
                            guard let child else { return }
                            lock.lock(); clients.removeValue(forKey: ObjectIdentifier(child)); lock.unlock()
                        }
                        return child.pipeline.addHandler(ControlServerHandler(perform))
                    } catch { return child.eventLoop.makeFailedFuture(error) }
                }.bind(unixDomainSocketPath: url.path).get()
            ownsSocket = true
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { await stop(); throw error }
    }
    public func stop() async {
        guard lock.withLock({ if stopped { return false }; stopped = true; return true }) else { return }
        try? await channel?.close().get(); channel = nil
        let current = lock.withLock { Array(clients.values) }
        for child in current { try? await child.close().get() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in group.shutdownGracefully { _ in continuation.resume() } }
        var info = stat()
        if ownsSocket, lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK { try? FileManager.default.removeItem(at: url) }
    }
}

private final class ControlClientHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<ControlResponse>
    var buffer = Data()
    private var finished = false
    init(_ promise: EventLoopPromise<ControlResponse>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        buffer.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        guard buffer.count <= 8_388_608 else { fail(ControlFailure("OUTPUT_LIMIT", "自动化返回内容过大。")); context.close(promise: nil); return }
        if buffer.last == 10 {
            do { let response = try JSONDecoder().decode(ControlResponse.self, from: buffer); finished = true; promise.succeed(response) }
            catch { fail(error) }
            context.close(promise: nil)
        }
    }
    func channelActive(context: ChannelHandlerContext) {
        do {
            guard try ControlSocket.sameUser(context.channel) else { throw ControlFailure("FORBIDDEN", "自动化接口不属于当前用户。") }
            context.fireChannelActive()
        } catch { fail(error); context.close(promise: nil) }
    }
    fileprivate func fail(_ error: Error) { if !finished { finished = true; promise.fail(error) } }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { fail(ControlFailure("CONNECTION_CLOSED", "自动化已关闭或本次请求已取消。")) }
}

public enum ControlClient {
    public static func call(_ request: ControlRequest, url: URL = ControlSocket.url) async throws -> ControlResponse {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let promise = loop.makePromise(of: ControlResponse.self)
        let handler = ControlClientHandler(promise)
        do {
            let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(5)).channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }.connect(unixDomainSocketPath: url.path).get()
            defer { channel.close(promise: nil) }
            let result = try await withTaskCancellationHandler {
                let data = try JSONEncoder().encode(request)
                guard data.count <= 1_048_575 else { throw ControlFailure("INVALID_ARGUMENT", "请求过大。") }
                var bytes = channel.allocator.buffer(capacity: data.count + 1); bytes.writeBytes(data); bytes.writeInteger(UInt8(10))
                try await channel.writeAndFlush(bytes).get()
                let response = try await promise.futureResult.get()
                guard response.version == 1, response.requestID == request.id else { throw ControlFailure("INVALID_RESPONSE", "应用返回了不匹配的请求结果。") }
                try Task.checkCancellation()
                return response
            } onCancel: { channel.close(promise: nil) }
            try? await channel.close().get()
            await shutdown(group)
            return result
        } catch {
            try? await loop.submit { handler.fail(error) }.get()
            await shutdown(group); throw error
        }
    }
    private static func shutdown(_ group: MultiThreadedEventLoopGroup) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in group.shutdownGracefully { _ in continuation.resume() } }
    }
}
