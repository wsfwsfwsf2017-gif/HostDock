import Foundation

/// Transport failures are distinct from SFTP permission and path errors.
public enum FileConnectionFailure: String, Error, LocalizedError, Sendable {
    case closed, timedOut, interrupted
    public var errorDescription: String? {
        switch self {
        case .closed: return "文件连接已断开。请刷新以恢复连接。"
        case .timedOut: return "文件服务器未及时响应，已结束等待。请刷新以恢复连接。"
        case .interrupted: return "文件请求已中断，服务端操作结果可能需要核对。"
        }
    }
}
