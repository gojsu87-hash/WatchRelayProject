// 수정일시: 2026-10-29 23:59 KST
// ContentView.swift
// 상단 연결 상태 텍스트 노출 최소화 버전

import SwiftUI
import SwiftData

// MARK: - 메인 뷰

struct ContentView: View {
    @Environment(BLECentralManager.self) private var bleManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \WatchMessage.createdAt, order: .reverse) private var messages: [WatchMessage]

    var body: some View {
        NavigationStack {
            ChatRoomListView(messages: messages) {
                bleManager.reconnectNow()
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionStatus
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                bleManager.modelContext = modelContext
                bleManager.handleAppActive()
            }
        }
    }

    private var connectionStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 1) {
                Label(statusText, systemImage: statusSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                if bleManager.connectionState == .operational {
                    Text(heartbeatStatusText(at: context.date))
                        .font(.system(size: 9))
                        .foregroundStyle(
                            isHeartbeatFresh(at: context.date) ? Color.secondary : Color.red
                        )
                        .lineLimit(1)
                } else if bleManager.connectionState == .offline {
                    Text(progressText(at: context.date))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 150, alignment: .leading)
        }
            .offset(y: -10)
            .accessibilityElement(children: .combine)
    }

    private func connectionDurationText(at date: Date) -> String {
        guard let connectedAt = bleManager.connectionEstablishedAt else {
            return "연결 시간 확인 중"
        }
        let elapsed = max(0, Int(date.timeIntervalSince(connectedAt)))
        let hours = elapsed / 3_600
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return "연결 유지 · \(hours)시간 \((elapsed % 3_600) / 60)분"
        }
        if minutes == 0 {
            return "연결 유지 · \(seconds)초"
        }
        return "연결 유지 · \(minutes)분 \(seconds)초"
    }

    private func heartbeatStatusText(at date: Date) -> String {
        guard isHeartbeatFresh(at: date) else {
            let elapsed = bleManager.lastHeartbeatResponseAt.map {
                max(0, Int(date.timeIntervalSince($0)))
            }
            let retryText = bleManager.heartbeatDelayed ? " · 재확인 중" : ""
            return "응답 지연\(retryText) · 마지막 응답 \(elapsed.map { "\($0)초 전" } ?? "없음")"
        }
        return connectionDurationText(at: date)
    }

    private func isHeartbeatFresh(at date: Date) -> Bool {
        guard !bleManager.heartbeatDelayed,
              let lastResponse = bleManager.lastHeartbeatResponseAt else { return false }
        return date.timeIntervalSince(lastResponse) < 20
    }

    private func progressText(at date: Date) -> String {
        guard let startedAt = bleManager.retryStartedAt else {
            return bleManager.connectionProgress
        }
        let elapsed = max(0, Int(date.timeIntervalSince(startedAt)))
        if let nextReconnectAt = bleManager.nextReconnectAt,
           nextReconnectAt > date {
            let remaining = Int(ceil(nextReconnectAt.timeIntervalSince(date)))
            return "\(elapsed)초째 재시도 · \(bleManager.connectionProgress) (\(remaining)초 후)"
        }
        return "재시도 \(elapsed)초째 · \(bleManager.connectionProgress)"
    }

    private var statusText: String {
        switch bleManager.connectionState {
        case .operational:
            return isHeartbeatFresh(at: .now) ? "연결됨" : "응답 지연"
        case .connected: return "연결중"
        case .offline: return bleManager.isScanning ? "연결중" : "연결실패"
        }
    }

    private var statusSymbol: String {
        switch bleManager.connectionState {
        case .operational:
            return isHeartbeatFresh(at: .now) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .connected: return "antenna.radiowaves.left.and.right"
        case .offline: return bleManager.isScanning ? "magnifyingglass" : "wifi.slash"
        }
    }

    private var statusColor: Color {
        switch bleManager.connectionState {
        case .operational: return isHeartbeatFresh(at: .now) ? .green : .red
        case .connected: return .orange
        case .offline: return bleManager.isScanning ? .yellow : .red
        }
    }
}

// MARK: - 상단 상태바

struct TopStatusBar: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Spacer()
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - 채팅방 목록

struct ChatRoomListView: View {
    let messages: [WatchMessage]
    let onReconnect: () -> Void

    private var chatRooms: [ChatRoom] {
        var roomMap: [String: (lastMsg: WatchMessage, count: Int)] = [:]

        for msg in messages {
            let roomId = msg.roomId
            if roomId == "etc" { continue }

            if let existing = roomMap[roomId] {
                let isRead = roomId == "com.watchnotify.syslog" ? true : msg.isRead
                let unread = isRead ? existing.count : existing.count + 1
                roomMap[roomId] = (existing.lastMsg, unread)
            } else {
                let unreadCount = roomId == "com.watchnotify.syslog" ? 0 : (msg.isRead ? 0 : 1)
                roomMap[roomId] = (msg, unreadCount)
            }
        }

        return roomMap.map { roomId, value in
            ChatRoom(
                id: roomId,
                pkg: value.lastMsg.pkg,
                roomId: roomId,
                lastMessage: value.lastMsg.body,
                lastTime: value.lastMsg.createdAt,
                unreadCount: value.count,
                title: value.lastMsg.title
            )
        }
        .sorted {
            if $0.roomId == "waippo" && $1.roomId != "waippo" { return true }
            if $0.roomId != "waippo" && $1.roomId == "waippo" { return false }
            if $0.roomId == "com.watchnotify.syslog" { return false }
            if $1.roomId == "com.watchnotify.syslog" { return true }
            return $0.lastTime > $1.lastTime
        }
    }
    
    var body: some View {
        List {
            ForEach(chatRooms) { room in
                NavigationLink(
                    destination: ChatRoomDetailView(
                        roomId: room.roomId,
                        roomName: room.appName
                    )
                ) {
                    ChatRoomRow(room: room)
                }
            }
            Button(action: onReconnect) {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text("재연결")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("워치 재연결")
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }
}

// MARK: - 채팅방 행

struct ChatRoomRow: View {
    let room: ChatRoom

    var body: some View {
        HStack(spacing: 8) {
            assetImage(for: room.roomId)
                .resizable()
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(room.appName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(timeString(room.lastTime))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Text(room.lastMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if room.unreadCount > 0 {
                Text("\(room.unreadCount)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private func assetImage(for roomId: String) -> Image {
        let name: String
        switch roomId {
        case "waippo", "kakao_family", "kakao_hwado", "kakao_etc":
            name = "icon_kakao"
        case "com.lguplus.aicallagent", "com.uplus.ubizai":
            name = "icon_call"
        case "com.samsung.android.messaging", "com.android.mms":
            name = "icon_message"
        case "daangn":
            name = "icon_dg"
        case "konai":
            name = "icon_kona"
        case "hana":
            name = "icon_hana"
        case "shinhan":
            name = "icon_sh"
        case "kb":
            name = "icon_kb"
        case "naver":
            name = "icon_naver"
        case "teams":
            name = "icon_teams"
        case "gov.gyeonggi.ggcard":
            name = "icon_ggcard"
        case "connection_log":
            return Image(systemName: "doc.text.fill")
        case "com.watchnotify.syslog":
            return Image(systemName: "terminal.fill")
        default:
            name = "icon_kakao"
        }
        return Image(name)
    }

    private func timeString(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "어제"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            return formatter.string(from: date)
        }
    }
}

// MARK: - 채팅방 상세

struct ChatRoomDetailView: View {
    let roomId: String
    let roomName: String

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WatchMessage.createdAt, order: .reverse) private var allMessages: [WatchMessage]

    private var messages: [WatchMessage] {
        allMessages.filter { $0.roomId == roomId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(messages) { message in
                    MessageBubble(message: message)
                        .id(message.persistentModelID)
                }
            }
            .listStyle(.plain)
            .onAppear {
                markRoomAsRead()
                if let last = messages.last {
                    DispatchQueue.main.async {
                        proxy.scrollTo(last.persistentModelID, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle(roomName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func markRoomAsRead() {
        let unread = messages.filter { !$0.isRead }
        guard !unread.isEmpty else { return }
        unread.forEach { $0.isRead = true }
        try? modelContext.save()
    }
}

// MARK: - 메시지 버블

struct MessageBubble: View {
    let message: WatchMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(message.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(timeString(message.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(message.body)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
