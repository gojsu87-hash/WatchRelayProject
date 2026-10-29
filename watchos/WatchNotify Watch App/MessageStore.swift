// MessageStore.swift
// SwiftData 모델 및 패키지 분류 규칙 소스코드

import SwiftData
import Foundation

@Model
class WatchMessage {
    var id: Int64; var pkg: String; var title: String
    var body: String; var createdAt: Date; var isRead: Bool

    init(id: Int64, pkg: String, title: String, body: String) {
        self.id = id; self.pkg = pkg; self.title = title
        self.body = body; self.createdAt = Date(); self.isRead = false
    }

    @Transient var isWaippo: Bool { pkg == "com.kakao.talk" && title.contains("와이뽀") }

    @Transient var roomId: String {
        if isWaippo { return "waippo" }
        if pkg == "com.watchnotify.log" { return "connection_log" }
        if pkg == "com.watchnotify.syslog" { return "com.watchnotify.syslog" }

        if pkg == "com.kakao.talk" {
            let familyNames = ["엄마", "아빠", "누나"]
            let hwadoNames = ["홍선기", "박주원", "윤부자"]
            if familyNames.contains(title) { return "kakao_family" }
            if hwadoNames.contains(title) { return "kakao_hwado" }
            return "kakao_etc"
        }
        switch pkg {
        case "com.lguplus.aicallagent", "com.uplus.ubizai":
            return "com.lguplus.aicallagent"
        case "com.samsung.android.messaging", "com.android.mms":
            return pkg
        case "com.towneers.www":
            return "daangn"
        case "com.konai.konamoney", "com.kona.card":
            return "konai"
        case "com.nhn.android.search":
            return "naver"
        case "com.hanabank.oqf", "com.kebhana.hanapush",
             "com.hanaskcard.paycla", "kr.co.hanamembers.hmscustomer":
            return "hana"
        case "com.shinhan.sbanking", "com.shinhan.smartcaremgr",
             "com.shinhancard.smart":
            return "shinhan"
        case "com.kbstar.kbbank", "com.kbcard.cxh.appcard":
            return "kb"
        case "com.microsoft.teams":
            return "teams"
        default:
            return "etc"
        }
    }
}

struct ChatRoom: Identifiable {
    let id: String; let pkg: String; let roomId: String
    let lastMessage: String; let lastTime: Date; let unreadCount: Int
    let title: String

    var appName: String {
        switch roomId {
        case "waippo":                  return "와이뽀❤️"
        case "kakao_family":            return "우리가족"
        case "kakao_hwado":             return "화도"
        case "kakao_etc":               return "카카오톡"
        case "com.lguplus.aicallagent": return "전화"
        case "com.samsung.android.messaging",
             "com.android.mms":         return "문자"
        case "daangn":                  return "당근"
        case "konai":                   return "코나카드"
        case "naver":                   return "네이버"
        case "hana":                    return "하나은행"
        case "shinhan":                 return "신한"
        case "kb":                      return "국민은행"
        case "teams":                   return "Teams"
        case "etc":                     return "알림"
        case "connection_log":          return "연결로그"
        case "com.watchnotify.syslog":  return "시스템로그"
        default:                        return title
        }
    }

    var emoji: String {
        switch roomId {
        case "waippo", "kakao_family", "kakao_hwado", "kakao_etc":
            return "message.fill"
        case "com.lguplus.aicallagent":
            return "phone.fill"
        case "com.samsung.android.messaging",
             "com.android.mms":
            return "bubble.left.fill"
        case "daangn":
            return "leaf.fill"
        case "konai":
            return "creditcard.fill"
        case "naver":
            return "magnifyingglass"
        case "hana", "shinhan", "kb":
            return "building.columns.fill"
        case "connection_log":
            return "list.bullet.clipboard.fill"
        case "com.watchnotify.syslog":
            return "terminal"
        case "teams":
            return "person.3.fill"
        default:
            return "bell.fill"
        }
    }
}
