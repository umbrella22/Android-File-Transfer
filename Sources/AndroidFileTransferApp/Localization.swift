import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
}

@MainActor
@Observable
final class Localization {
    private static let defaultsKey = "appLanguage"

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
            ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: raw) ?? .system
    }

    var effectiveLanguage: AppLanguage {
        if language != .system {
            return language
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    func t(_ key: String, _ arguments: CVarArg...) -> String {
        let format: String
        switch effectiveLanguage {
        case .simplifiedChinese:
            format = Self.chinese[key] ?? Self.english[key] ?? key
        default:
            format = Self.english[key] ?? key
        }
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments)
    }

    func displayName(for language: AppLanguage) -> String {
        switch language {
        case .system:
            return t("general.system")
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    private static let english: [String: String] = [
        "favorites.home": "Home",
        "favorites.desktop": "Desktop",
        "favorites.downloads": "Downloads",
        "favorites.documents": "Documents",
        "sidebar.favorites": "Favorites",
        "sidebar.devices": "Devices",
        "sidebar.noDevice": "No Android device",
        "sidebar.refresh": "Refresh",

        "access.title": "File Access Permissions",
        "access.subtitle": "Choose how Android File Transfer may read protected folders and external volumes.",
        "access.files.title": "On-demand access (recommended)",
        "access.files.body": "When you open Documents, Downloads, or a removable volume, macOS asks once. Choose Allow. If you previously denied access, enable Android File Transfer here.",
        "access.files.open": "Open Files and Folders Settings",
        "access.files.note": "This page does not accept drag-and-drop.",
        "access.fda.title": "Full Disk Access (optional)",
        "access.fda.body": "Grants access to all locations in one step. Drag the Android File Transfer icon into the list, or click + and choose Android File Transfer.app.",
        "access.fda.drag": "Drag this icon into the list",
        "access.fda.dragHint": "Open the settings below, then drag the icon across.",
        "access.fda.dragHelp": "Drag Android File Transfer into Full Disk Access",
        "access.fda.open": "Open Full Disk Access Settings",
        "access.fda.reveal": "Show Android File Transfer in Finder",
        "access.fda.granted": "Granted",
        "access.fda.notGranted": "Not granted",
        "access.fda.statusNote": "Status reflects Full Disk Access only.",
        "access.recheck": "Check Again",
        "access.done": "Done",
        "settings.permissions": "Permissions",
        "settings.accessGuide": "File Access Permissions…",
        "onboarding.access": "File Access Permissions…",
        "header.back": "Back",
        "local.accessDenied": "Android File Transfer doesn’t have permission to read this folder. Allow access in System Settings → Privacy & Security → Files and Folders, then refresh.",
        "local.openPrivacySettings": "Open Privacy Settings",
        "header.up": "Enclosing folder",
        "header.refresh": "Refresh",
        "header.upload": "Upload",
        "header.download": "Download",
        "header.delete": "Delete",
        "header.quickLook": "Quick Look",

        "column.name": "Name",
        "column.size": "Size",
        "column.dateModified": "Date Modified",
        "context.open": "Open",
        "transfer.dismiss": "Dismiss",

        "toolbar.transfers": "Transfers",
        "queue.title": "Transfers",
        "queue.empty": "No transfers",
        "queue.start": "Start",
        "queue.pause": "Pause",
        "queue.resume": "Resume",
        "queue.cancelCurrent": "Cancel Current",
        "queue.clearCompleted": "Clear Completed",
        "queue.done": "Done",
        "queue.retry": "Retry",
        "queue.remove": "Remove",
        "queue.interrupted": "Interrupted by app exit",
        "queue.state.pending": "Pending",
        "queue.state.running": "Running",
        "queue.state.paused": "Paused",
        "queue.state.completed": "Completed",
        "queue.state.failed": "Failed",
        "queue.state.canceled": "Canceled",
        "queue.direction.download": "Download",
        "queue.direction.upload": "Upload",

        "status.items": "%d items",
        "status.selected": "· %d selected",
        "status.free": "%@ free",

        "empty.noDevice.title": "No Android device",
        "empty.noDevice.description": "Connect your phone with USB, unlock it, and choose File Transfer / MTP.",
        "empty.noDevice.refresh": "Refresh",
        "empty.selectStorage.title": "Select a storage",
        "empty.selectStorage.description": "Choose Internal storage or the SD card in the sidebar.",
        "empty.error.title": "Cannot list this folder",
        "empty.error.retry": "Retry",

        "transfer.preparing": "Preparing %@…",
        "transfer.downloading": "Downloading %@",
        "transfer.uploading": "Uploading %@",
        "transfer.deleting": "Deleting…",
        "transfer.cancel": "Cancel",
        "transfer.canceling": "Canceling transfer…",
        "transfer.pause": "Pause",
        "transfer.resume": "Resume",
        "transfer.paused": "Paused",
        "transfer.retry": "Retry",
        "transfer.done": "Done",
        "transfer.canceled": "Canceled",
        "transfer.savedDownloads": "Saved to Downloads",
        "transfer.savedFolder": "Saved folder to Downloads",
        "transfer.uploadedTo": "Uploaded to %@",
        "transfer.uploaded": "Uploaded %@",
        "transfer.deleted": "Deleted",

        "alerts.noDevice": "No Android device is connected.",
        "alerts.noStorage": "No Android storage is selected.",
        "alerts.selectPhone": "Select a file or folder on the phone first.",
        "alerts.selectLocal": "Select a local file or folder first.",
        "alerts.transferRunning": "A transfer is already running.",
        "alerts.symlink": "Symbolic links are not uploaded. Choose the real file or folder.",
        "alerts.nameExists": "A file named “%@” already exists in this folder.",
        "alerts.debugFileNotFound": "Debug file %@ not found in Home.",
        "alerts.testFolderNotVisible": "Test folder not visible in Downloads.",
        "alerts.testFolderNotFound": "AndroidFileTransferKitUITest folder not found on the phone.",
        "alerts.noDeviceFile": "No device file available.",
        "alerts.couldNotCreateTestFolder": "Could not create test folder: %@",

        "conflict.title": "Items already exist",
        "conflict.message": "%d item(s) already exist in the destination.",
        "conflict.replace": "Replace",
        "conflict.keepBoth": "Keep Both",
        "conflict.cancel": "Cancel",
        "conflict.replaceWarning": "Replace deletes the existing item(s) at the destination.",

        "delete.title": "Delete from phone?",
        "delete.message": "Delete %d item(s) from the phone? This cannot be undone.",
        "delete.confirm": "Delete",
        "delete.cancel": "Cancel",

        "general.ok": "OK",
        "general.cancel": "Cancel",
        "general.delete": "Delete",
        "general.refresh": "Refresh",
        "general.language": "Language",
        "general.system": "System",

        "settings.title": "Settings",
        "settings.general": "General",
        "settings.browsing": "Browsing",
        "settings.showHiddenFiles": "Show hidden files",
        "settings.about": "About",
        "settings.version": "Version %@",

        "onboarding.title": "Welcome to Android File Transfer",
        "onboarding.subtitle": "Transfer files between your Mac and Android over USB.",
        "onboarding.step1": "Connect your phone with a USB cable.",
        "onboarding.step2": "Unlock the phone and choose File Transfer / MTP.",
        "onboarding.step3": "Drag files between the two panes, or use Upload / Download.",
        "onboarding.done": "Get Started",

        "debug.menu": "Debug",
        "debug.uploadHome": "Upload skills-lock.json from Home",
        "debug.downloadFirst": "Download First Device File",
        "debug.uploadTestFolder": "Upload Test Folder",
        "debug.downloadTestFolder": "Download Test Folder",
        "debug.deleteTestFolders": "Delete Test Folders Now",
        "debug.resetUSB": "Reset USB Device",
        "debug.disconnectDevice": "Disconnect Device (Test)",
        "debug.quickLookHome": "Quick Look skills-lock.json",
        "debug.quickLookDevice": "Quick Look First Device File",
        "debug.testDrag": "Test Drag Provider",
        "debug.testFolderDrag": "Test Folder Drag Provider",
        "debug.uploadLarge": "Upload 64MB Test File",
        "debug.cancelTransfer": "Cancel Current Transfer",
        "debug.pauseTransfer": "Pause Current Transfer",
        "debug.resumeQueue": "Resume Queue",
    ]

    private static let chinese: [String: String] = [
        "favorites.home": "个人",
        "favorites.desktop": "桌面",
        "favorites.downloads": "下载",
        "favorites.documents": "文稿",
        "sidebar.favorites": "个人收藏",
        "sidebar.devices": "设备",
        "sidebar.noDevice": "未连接 Android 设备",
        "sidebar.refresh": "刷新",

        "access.title": "文件访问权限",
        "access.subtitle": "选择 Android File Transfer 读取受保护文件夹和外接卷的方式。",
        "access.files.title": "按需授权（推荐）",
        "access.files.body": "首次打开“文档”“下载”或可移除卷时，macOS 会询问一次，选择“允许”即可。如果之前拒绝过，请在此页面为 Android File Transfer 打开开关。",
        "access.files.open": "打开“文件与文件夹”设置",
        "access.files.note": "此页面不支持拖拽添加 App。",
        "access.fda.title": "完全磁盘访问权限（可选）",
        "access.fda.body": "一次授权所有位置。将 Android File Transfer 图标拖入列表，或点击 + 选择 Android File Transfer.app。",
        "access.fda.drag": "将此图标拖入列表",
        "access.fda.dragHint": "先打开下方设置，再把图标拖过去。",
        "access.fda.dragHelp": "将 Android File Transfer 拖入完全磁盘访问权限",
        "access.fda.open": "打开“完全磁盘访问权限”设置",
        "access.fda.reveal": "在 Finder 中显示 Android File Transfer",
        "access.fda.granted": "已授权",
        "access.fda.notGranted": "未授权",
        "access.fda.statusNote": "状态仅反映完全磁盘访问权限。",
        "access.recheck": "重新检查",
        "access.done": "完成",
        "settings.permissions": "权限",
        "settings.accessGuide": "文件访问权限…",
        "onboarding.access": "文件访问权限…",
        "header.back": "后退",
        "local.accessDenied": "Android File Transfer 没有权限读取此文件夹。请在“系统设置”→“隐私与安全性”→“文件与文件夹”中允许访问，然后刷新。",
        "local.openPrivacySettings": "打开隐私设置",
        "header.up": "上一级",
        "header.refresh": "刷新",
        "header.upload": "上传",
        "header.download": "下载",
        "header.delete": "删除",
        "header.quickLook": "快速查看",

        "column.name": "名称",
        "column.size": "大小",
        "column.dateModified": "修改日期",
        "context.open": "打开",
        "transfer.dismiss": "关闭",

        "toolbar.transfers": "传输队列",
        "queue.title": "传输队列",
        "queue.empty": "没有传输任务",
        "queue.start": "开始",
        "queue.pause": "暂停",
        "queue.resume": "继续",
        "queue.cancelCurrent": "取消当前",
        "queue.clearCompleted": "清除已完成",
        "queue.done": "完成",
        "queue.retry": "重试",
        "queue.remove": "移除",
        "queue.interrupted": "应用退出时中断",
        "queue.state.pending": "等待中",
        "queue.state.running": "进行中",
        "queue.state.paused": "已暂停",
        "queue.state.completed": "已完成",
        "queue.state.failed": "失败",
        "queue.state.canceled": "已取消",
        "queue.direction.download": "下载",
        "queue.direction.upload": "上传",

        "status.items": "%d 项",
        "status.selected": "· 已选 %d 项",
        "status.free": "%@ 可用",

        "empty.noDevice.title": "未连接 Android 设备",
        "empty.noDevice.description": "用 USB 连接手机，解锁后选择“文件传输 / MTP”。",
        "empty.noDevice.refresh": "刷新",
        "empty.selectStorage.title": "选择存储",
        "empty.selectStorage.description": "在侧边栏选择内部存储或 SD 卡。",
        "empty.error.title": "无法列出此文件夹",
        "empty.error.retry": "重试",

        "transfer.preparing": "正在准备 %@…",
        "transfer.downloading": "正在下载 %@",
        "transfer.uploading": "正在上传 %@",
        "transfer.deleting": "正在删除…",
        "transfer.cancel": "取消",
        "transfer.canceling": "正在取消传输…",
        "transfer.pause": "暂停",
        "transfer.resume": "继续",
        "transfer.paused": "已暂停",
        "transfer.retry": "重试",
        "transfer.done": "完成",
        "transfer.canceled": "已取消",
        "transfer.savedDownloads": "已保存到“下载”",
        "transfer.savedFolder": "文件夹已保存到“下载”",
        "transfer.uploadedTo": "已上传到 %@",
        "transfer.uploaded": "已上传 %@",
        "transfer.deleted": "已删除",

        "alerts.noDevice": "未连接 Android 设备。",
        "alerts.noStorage": "未选择 Android 存储。",
        "alerts.selectPhone": "请先在手机上选择文件或文件夹。",
        "alerts.selectLocal": "请先在本地选择文件或文件夹。",
        "alerts.transferRunning": "已有传输正在进行。",
        "alerts.symlink": "不支持上传符号链接，请选择真实文件或文件夹。",
        "alerts.nameExists": "此文件夹中已存在名为“%@”的文件。",
        "alerts.debugFileNotFound": "在个人文件夹中找不到调试文件 %@。",
        "alerts.testFolderNotVisible": "在“下载”中看不到测试文件夹。",
        "alerts.testFolderNotFound": "手机上找不到 AndroidFileTransferKitUITest 文件夹。",
        "alerts.noDeviceFile": "设备上没有可用文件。",
        "alerts.couldNotCreateTestFolder": "无法创建测试文件夹：%@",

        "conflict.title": "项目已存在",
        "conflict.message": "目标位置已存在 %d 个项目。",
        "conflict.replace": "替换",
        "conflict.keepBoth": "保留两者",
        "conflict.cancel": "取消",
        "conflict.replaceWarning": "“替换”会删除目标位置已有的项目。",

        "delete.title": "从手机删除？",
        "delete.message": "从手机删除 %d 个项目？此操作无法撤销。",
        "delete.confirm": "删除",
        "delete.cancel": "取消",

        "general.ok": "好",
        "general.cancel": "取消",
        "general.delete": "删除",
        "general.refresh": "刷新",
        "general.language": "语言",
        "general.system": "跟随系统",

        "settings.title": "设置",
        "settings.general": "通用",
        "settings.browsing": "浏览",
        "settings.showHiddenFiles": "显示隐藏文件",
        "settings.about": "关于",
        "settings.version": "版本 %@",

        "onboarding.title": "欢迎使用 Android File Transfer",
        "onboarding.subtitle": "通过 USB 在 Mac 和 Android 之间传输文件。",
        "onboarding.step1": "用 USB 线连接手机。",
        "onboarding.step2": "解锁手机并选择“文件传输 / MTP”。",
        "onboarding.step3": "在两栏之间拖拽文件，或使用“上传 / 下载”。",
        "onboarding.done": "开始使用",

        "debug.menu": "调试",
        "debug.uploadHome": "从个人文件夹上传 skills-lock.json",
        "debug.downloadFirst": "下载设备上的第一个文件",
        "debug.uploadTestFolder": "上传测试文件夹",
        "debug.downloadTestFolder": "下载测试文件夹",
        "debug.deleteTestFolders": "立即删除测试文件夹",
        "debug.resetUSB": "重置 USB 设备",
        "debug.disconnectDevice": "断开设备（测试）",
        "debug.quickLookHome": "快速查看 skills-lock.json",
        "debug.quickLookDevice": "快速查看设备文件",
        "debug.testDrag": "测试拖出文件",
        "debug.testFolderDrag": "测试拖出文件夹",
        "debug.uploadLarge": "上传 64MB 测试文件",
        "debug.cancelTransfer": "取消当前传输",
        "debug.pauseTransfer": "暂停当前传输",
        "debug.resumeQueue": "恢复队列",
    ]
}
