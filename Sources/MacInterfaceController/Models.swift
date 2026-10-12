import Carbon
import Foundation

enum AppAction: String, Codable, CaseIterable, Identifiable {
    case toggleInputSource
    case finder
    case toggleApplication = "toggleTerminal" // Keep existing saved shortcuts readable.
    case missionControl
    case launchpad
    case screenSaver
    case applications
    case macro
    case windowLeft, windowRight, windowMaximize, windowRestore, windowCenter, windowCenterHeight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleInputSource: "한/영 입력 소스 전환"
        case .toggleApplication: "앱 표시 / 숨기기"
        case .finder: "Finder 열기"
        case .missionControl: "Mission Control"
        case .launchpad: "Launchpad"
        case .screenSaver: "화면 보호기 시작"
        case .applications: "응용 프로그램 폴더"
        case .macro: "키 연속입력 매크로"
        case .windowLeft: "창 왼쪽 절반"
        case .windowRight: "창 오른쪽 절반"
        case .windowMaximize: "창 최대화"
        case .windowRestore: "창 이전 크기로 복원"
        case .windowCenter: "창 가운데 정렬"
        case .windowCenterHeight: "창 가운데 · 크기 조절"
        }
    }

    var symbol: String {
        switch self {
        case .toggleInputSource: "character.cursor.ibeam"
        case .toggleApplication: "macwindow"
        case .finder: "face.smiling"
        case .missionControl: "rectangle.3.group"
        case .launchpad: "square.grid.3x3.fill"
        case .screenSaver: "moon.stars.fill"
        case .applications: "folder.fill"
        case .macro: "list.bullet.rectangle"
        case .windowLeft: "rectangle.lefthalf.inset.filled"
        case .windowRight: "rectangle.righthalf.inset.filled"
        case .windowMaximize: "arrow.up.left.and.arrow.down.right"
        case .windowRestore: "arrow.uturn.backward"
        case .windowCenter: "align.horizontal.center"
        case .windowCenterHeight: "arrow.up.and.down"
        }
    }
}

enum ShortcutKey: String, Codable, CaseIterable, Identifiable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case one, two, three, four, five, six, seven, eight, nine, zero
    case quote
    case space, tab, enter, escape, backspace, forwardDelete, left, right, up, down, home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quote: "'"
        case .space: "Space"
        case .tab: "Tab"
        case .enter: "Enter"; case .escape: "Esc"
        case .backspace: "Backspace"; case .forwardDelete: "Delete"
        case .left: "←"; case .right: "→"; case .up: "↑"; case .down: "↓"
        case .home: "Home"; case .end: "End"; case .pageUp: "Page Up"; case .pageDown: "Page Down"
        case .one: "1"; case .two: "2"; case .three: "3"; case .four: "4"
        case .five: "5"; case .six: "6"; case .seven: "7"; case .eight: "8"
        case .nine: "9"; case .zero: "0"
        default: rawValue.uppercased()
        }
    }

    var keyCode: UInt32 {
        let codes: [ShortcutKey: Int] = [
            .quote: kVK_ANSI_Quote,
            .a: kVK_ANSI_A, .b: kVK_ANSI_B, .c: kVK_ANSI_C, .d: kVK_ANSI_D,
            .e: kVK_ANSI_E, .f: kVK_ANSI_F, .g: kVK_ANSI_G, .h: kVK_ANSI_H,
            .i: kVK_ANSI_I, .j: kVK_ANSI_J, .k: kVK_ANSI_K, .l: kVK_ANSI_L,
            .m: kVK_ANSI_M, .n: kVK_ANSI_N, .o: kVK_ANSI_O, .p: kVK_ANSI_P,
            .q: kVK_ANSI_Q, .r: kVK_ANSI_R, .s: kVK_ANSI_S, .t: kVK_ANSI_T,
            .u: kVK_ANSI_U, .v: kVK_ANSI_V, .w: kVK_ANSI_W, .x: kVK_ANSI_X,
            .y: kVK_ANSI_Y, .z: kVK_ANSI_Z,
            .one: kVK_ANSI_1, .two: kVK_ANSI_2, .three: kVK_ANSI_3,
            .four: kVK_ANSI_4, .five: kVK_ANSI_5, .six: kVK_ANSI_6,
            .seven: kVK_ANSI_7, .eight: kVK_ANSI_8, .nine: kVK_ANSI_9,
            .zero: kVK_ANSI_0, .space: kVK_Space, .tab: kVK_Tab,
            .enter: kVK_Return, .escape: kVK_Escape, .backspace: kVK_Delete, .forwardDelete: kVK_ForwardDelete,
            .left: kVK_LeftArrow, .right: kVK_RightArrow, .up: kVK_UpArrow, .down: kVK_DownArrow,
            .home: kVK_Home, .end: kVK_End, .pageUp: kVK_PageUp, .pageDown: kVK_PageDown,
            .f1: kVK_F1, .f2: kVK_F2, .f3: kVK_F3, .f4: kVK_F4, .f5: kVK_F5, .f6: kVK_F6,
            .f7: kVK_F7, .f8: kVK_F8, .f9: kVK_F9, .f10: kVK_F10, .f11: kVK_F11, .f12: kVK_F12
        ]
        return UInt32(codes[self] ?? kVK_Space)
    }
}

enum ShortcutModifier: String, Codable, CaseIterable, Identifiable {
    case command, option, control, shift

    var id: String { rawValue }
    var title: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        }
    }

    var carbonMask: UInt32 {
        switch self {
        case .command: UInt32(cmdKey)
        case .option: UInt32(optionKey)
        case .control: UInt32(controlKey)
        case .shift: UInt32(shiftKey)
        }
    }
}

struct ShortcutRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var isEnabled = true
    var key: ShortcutKey
    var modifiers: Set<ShortcutModifier>
    var action: AppAction
    var macro: KeyMacro? = nil
    var windowHeightPercent: Double? = nil
    var windowWidthPercent: Double? = nil
    var templateID: String? = nil
    var targetApplication = ApplicationTarget()

    var actionTitle: String {
        if action == .macro, let name = macro?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return action.title
    }

    var carbonModifiers: UInt32 {
        modifiers.reduce(0) { $0 | $1.carbonMask }
    }

    var displayText: String {
        let order: [ShortcutModifier] = [.control, .option, .shift, .command]
        return order.filter(modifiers.contains).map(\.title).joined() + key.title
    }
}

enum CornerPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft: "왼쪽 위"
        case .topRight: "오른쪽 위"
        case .bottomLeft: "왼쪽 아래"
        case .bottomRight: "오른쪽 아래"
        }
    }

    var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        }
    }
}

struct HotCornerRule: Codable, Identifiable, Equatable {
    var id: CornerPosition { position }
    var position: CornerPosition
    var isEnabled: Bool
    var dwellSeconds: Double
    var action: AppAction
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case keyboard, shortcuts, macros, windowSwitcher, display, corners, dock, checks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keyboard: "키보드"
        case .shortcuts: "단축키"
        case .macros: "매크로"
        case .windowSwitcher: "창 관리"
        case .display: "디스플레이"
        case .dock: "Dock"
        case .corners: "핫 코너"
        case .checks: "설정 점검"
        }
    }
    var symbol: String {
        switch self {
        case .keyboard: "keyboard"
        case .shortcuts: "command"
        case .macros: "list.bullet.rectangle"
        case .windowSwitcher: "rectangle.on.rectangle"
        case .dock: "dock.rectangle"
        case .display: "laptopcomputer"
        case .corners: "arrow.up.left.and.arrow.down.right"
        case .checks: "checkmark.shield"
        }
    }
}

/// Bundle identity remains portable when an application is moved or updated.
struct ApplicationTarget: Codable, Equatable {
    var bundleIdentifier = ""
    var name = ""
    var isConfigured: Bool { !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var displayName: String {
        if bundleIdentifier == "com.apple.Terminal" && ["터미널", "Terminal"].contains(name) { return L10n.text("터미널") }
        return name
    }
    static let terminal = ApplicationTarget(bundleIdentifier: "com.apple.Terminal", name: "터미널")
}

extension ShortcutRule {
    enum CodingKeys: String, CodingKey {
        case id, isEnabled, key, modifiers, action, macro, windowHeightPercent, windowWidthPercent, templateID, targetApplication
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        key = try values.decode(ShortcutKey.self, forKey: .key)
        modifiers = try values.decode(Set<ShortcutModifier>.self, forKey: .modifiers)
        action = try values.decode(AppAction.self, forKey: .action)
        macro = try values.decodeIfPresent(KeyMacro.self, forKey: .macro)
        windowHeightPercent = try values.decodeIfPresent(Double.self, forKey: .windowHeightPercent)
        windowWidthPercent = try values.decodeIfPresent(Double.self, forKey: .windowWidthPercent)
        templateID = try values.decodeIfPresent(String.self, forKey: .templateID)
        targetApplication = try values.decodeIfPresent(ApplicationTarget.self, forKey: .targetApplication)
            ?? (action == .toggleApplication ? .terminal : ApplicationTarget())
    }
}
