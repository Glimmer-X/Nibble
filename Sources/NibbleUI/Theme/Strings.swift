import Foundation
import NibbleCore

/// The interface's language.
enum Language: String, Sendable {
    case chinese
    case english

    /// The language a setting resolves to: the system's first preferred language when it says
    /// "system", Chinese for any Chinese, English otherwise.
    init(_ setting: LanguageSetting) {
        switch setting {
        case .chinese: self = .chinese
        case .english: self = .english
        case .system:
            let first = Locale.preferredLanguages.first ?? "zh-Hans"
            self = first.hasPrefix("zh") ? .chinese : .english
        }
    }
}

/// Every string the interface shows, in both languages side by side, so the panel can switch
/// language at once from its own settings. Words from the reader's side: short and plain.
struct Strings {
    let language: Language

    private func t(_ zh: String, _ en: String) -> String { language == .chinese ? zh : en }

    // MARK: Composer and keys

    var placeholder: String { t("随便问点什么…", "Ask anything…") }
    var send: String { t("发送", "Send") }
    var stop: String { t("停止", "Stop") }
    var capture: String { t("截屏", "Capture screen") }
    var newChat: String { t("新对话", "New chat") }
    var settings: String { t("设置", "Settings") }
    var settingsMenu: String { t("设置…", "Settings…") }
    var close: String { t("关闭", "Close") }
    var back: String { t("返回", "Back") }
    var remove: String { t("移除", "Remove") }
    var copy: String { t("复制", "Copy") }
    var copied: String { t("已复制", "Copied") }
    var retry: String { t("重试", "Retry") }
    var editQuestion: String { t("编辑", "Edit") }
    var cancelEditing: String { t("取消编辑", "Cancel edit") }
    var setUpService: String { t("还没设置好服务", "No service set up yet") }
    var goSetUp: String { t("去设置", "Set up") }
    var allow: String { t("允许", "Allow") }
    var deny: String { t("拒绝", "Deny") }
    var allowForConversation: String { t("本对话都允许", "Allow for this chat") }
    var allowForConversationHelp: String { t("这段对话里同类命令不再询问", "Commands like this one run without asking for the rest of this chat") }
    var stopped: String { t("已停止", "Stopped") }
    var collapse: String { t("收起", "Collapse") }
    var expand: String { t("展开", "Expand") }
    var persona: String { t("人格", "Persona") }

    var capturePermission: String {
        t("截屏需要“屏幕与系统录音”权限。在系统设置里打开后，重新启动 Nibble。",
          "Capturing needs Screen & System Audio Recording permission. Turn it on in System Settings, then restart Nibble.")
    }
    var save: String { t("保存", "Save") }

    func screenshot(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        return t("截屏 \(time)", "Screenshot \(time)")
    }

    // MARK: Status line

    var waiting: String { t("等待回应", "Waiting for a reply") }

    func activity(_ activity: Activity) -> String {
        let label: String = switch activity.kind {
        case .thinking: t("思考中", "Thinking")
        case .searching: t("搜索", "Searching")
        case .reading: t("阅读", "Reading")
        case .looking: t("看图", "Looking at the image")
        case .tool: t("运行", "Running")
        }
        guard let detail = activity.detail, !detail.isEmpty, activity.kind != .thinking else {
            return activity.kind == .tool ? t("运行工具", "Running a tool") : label
        }
        return t("\(label) \(detail)", "\(label) \(detail)")
    }

    func working(_ label: String, seconds: Int) -> String { t("\(label) · \(seconds) 秒", "\(label) · \(seconds)s") }
    func writing(tokensPerSecond n: Int) -> String { t("输出中 · \(n) token/s", "Writing · \(n) tokens/s") }
    func attention(_ what: String) -> String { t("等你确认 · \(what)", "Needs your OK · \(what)") }
    func thought(seconds: Int) -> String { t("思考了 \(seconds) 秒", "Thought for \(seconds)s") }

    // MARK: The strip

    var needsOK: String { t("等你确认", "Needs your OK") }
    /// A reply that failed, on the strip: one word, like a device's display.
    var failed: String { "ERROR" }

    func done(thoughtFor seconds: Int?) -> String {
        guard let seconds else { return t("完成", "Done") }
        return t("完成 · 思考了 \(seconds) 秒", "Done · Thought for \(seconds)s")
    }

    // MARK: Errors

    /// A failed request, in a sentence the reader can act on.
    func describe(_ error: any Error, backend: BackendSettings.Kind) -> String {
        guard let error = error as? BackendError else { return error.localizedDescription }
        let hermes = backend == .hermes
        switch error {
        case .notConfigured:
            if hermes {
                return t("还没设置好。到设置里连上 Hermes，或者换一个服务。", "Not set up yet. In Settings, connect Hermes or pick another service.")
            }
            return backend == .openAI
                ? t("还没设置好。到设置里填好地址和模型。", "Not set up yet. Fill in the address and model in Settings.")
                : t("还没设置好。到设置里填好模型和密钥。", "Not set up yet. Fill in the model and key in Settings.")
        case .cannotConnect(let address):
            return hermes
                ? t("连不上 Hermes（\(address)）。确认 hermes gateway 正在运行，然后重试。",
                    "Can't reach Hermes at \(address). Check that hermes gateway is running, then try again.")
                : t("连不上 \(address)。检查地址和网络，然后重试。", "Could not reach \(address). Check the address and the network, then retry.")
        case .unauthorized:
            return hermes
                ? t("Hermes 不接受这个密钥。检查这个人格的 API_SERVER_KEY。", "Hermes refused the key. Check this persona's API_SERVER_KEY.")
                : t("密钥不对，请求被拒绝了。到设置里检查密钥。", "The key was refused. Check it in Settings.")
        case .rateLimited:
            return t("请求太多，暂时被拒绝了。稍等一会儿再重试。", "Too many requests for now. Wait a moment, then retry.")
        case .server(let status, let message):
            return t("出错了（\(status)）。\(message ?? "")", "Something went wrong (\(status)). \(message ?? "")")
                .trimmingCharacters(in: .whitespaces)
        case .timedOut:
            return t("等了太久没有回应。重试一下。", "No answer for too long. Try again.")
        case .invalidResponse:
            return t("收到的回应读不懂。", "The reply could not be read.")
        case .failed(let message):
            return message
        case .unsupported:
            return t("这个后端做不到。", "This backend can't do that.")
        }
    }

    // MARK: Settings

    var settingsTitle: String { t("设置", "Settings") }
    var backendSection: String { t("连接", "Connection") }
    /// The backend that answers: Hermes or one of the model APIs.
    var service: String { t("服务", "Service") }
    func backendName(_ kind: BackendSettings.Kind) -> String {
        switch kind {
        case .hermes: "Hermes"
        case .openAI: t("OpenAI 兼容", "OpenAI-compatible")
        case .gemini: "Gemini"
        case .anthropic: "Claude"
        }
    }
    var noPersona: String { t("默认", "Default") }
    var newPersona: String { t("新人格", "New persona") }
    var addPersona: String { t("新建", "New") }
    func personaName(_ persona: Persona) -> String {
        let name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? t("未命名", "Untitled") : name
    }
    var personaNamePlaceholder: String { t("名称", "Name") }
    var promptPlaceholder: String {
        t("系统提示词，比如回答的语气和擅长的领域", "System prompt, such as the tone of the answers and what to focus on")
    }
    var noPersonaNote: String { t("不附加系统提示词。", "Questions go without a system prompt.") }
    var revert: String { t("撤销修改", "Revert") }
    var managePersonas: String { t("管理人格", "Manage Personas") }
    var more: String { t("更多", "More") }
    var address: String { t("地址", "Address") }
    var key: String { t("密钥", "Key") }
    var keyFromHermes: String { t("用 Hermes 里的", "From Hermes") }
    var keyPlaceholder: String { t("粘贴密钥", "Paste a key") }
    var keySaved: String { t("已存进钥匙串", "In Keychain") }
    var model: String { t("模型", "Model") }
    /// The Hermes profile's own model, in the model list.
    var defaultModel: String { t("默认", "Default") }
    var useDefaultModel: String { t("改回默认", "Use Default") }
    var connected: String { t("已连接", "Connected") }
    var checking: String { t("检查中…", "Checking…") }
    var unreachable: String { t("连不上", "Not reachable") }
    var keyRefused: String { t("密钥不对", "Key refused") }
    var notSet: String { t("未设置", "Not set") }
    var chatsSection: String { t("快捷键与对话", "Shortcut & chats") }
    var hotKey: String { t("唤出", "Summon") }
    var recording: String { t("按下组合键…", "Press keys…") }
    /// "与 ChatGPT、聚焦搜索的快捷键冲突".
    func conflict(_ conflicts: [HotKeyConflict]) -> String {
        let names = conflicts.map(conflictName)
        return t("与 \(names.joined(separator: "、")) 的快捷键冲突", "Conflicts with \(names.joined(separator: ", "))")
    }

    private func conflictName(_ conflict: HotKeyConflict) -> String {
        switch conflict {
        case .app(let name): name
        case .taken: t("系统快捷键", "a system shortcut")
        case .system(let shortcut):
            switch shortcut {
            case .spotlight: t("聚焦搜索", "Spotlight")
            case .finderSearch: t("访达搜索", "Finder search")
            case .inputSource: t("切换输入法", "input source switching")
            case .missionControl: t("调度中心", "Mission Control")
            case .appWindows: t("应用程序窗口", "App Exposé")
            case .switchSpace: t("切换桌面", "Space switching")
            case .screenshot: t("截屏", "screenshots")
            case .screenshotTool: t("截屏工具", "the screenshot tool")
            case .helpMenu: t("帮助菜单", "the Help menu")
            case .dockHiding: t("程序坞隐藏", "Dock hiding")
            }
        case .common(let shortcut):
            switch shortcut {
            case .quit: t("退出", "Quit")
            case .closeWindow: t("关闭窗口", "Close Window")
            case .copy: t("拷贝", "Copy")
            case .paste: t("粘贴", "Paste")
            case .cut: t("剪切", "Cut")
            case .undo: t("撤销", "Undo")
            case .redo: t("重做", "Redo")
            case .selectAll: t("全选", "Select All")
            case .save: t("存储", "Save")
            case .new: t("新建", "New")
            case .newTab: t("新建标签页", "New Tab")
            case .open: t("打开", "Open")
            case .print: t("打印", "Print")
            case .find: t("查找", "Find")
            case .hide: t("隐藏", "Hide")
            case .minimize: t("最小化", "Minimize")
            case .switchApps: t("切换应用", "app switching")
            case .switchWindows: t("切换窗口", "window switching")
            }
        }
    }
    var continueLabel: String { t("接着上次", "Continue") }
    func within(minutes: Int) -> String { t("\(minutes) 分钟内", "within \(minutes) min") }
    var lookSection: String { t("外观", "Appearance") }
    var mode: String { t("模式", "Mode") }
    func appearance(_ setting: AppearanceSetting) -> String {
        switch setting {
        case .system: t("跟随系统", "System")
        case .light: t("浅色", "Light")
        case .dark: t("深色", "Dark")
        }
    }
    var languageLabel: String { t("语言", "Language") }
    var colorLabel: String { t("颜色", "Colour") }
    func theme(_ theme: ColorTheme) -> String {
        switch theme {
        case .violet: t("紫", "Violet")
        case .teal: t("青", "Teal")
        case .blue: t("蓝", "Blue")
        case .rose: t("粉", "Rose")
        case .orange: t("橙", "Orange")
        case .amber: t("琥珀", "Amber")
        }
    }
    var textSizeLabel: String { t("字号", "Text size") }
    func textSize(_ size: TextSize) -> String {
        switch size {
        case .small: t("小", "Small")
        case .medium: t("中", "Medium")
        case .large: t("大", "Large")
        }
    }
    var backgroundLabel: String { t("基础动效", "Idle light") }
    func background(_ motion: BackgroundMotion) -> String {
        switch motion {
        case .lava: t("熔岩灯", "Lava lamp")
        case .stars: t("星空", "Stars")
        case .tunnel: t("时光隧道", "Tunnel")
        case .glimmer: t("微光", "Glimmer")
        case .ripple: t("水波纹", "Ripples")
        }
    }
    func language(_ setting: LanguageSetting) -> String {
        switch setting {
        case .system: t("跟随系统", "System")
        case .chinese: "中文"
        case .english: "English"
        }
    }
    var dataSection: String { t("数据", "Data") }
    var keep: String { t("保留", "Keep") }
    func days(_ n: Int) -> String { t("\(n) 天", "\(n) days") }
    var location: String { t("位置", "Location") }

    var dockSection: String { t("应用", "App") }
    var showInDock: String { t("在程序坞显示", "Show in Dock") }
    var openAtLogin: String { t("登录时打开", "Open at login") }
    func sendKey(_ key: SendKey) -> String {
        switch key {
        case .return: t("回车", "Return")
        case .commandReturn: t("⌘ 回车", "⌘ Return")
        }
    }
    var screenCapture: String { t("截屏", "Screen capture") }
    var allowed: String { t("已允许", "Allowed") }
    var notAllowed: String { t("还没允许", "Not allowed") }
    var openSystemSettings: String { t("打开系统设置", "Open System Settings") }
    func version(_ version: String, build: String) -> String { t("版本 \(version)（\(build)）", "Version \(version) (\(build))") }
    var tagline: String {
        t("随时在 Mac 上呼出的 AI 助手。可以直接连接模型 API，也可以通过 Hermes 处理更复杂的任务。",
          "An AI assistant you can bring up anytime on your Mac. Connect directly to a model's API, or use Hermes for more complex tasks.")
    }
    var loginItemFailed: String {
        t("没能更改登录项。可以到系统设置的“登录项”里更改。", "Couldn't change the login item. You can change it in System Settings › Login Items.")
    }
    var quickChatSection: String { t("浮窗", "Quick chat") }

    // MARK: Updates

    func newVersion(_ version: String) -> String { t("有新版本 \(version)", "Version \(version) is available") }
    var download: String { t("下载", "Download") }
    var ignore: String { t("忽略", "Ignore") }
    var versionLabel: String { t("版本", "Version") }
    var checkForUpdates: String { t("检查更新", "Check for updates") }
    /// The switch for the daily check.
    var updateCheck: String { t("自动检查更新", "Check daily") }
    var upToDate: String { t("已是最新版本", "Up to date") }
    var checkFailed: String { t("没能检查，稍后再试", "Couldn't check. Try later.") }

    // MARK: Main window

    func page(_ page: MainPage) -> String {
        switch page {
        case .home: t("首页", "Home")
        case .history: t("历史", "History")
        case .settings: t("设置", "Settings")
        case .about: t("关于", "About")
        }
    }

    var quickChat: String { t("浮窗", "Quick chat") }
    var askedToday: String { t("今天提问", "Asked today") }
    var tokensWeek: String { t("近 7 天 token", "Tokens, 7 days") }
    var averageSpeed: String { t("平均速度", "Average speed") }
    var averageWait: String { t("平均等待", "Average wait") }
    var perSecond: String { "token/s" }
    var secondsUnit: String { t("秒", "s") }
    var lastDays: String { t("最近 14 天", "Last 14 days") }
    var lastWeek: String { t("最近 7 天", "Last 7 days") }
    var questionsLabel: String { t("提问", "Questions") }
    var tokensLabel: String { "token" }
    var personasLabel: String { t("人格", "Personas") }
    var recentChats: String { t("最近的对话", "Recent chats") }
    func noChatsYet(_ hotKey: String) -> String {
        t("还没有对话。按 \(hotKey) 问点什么。", "No chats yet. Press \(hotKey) to ask something.")
    }
    func questions(_ n: Int) -> String { t("\(n) 问", n == 1 ? "1 question" : "\(n) questions") }
    func tokens(_ n: String) -> String { t("\(n) token", "\(n) tokens") }
    func dayValue(_ date: Date, _ value: String) -> String { "\(day(date)) · \(value)" }

    var searchChats: String { t("搜索对话", "Search chats") }
    var today: String { t("今天", "Today") }
    var yesterday: String { t("昨天", "Yesterday") }
    var continueInPanel: String { t("在浮窗里继续", "Continue in quick chat") }
    var delete: String { t("删除", "Delete") }
    var confirmDelete: String { t("再点一次删除", "Click again to delete") }
    var nothingFound: String { t("没有找到", "Nothing found") }
    var clearHistory: String { t("清空全部历史", "Clear all history") }
    var confirmClear: String { t("再点一次清空", "Click again to clear") }
    var image: String { t("图片", "Image") }
    func answerMeta(thought: Int?, speed: Int?) -> String {
        var parts: [String] = []
        if let thought { parts.append(t("思考 \(thought) 秒", "thought \(thought)s")) }
        if let speed { parts.append("\(speed) token/s") }
        return parts.joined(separator: " · ")
    }

    /// A day in lists: today, yesterday, or the date.
    func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return today }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return yesterday }
        return shortDate(date)
    }

    func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .chinese ? "zh_CN" : "en_GB")
        formatter.setLocalizedDateFormatFromTemplate(language == .chinese ? "Md" : "dMMM")
        return formatter.string(from: date)
    }

    func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    // MARK: The conversation page (the panel's menu key)

    var thisChat: String { t("这段对话", "This chat") }
    var speedLabel: String { t("速度", "Speed") }
    var waitLabel: String { t("等待", "Wait") }
    func context(_ tokens: String) -> String { t("上下文 \(tokens) token", "Context \(tokens) tokens") }
    func failures(_ n: Int) -> String { t("出错 \(n) 次", n == 1 ? "1 failed" : "\(n) failed") }
    var answerSpeeds: String { t("每次回答的速度", "Speed of each answer") }
    var allChats: String { t("全部对话", "All chats") }
    var noOtherChats: String { t("还没有别的对话", "No other chats yet") }
    var noChats: String { t("还没有对话", "No chats yet") }

    // MARK: Menus

    var openNibble: String { t("打开 Nibble", "Open Nibble") }
    var showQuickChat: String { t("唤出浮窗", "Show quick chat") }
    /// The menu bar panel's key, short enough for its tile.
    var quickChatTile: String { t("唤出浮窗", "Quick chat") }
    var quitNibble: String { t("退出 Nibble", "Quit Nibble") }
    var quit: String { t("退出", "Quit") }
    var aboutNibble: String { t("关于 Nibble", "About Nibble") }
    var hideNibble: String { t("隐藏 Nibble", "Hide Nibble") }
    var hideOthers: String { t("隐藏其他", "Hide Others") }
    var showAll: String { t("全部显示", "Show All") }
    var edit: String { t("编辑", "Edit") }
    var undo: String { t("撤销", "Undo") }
    var redo: String { t("重做", "Redo") }
    var cut: String { t("剪切", "Cut") }
    var copyMenu: String { t("拷贝", "Copy") }
    var paste: String { t("粘贴", "Paste") }
    var selectAll: String { t("全选", "Select All") }
    var window: String { t("窗口", "Window") }
    var minimize: String { t("最小化", "Minimize") }
    var closeWindow: String { t("关闭窗口", "Close Window") }
}
