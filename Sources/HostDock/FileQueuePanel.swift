import SwiftUI

struct FileQueuePanel: View {
    @ObservedObject var session: SessionModel
    @ObservedObject var queue: FileOperationQueue
    @ViewState private var startHeight: CGFloat?
    var body: some View {
        VStack(spacing: 0) {
            if session.queueExpanded {
                Rectangle().fill(DockTheme.border).frame(height: 5).contentShape(Rectangle())
                    .help("拖动调整操作队列高度")
                    .gesture(DragGesture().onChanged { value in
                        if startHeight == nil { startHeight = session.queueHeight }
                        session.queueHeight = min(320, max(120, (startHeight ?? 180) - value.translation.height))
                    }.onEnded { _ in startHeight = nil })
            }
            HStack(spacing: 12) {
                Button { session.queueExpanded.toggle() } label: {
                    Label("操作队列 · \(queue.jobs.filter { !$0.state.finished }.count) 项未完成", systemImage: session.queueExpanded ? "chevron.down" : "chevron.up")
                }.buttonStyle(.plain).help(session.queueExpanded ? "收起队列" : "展开队列")
                Spacer()
                if queue.paused {
                    if queue.jobs.contains(where: { $0.state == .review }) {
                        Button("已核对，继续") { queue.resumeAfterReview() }.help("确认服务器上的实际结果后继续等待任务；不会重试待核对任务")
                    } else {
                        Button("恢复并继续") { Task { await session.remote.refresh(); if session.connectionIndicatorHealthy { queue.resumeWhenSafe() } } }
                    }
                }
                Button("取消等待任务", action: queue.cancelWaiting).disabled(!queue.jobs.contains { $0.state == .queued })
                Button("清除已结束", action: queue.clearCompleted).disabled(!queue.jobs.contains { $0.state.finished && $0.state != .review })
            }.font(.system(size: 12)).padding(.horizontal, 14).frame(height: 34)
            if session.queueExpanded {
                Divider()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(queue.jobs) { job in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(job.label).lineLimit(1).truncationMode(.middle).foregroundStyle(DockTheme.text)
                                        if !job.detail.isEmpty { Text(job.detail).lineLimit(2).foregroundStyle(DockTheme.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).help(job.label + "\n" + job.detail)
                                    if let progress = job.progress, !job.state.finished { ProgressView(value: progress).frame(width: 80) }
                                    Text(job.state.rawValue).foregroundStyle(job.state == .failed || job.state == .review ? Color.orange : DockTheme.secondary).frame(width: 66)
                                    Text("\(max(0, Int((job.ended ?? context.date).timeIntervalSince(job.started ?? job.submitted)))) 秒")
                                        .monospacedDigit().foregroundStyle(DockTheme.secondary).frame(width: 60, alignment: .trailing)
                                    Button("取消") {
                                        if queue.activeID == job.id { session.cancelTransfer() } else { queue.cancel(job.id) }
                                    }.disabled(job.state.finished || job.state == .cancelling)
                                }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                }
            }
        }.frame(height: session.queueExpanded ? session.queueHeight : 34)
            .background(DockTheme.surface).foregroundStyle(DockTheme.text)
    }
}
