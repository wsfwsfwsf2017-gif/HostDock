import Crypto
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import Citadel
@testable import HostDockCore

private final class DeferredHostKey: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    var decision: EventLoopPromise<Void>?
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        decision = validationCompletePromise
    }
}

@Test func hostKeyDecisionPausesDeadlineAndLoginStillTimesOutAfterwards() throws {
    let loop = EmbeddedEventLoop()
    let handler = ClientHandshakeHandler(eventLoop: loop, loginTimeout: .seconds(10))
    let base = DeferredHostKey()
    let validator = LoginHostKeyValidator(base: .custom(base), handshake: handler)
    let decision = loop.makePromise(of: Void.self)
    var result: Result<Void, Error>?
    handler.authenticated.whenComplete { result = $0 }
    loop.advanceTime(by: .seconds(9))
    validator.validateHostKey(hostKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey, validationCompletePromise: decision)
    loop.advanceTime(by: .hours(2))
    #expect(result == nil && base.decision != nil)
    base.decision?.succeed(())
    loop.run()
    loop.advanceTime(by: .seconds(9))
    #expect(result == nil)
    loop.advanceTime(by: .seconds(1))
    if case .failure(let error)? = result { #expect(error as? ChannelError == .connectTimeout(.seconds(10))) }
    else { Issue.record("确认后仍需保留登录超时") }
}

@Test func completedHandshakeCancelsDeadlineAndDisconnectFinishesPendingDecision() throws {
    for authenticate in [false, true] {
        let loop = EmbeddedEventLoop()
        let handler = ClientHandshakeHandler(eventLoop: loop, loginTimeout: .seconds(10))
        let channel = EmbeddedChannel(handler: handler, loop: loop)
        var result: Result<Void, Error>?
        handler.authenticated.whenComplete { result = $0 }
        handler.pauseForHostKeyValidation()
        if authenticate { channel.pipeline.fireUserInboundEventTriggered(UserAuthSuccessEvent()) }
        else { channel.pipeline.fireChannelInactive() }
        handler.resumeAfterHostKeyValidation()
        loop.advanceTime(by: .hours(2))
        if authenticate {
            if case .success? = result {} else { Issue.record("已认证连接不应再次超时") }
        } else {
            if case .failure(let error)? = result { #expect(error as? ChannelError == .eof) }
            else { Issue.record("确认期间断线应立即完成等待") }
        }
        _ = try channel.finish()
    }
}

@Test func rejectedHostKeyIsNeverChangedIntoAnApproval() throws {
    let loop = EmbeddedEventLoop()
    let handler = ClientHandshakeHandler(eventLoop: loop, loginTimeout: .seconds(10))
    let base = DeferredHostKey()
    let validator = LoginHostKeyValidator(base: .custom(base), handshake: handler)
    let decision = loop.makePromise(of: Void.self)
    var failure: Error?
    decision.futureResult.whenFailure { failure = $0 }
    validator.validateHostKey(hostKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey, validationCompletePromise: decision)
    loop.advanceTime(by: .seconds(20))
    base.decision?.fail(SSHConnectionFailure.hostKey)
    loop.run()
    #expect(failure as? SSHConnectionFailure == .hostKey)
    loop.advanceTime(by: .seconds(11))
}
