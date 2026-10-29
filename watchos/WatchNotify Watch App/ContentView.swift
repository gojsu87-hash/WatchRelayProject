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
            VStack(spacing: 0) {
                ChatRoomListView(messages: messages)
                    .navigationTitle("")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            // 상단 상태 표시를 작은 인디케이터 점(Dot)만 노출
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                                .offset(y: -10)
                        }
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

    private var statusColor: Color {
        switch bleManager.connectionState {
        case .operational: return .green
        case .connected: return .orange
        case .offline: return .gray
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
