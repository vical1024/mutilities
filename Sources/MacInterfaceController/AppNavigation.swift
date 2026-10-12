import SwiftUI

final class AppNavigation: ObservableObject {
    @Published var selection: SidebarItem? = .keyboard
    @Published private(set) var checkSection: CheckSection = .setup

    func openCheck(_ section: CheckSection) {
        if checkSection != section { checkSection = section }
        if selection != .checks { selection = .checks }
    }
}

enum CheckSection: String, CaseIterable, Identifiable {
    case setup, permissions, conflicts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setup: "초기 설정·백업·복구"
        case .permissions: "권한"
        case .conflicts: "충돌 검사"
        }
    }
}
