import SwiftUI
import Combine
import SQLite3
import AppKit
import CommonCrypto
@preconcurrency import QuickLookUI
@preconcurrency import QuickLookThumbnailing
import ImageIO
import AVFoundation
import CoreLocation
import UniformTypeIdentifiers
@preconcurrency import MapKit

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "wave", "aiff", "aif", "ape", "ogg", "opus", "wma", "alac", "caf", "ac3", "eac3", "wv", "tta", "amr"]
private let mediaExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "raw", "arw", "cr2", "cr3", "nef", "dng", "orf", "rw2", "raf", "mp4", "mov", "m4v", "avi", "mkv", "wmv", "mts", "m2ts", "3gp", "webm", "mpg", "mpeg", "ts", "vob"]

private final class MotionPhotoPlayback {
    let url: URL
    private let removesFileOnDeinit: Bool

    init(url: URL, removesFileOnDeinit: Bool = false) {
        self.url = url
        self.removesFileOnDeinit = removesFileOnDeinit
    }

    deinit {
        if removesFileOnDeinit { try? FileManager.default.removeItem(at: url) }
    }
}

private func toolOutput(_ executable: String, arguments: [String]) -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : Data()
    } catch {
        return Data()
    }
}

private func extractToolOutput(_ executable: String, arguments: [String], to destination: URL) -> Bool {
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    guard let output = try? FileHandle(forWritingTo: destination) else { return false }
    defer { try? output.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func exifTagValues(_ text: String, named tag: String) -> [String] {
    text.split(separator: "\n").compactMap { line in
        let raw = String(line).trimmingCharacters(in: .whitespaces)
        guard let separator = raw.range(of: " : ") else { return nil }
        let field = String(raw[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        let key = field.components(separatedBy: "]").last?.trimmingCharacters(in: .whitespaces) ?? field
        guard key.caseInsensitiveCompare(tag) == .orderedSame else { return nil }
        return String(raw[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}

private func validMP4Start(in url: URL) -> UInt64? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let prefix = (try? handle.read(upToCount: 4096)) ?? Data()
    guard let marker = prefix.range(of: Data("ftyp".utf8)), marker.lowerBound >= 4 else { return nil }
    return UInt64(marker.lowerBound - 4)
}

private func trimFile(_ source: URL, from offset: UInt64, to destination: URL) -> Bool {
    guard let input = try? FileHandle(forReadingFrom: source) else { return false }
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    guard let output = try? FileHandle(forWritingTo: destination) else {
        try? input.close()
        return false
    }
    defer { try? input.close(); try? output.close() }
    do {
        try input.seek(toOffset: offset)
        while true {
            let chunk = try input.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
        return true
    } catch {
        return false
    }
}

private func temporaryMotionVideoURL(for source: URL) -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ViewMediaInfoMotionPhotos", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).mov")
}

private func detectMotionPhoto(fileURL: URL, metadataText: String, exiftool: String) -> MotionPhotoPlayback? {
    let photoExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg"]
    guard photoExtensions.contains(fileURL.pathExtension.lowercased()) else { return nil }

    // Apple Live Photos must have an exact ContentIdentifier match in the same directory.
    if let identifier = exifTagValues(metadataText, named: "ContentIdentifier").first, !identifier.isEmpty,
       let siblings = try? FileManager.default.contentsOfDirectory(at: fileURL.deletingLastPathComponent(),
                                                                    includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles]) {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let movies = siblings.filter { $0.pathExtension.lowercased() == "mov" }.sorted {
            let leftMatches = $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(stem) == .orderedSame
            let rightMatches = $1.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(stem) == .orderedSame
            return leftMatches && !rightMatches
        }
        for movie in movies {
            let output = toolOutput(exiftool, arguments: ["-s3", "-ContentIdentifier", movie.path])
            let identifiers = String(data: output, encoding: .utf8)?.split(separator: "\n").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? []
            if identifiers.contains(identifier) { return MotionPhotoPlayback(url: movie) }
        }
    }

    // Android motion photos commonly expose one of these XMP/vendor tags and append an MP4 payload.
    let markerTags = ["MotionPhoto", "MotionPhotoVersion", "MicroVideo", "MicroVideoVersion",
                      "MicroVideoOffset", "MotionPhotoVideo", "EmbeddedVideo", "SamsungMotionPhotoVersion"]
    guard markerTags.contains(where: { !exifTagValues(metadataText, named: $0).isEmpty }) else { return nil }

    for binaryTag in ["MotionPhotoVideo", "EmbeddedVideo"] {
        let extracted = temporaryMotionVideoURL(for: fileURL)
        guard extractToolOutput(exiftool, arguments: ["-b", "-\(binaryTag)", fileURL.path], to: extracted) else {
            try? FileManager.default.removeItem(at: extracted)
            continue
        }
        if let start = validMP4Start(in: extracted) {
            if start == 0 { return MotionPhotoPlayback(url: extracted, removesFileOnDeinit: true) }
            let trimmed = temporaryMotionVideoURL(for: fileURL)
            if trimFile(extracted, from: start, to: trimmed) {
                try? FileManager.default.removeItem(at: extracted)
                return MotionPhotoPlayback(url: trimmed, removesFileOnDeinit: true)
            }
        }
        try? FileManager.default.removeItem(at: extracted)
    }

    if let offsetText = exifTagValues(metadataText, named: "MicroVideoOffset").first,
       let offset = UInt64(offsetText.filter(\.isNumber)), offset > 0,
       let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
       let fileSize = (attributes[.size] as? NSNumber)?.uint64Value, offset < fileSize {
        let extracted = temporaryMotionVideoURL(for: fileURL)
        if trimFile(fileURL, from: fileSize - offset, to: extracted), validMP4Start(in: extracted) == 0 {
            return MotionPhotoPlayback(url: extracted, removesFileOnDeinit: true)
        }
        try? FileManager.default.removeItem(at: extracted)
    }
    return nil
}

private enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"
    var id: String { rawValue }
}

private final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    private static let defaultsKey = "preferredInterfaceLanguage"

    @Published private(set) var language: AppLanguage
    @Published private(set) var preferredLanguage: AppLanguage

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let language = AppLanguage(rawValue: saved) {
            self.language = language
            self.preferredLanguage = language
        } else {
            let first = Locale.preferredLanguages.first?.lowercased() ?? "en"
            let language: AppLanguage = first.hasPrefix("zh") ? .chinese : .english
            self.language = language
            self.preferredLanguage = language
        }
        UserDefaults.standard.set([preferredLanguage.rawValue], forKey: "AppleLanguages")
    }

    func select(_ language: AppLanguage) {
        guard preferredLanguage != language else { return }
        preferredLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    var locale: Locale { Locale(identifier: language.rawValue) }
}

private let englishInterfaceText: [String: String] = [
    "媒体信息": "Media Information", "重要媒体信息": "Essential Media Information", "全部媒体信息": "All Media Information",
    "详细信息": "Details", "精简信息": "Summary", "复制结果": "Copy Results", "设置": "Settings", "语言": "Language",
    "语言更改将在下次启动时生效。": "Language changes will take effect the next time the app starts.",
    "播放视频预览": "Play Video Preview",
    "播放音频预览": "Play Audio Preview",
    "打开媒体…": "Open Media…",
    "打开媒体": "Open Media",
    "请选择一个媒体文件": "Choose a media file",
    "请通过“文件 > 打开媒体…”或按 ⌘O 选择图片、视频或音频文件。": "Choose an image, video, or audio file from File > Open Media… or press ⌘O.",
    "简体中文": "Simplified Chinese", "英语": "English", "没有可用信息": "No information available",
    "正在查询位置…": "Looking up location…", "未指定": "Unspecified", "单声道": "Mono", "立体声": "Stereo", "像素": "Pixels",
    "错误": "Error", "信息": "Information", "确定": "OK", "找不到文件": "File not found", "找不到 exiftool": "ExifTool not found",
    "文件": "File", "图像": "Image", "相机": "Camera", "拍摄参数": "Capture Settings", "日期与位置": "Date & Location",
    "视频": "Video", "音频": "Audio", "音乐": "Music", "录音来源": "Recording Source", "其他": "Other",
    "文件名": "File Name", "所在目录": "Folder", "文件路径": "File Path", "文件大小": "File Size", "文件格式": "File Format",
    "格式名称": "Format Name", "封装格式": "Container", "扩展名": "Extension", "MIME 类型": "MIME Type", "文件权限": "Permissions",
    "文件修改时间": "Modified", "文件访问时间": "Last Accessed", "文件属性修改时间": "Metadata Changed",
    "主要格式": "Major Brand", "兼容格式": "Compatible Brands", "媒体流数量": "Stream Count", "格式识别可信度": "Probe Confidence",
    "格式": "Format", "标题": "Title", "副标题": "Subtitle", "艺术家": "Artist", "专辑": "Album", "专辑艺术家": "Album Artist",
    "作曲": "Composer", "曲目": "Track", "碟片": "Disc", "年份": "Year", "流派": "Genre", "年份与流派": "Year & Genre",
    "版权": "Copyright", "条码": "Barcode", "作者": "Author", "说明": "Description", "注释": "Comment", "主题": "Subject",
    "关键词": "Keywords", "创建者": "Creator", "署名": "Credit", "来源": "Source", "对象名称": "Object Name",
    "时长与大小": "Duration & Size", "音频格式": "Audio Format", "音频参数": "Audio Properties", "时长": "Duration", "大小": "Size",
    "编码": "Codec", "码率": "Bit Rate", "采样率": "Sample Rate", "采样格式": "Sample Format", "位深": "Bit Depth", "声道": "Channels",
    "编码器": "Encoder", "应用": "Application", "设备": "Device", "时间": "Time", "录制时间": "Recorded",
    "图像宽度": "Image Width", "图像高度": "Image Height", "图像尺寸": "Image Dimensions", "像素数（百万）": "Megapixels",
    "EXIF 图像宽度": "EXIF Image Width", "EXIF 图像高度": "EXIF Image Height", "图像方向": "Orientation",
    "水平分辨率": "Horizontal Resolution", "垂直分辨率": "Vertical Resolution", "分辨率单位": "Resolution Unit",
    "色彩配置": "Color Profile", "色彩原色": "Color Primaries", "传输特性": "Transfer Characteristics", "色彩矩阵": "Color Matrix",
    "全范围色彩": "Full-range Color", "色度采样格式": "Chroma Subsampling", "亮度位深": "Luma Bit Depth",
    "色度位深": "Chroma Bit Depth", "像素位深": "Pixel Depth", "色彩空间": "Color Space", "旋转角度": "Rotation",
    "媒体数据大小": "Media Data Size", "宽度": "Width", "高度": "Height", "编码宽度": "Coded Width", "编码高度": "Coded Height",
    "像素格式": "Pixel Format", "色彩范围": "Color Range", "色彩传输": "Color Transfer", "色度位置": "Chroma Location",
    "设备品牌": "Manufacturer", "设备型号": "Model", "拍摄设备": "Capture Device", "系统版本": "Software",
    "镜头": "Lens", "镜头品牌": "Lens Manufacturer", "镜头型号": "Lens Model", "镜头参数": "Lens Properties", "相机类型": "Camera Type",
    "照片标识符": "Photo Identifier", "内容标识符": "Content Identifier", "ExifTool 版本": "ExifTool Version", "EXIF 版本": "EXIF Version",
    "曝光时间": "Exposure Time", "曝光程序": "Exposure Program",
    "感光度（ISO）": "ISO", "快门速度": "Shutter Speed", "快门": "Shutter", "光圈值": "F-number", "光圈": "Aperture",
    "亮度值": "Brightness", "曝光补偿": "Exposure Compensation", "测光模式": "Metering Mode", "闪光灯": "Flash",
    "焦距": "Focal Length", "等效 35 毫米焦距": "35 mm Equivalent", "主体区域": "Subject Area", "感光方式": "Sensing Method",
    "场景类型": "Scene Type", "曝光模式": "Exposure Mode", "白平衡": "White Balance", "拍摄类型": "Capture Type",
    "HDR 余量": "HDR Headroom", "信噪比": "Signal-to-noise Ratio", "色温": "Color Temperature", "对焦位置": "Focus Position",
    "视角": "Field of View", "合成图像": "Composite Image", "品牌": "Manufacturer", "型号": "Model",
    "位置": "Location", "拍摄位置": "Capture Location", "海拔基准": "Altitude Reference", "海拔": "Altitude",
    "GPS 时间": "GPS Time", "速度单位": "Speed Unit", "移动速度": "Speed", "拍摄方向基准": "Direction Reference",
    "拍摄方向": "Direction", "GPS 日期": "GPS Date", "定位精度": "Location Accuracy", "GPS 日期时间": "GPS Date & Time",
    "拍摄时间": "Captured", "创建时间": "Created", "修改时间": "Modified", "时区": "Time Zone", "拍摄时区": "Capture Time Zone",
    "数字化时区": "Digitized Time Zone", "标称帧率": "Nominal Frame Rate", "平均帧率": "Average Frame Rate", "帧数": "Frame Count",
    "媒体流类型": "Stream Type", "编码格式": "Codec", "编码名称": "Codec Name", "编码配置": "Codec Profile", "编码标识": "Codec Tag",
    "音频采样格式": "Audio Sample Format", "音频采样率": "Audio Sample Rate", "声道数": "Channel Count", "声道布局": "Channel Layout",
    "音频位深": "Audio Bit Depth", "媒体处理器": "Media Handler", "媒体流编号": "Stream Index",
    "B 帧数量": "B-frame Count", "编码级别": "Codec Level", "时间基准": "Time Base", "起始时间（秒）": "Start Time (seconds)",
    "时长（秒）": "Duration (seconds)", "编码附加数据大小": "Extradata Size", "附加数据类型": "Side Data Type",
    "顶部裁切": "Top Crop", "底部裁切": "Bottom Crop", "左侧裁切": "Left Crop", "右侧裁切": "Right Crop",
    "图像说明": "Image Description", "用户注释": "User Comment", "水平": "Horizontal", "垂直": "Vertical",
    "没有尺寸信息": "No dimension information", "尺寸图": "Dimensions Diagram", "没有嵌入封面": "No embedded artwork",
    "全部类型": "All Types", "照片": "Photos", "全部状态": "All Statuses", "已同步": "Synced", "未同步": "Not Synced",
    "筛选": "Filter", "类型": "Type", "同步状态": "Sync Status", "更新数据库": "Update Database", "刷新": "Refresh",
    "标记已同步": "Mark as Synced", "标记未同步": "Mark as Not Synced", "目录": "Folder", "同步": "Sync",
    "在 Finder 中打开文件": "Reveal File in Finder", "打开所在目录": "Open Containing Folder", "显示简介": "Get Info",
    "查看媒体信息": "View Media Information", "搜索文件名或目录": "Search file name or folder"
]

private func localizedText(_ chinese: String) -> String {
    guard LanguageSettings.shared.language == .english else { return chinese }
    return englishInterfaceText[chinese] ?? chinese
}

private func localizedFieldLabel(_ label: String) -> String {
    label.components(separatedBy: " · ").map(localizedText).joined(separator: " · ")
}

private func localizedMetadataValue(_ value: String) -> String {
    guard LanguageSettings.shared.language == .english else { return value }
    if let exact = englishInterfaceText[value] { return exact }
    var result = value
    let replacements: [(String, String)] = [
        ("焦距范围：", "Focal range: "), ("最大光圈：", "Maximum aperture: "),
        ("单声道", "Mono"), ("立体声", "Stereo"), ("未指定", "Unspecified"),
        ("语音备忘录", "Voice Memos"), ("帧/秒", "fps"), ("Mb/秒", "Mb/s"), ("kb/秒", "kb/s"),
        (" 声道", " channels"), (" 位", "-bit"), (" 秒", " s"),
        ("今天", "Today"), ("天前", " days ago"), ("个月前", " months ago"), ("年前", " years ago")
    ]
    for (source, target) in replacements { result = result.replacingOccurrences(of: source, with: target) }
    for (chinese, english) in englishInterfaceText {
        result = result.replacingOccurrences(of: "\(chinese)：", with: "\(english): ")
    }
    return result
}

/// Some old Windows tag writers mark UTF-16 text as big-endian while storing
/// little-endian bytes without a BOM. ExifTool/FFmpeg then return readable
/// Unicode made from byte-swapped code units (for example `Ɛ⭒` instead of
/// `送别`). Repair only the distinctive mixed-script form so normal metadata,
/// including legitimate multilingual text, is left untouched.
private let legacyTextMetadataKeys: Set<String> = [
    "title", "subtitle", "artist", "album", "albumartist", "album_artist", "band", "composer", "conductor",
    "genre", "comment", "comments", "description", "synopsis", "lyrics", "copyright", "author", "creator",
    "credit", "source", "headline", "objectname", "caption-abstract", "instructions", "keywords", "subject",
    "imagedescription", "usercomment", "xptitle", "xpcomment", "xpauthor", "xpkeywords", "xpsubject",
    "software", "hostcomputer", "encoder", "encoded_by", "encodersettings", "handler_name",
    "make", "model", "lensmake", "lensmodel", "devicemanufacturer", "devicemodelname",
    "com.apple.quicktime.title", "com.apple.quicktime.subtitle", "com.apple.quicktime.artist",
    "com.apple.quicktime.author", "com.apple.quicktime.comment", "com.apple.quicktime.description",
    "com.apple.quicktime.information", "com.apple.quicktime.copyright", "com.apple.quicktime.software",
    "com.apple.quicktime.make", "com.apple.quicktime.model"
]

private func repairedLegacyMetadataText(_ text: String, key: String) -> String {
    guard legacyTextMetadataKeys.contains(key.lowercased()) else { return text }
    guard text.utf16.count >= 2 else { return text }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(text.utf16.count * 2)
    for unit in text.utf16 {
        bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
        bytes.append(UInt8(truncatingIfNeeded: unit))
    }
    guard let candidate = String(data: Data(bytes), encoding: .utf16LittleEndian),
          !candidate.isEmpty, candidate != text else { return text }

    struct Profile {
        var cjk = 0
        var kana = 0
        var hangul = 0
        var latin = 0
        var otherLetters = 0
        var suspicious = 0
        var visible = 0

        var scriptCount: Int {
            [cjk, kana, hangul, latin, otherLetters].filter { $0 > 0 }.count
        }
        var commonTextCount: Int { cjk + kana + hangul + latin }
    }

    func profile(_ value: String) -> Profile {
        var result = Profile()
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            result.visible += 1
            if (0x4E00...0x9FFF).contains(code) || (0x3400...0x4DBF).contains(code) {
                result.cjk += 1
            } else if (0x3040...0x30FF).contains(code) {
                result.kana += 1
            } else if (0xAC00...0xD7AF).contains(code) {
                result.hangul += 1
            } else if (0x0020...0x007E).contains(code) || (0x00C0...0x024F).contains(code) {
                if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                    result.latin += 1
                }
            } else if CharacterSet.letters.contains(scalar) {
                result.otherLetters += 1
            }

            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .unassigned:
                result.suspicious += 2
            case .mathSymbol, .modifierSymbol, .otherSymbol:
                result.suspicious += 1
            default:
                break
            }
        }
        return result
    }

    let original = profile(text)
    let recovered = profile(candidate)
    guard recovered.visible > 0,
          recovered.suspicious == 0,
          recovered.commonTextCount * 4 >= recovered.visible * 3 else { return text }

    let originalLooksSwapped = original.suspicious > 0
        || original.scriptCount >= 3
        || (original.scriptCount >= 2 && recovered.scriptCount == 1)
    let recoveredLooksCoherent = recovered.scriptCount <= 2
        && (recovered.cjk >= 2 || recovered.latin >= 3)
    return originalLooksSwapped && recoveredLooksCoherent ? candidate : text
}

private func md5(of url: URL) throws -> Data {
    var context = CC_MD5_CTX(); CC_MD5_Init(&context)
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        data.withUnsafeBytes { _ = CC_MD5_Update(&context, $0.baseAddress, CC_LONG(data.count)) }
    }
    var digest = Data(count: Int(CC_MD5_DIGEST_LENGTH))
    digest.withUnsafeMutableBytes { _ = CC_MD5_Final($0.bindMemory(to: UInt8.self).baseAddress, &context) }
    return digest
}

struct PhotoRecord: Identifiable, Hashable {
    let id: Int64
    let fileName: String
    let directory: String
    let mediaType: String
    var syncStatus: String
    let md5: String
}

enum DatabaseError: LocalizedError {
    case notFound(URL), sqlite(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let url):
            LanguageSettings.shared.language == .chinese ? "找不到数据库：\(url.path)" : "Database not found: \(url.path)"
        case .sqlite(let text): text
        }
    }
}

final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let url: URL

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { throw DatabaseError.notFound(url) }
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    deinit { sqlite3_close(handle) }

    func records(search: String, mediaFilter: String = "全部类型", syncFilter: String = "全部状态") throws -> [PhotoRecord] {
        var conditions: [String] = []
        var parameters: [String] = []
        if !search.isEmpty { conditions.append("(p.file_name LIKE ? OR d.path LIKE ?)"); parameters += ["%\(search)%", "%\(search)%"] }
        if mediaFilter == "照片" { conditions.append("p.media_type = 'photo'") }
        if mediaFilter == "视频" { conditions.append("p.media_type = 'video'") }
        if syncFilter == "已同步" { conditions.append("p.sync_status = 'synced'") }
        if syncFilter == "未同步" { conditions.append("p.sync_status = 'unsynced'") }
        let sql = """
        SELECT p.id, p.file_name, d.path, p.media_type, p.sync_status, p.md5
        FROM synced_photos p JOIN directories d ON d.id = p.directory_id
        \(conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "))
        ORDER BY d.path, p.file_name
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        for (index, parameter) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), parameter, -1, sqliteTransient)
        }
        var result: [PhotoRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let md5Pointer = sqlite3_column_blob(statement, 5)
            let md5Length = Int(sqlite3_column_bytes(statement, 5))
            let md5 = md5Pointer.map { Data(bytes: $0, count: md5Length).map { String(format: "%02x", $0) }.joined() } ?? ""
            result.append(PhotoRecord(
                id: sqlite3_column_int64(statement, 0), fileName: text(statement, 1),
                directory: text(statement, 2), mediaType: text(statement, 3),
                syncStatus: text(statement, 4), md5: md5))
        }
        return result
    }

    func setStatus(ids: [Int64], status: String) throws {
        for id in ids {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, "UPDATE synced_photos SET sync_status=? WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw lastError() }
            sqlite3_bind_text(statement, 1, status, -1, sqliteTransient); sqlite3_bind_int64(statement, 2, id)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    func reindex(root: URL, progress: @escaping @Sendable (Int) -> Void) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "mts", "m2ts", "3gp", "webm", "mpg", "mpeg", "ts", "vob"]
        var processedFiles = 0

        for case let url as URL in enumerator {
            let fileExtension = url.pathExtension.lowercased()
            guard mediaExtensions.contains(fileExtension) else { continue }
            processedFiles += 1

            let directory = url.deletingLastPathComponent().path
            let name = url.lastPathComponent
            let media = videoExtensions.contains(fileExtension) ? "video" : "photo"

            var lookup: OpaquePointer?
            let lookupSQL = """
                SELECT p.id, p.md5
                FROM synced_photos p JOIN directories d ON d.id=p.directory_id
                WHERE d.path=? AND p.file_name=?
                """
            guard sqlite3_prepare_v2(handle, lookupSQL, -1, &lookup, nil) == SQLITE_OK else { throw lastError() }
            sqlite3_bind_text(lookup, 1, directory, -1, sqliteTransient)
            sqlite3_bind_text(lookup, 2, name, -1, sqliteTransient)
            let found = sqlite3_step(lookup) == SQLITE_ROW
            let existingID = found ? sqlite3_column_int64(lookup, 0) : nil
            let oldDigest = found ? data(lookup, 1) : nil
            sqlite3_finalize(lookup)

            let digest = try md5(of: url)
            if existingID != nil, oldDigest == digest {
                progress(processedFiles)
                continue
            }

            if let existingID {
                var update: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "UPDATE synced_photos SET md5=?, media_type=? WHERE id=?", -1, &update, nil) == SQLITE_OK else { throw lastError() }
                _ = digest.withUnsafeBytes { sqlite3_bind_blob(update, 1, $0.baseAddress, Int32(digest.count), sqliteTransient) }
                sqlite3_bind_text(update, 2, media, -1, sqliteTransient)
                sqlite3_bind_int64(update, 3, existingID)
                guard sqlite3_step(update) == SQLITE_DONE else {
                    sqlite3_finalize(update)
                    throw lastError()
                }
                sqlite3_finalize(update)
            } else {
                let directoryID = try ensureDirectory(directory)
                var insert: OpaquePointer?
                let insertSQL = "INSERT INTO synced_photos(directory_id,file_name,md5,media_type,sync_status) VALUES (?,?,?,?,'unsynced')"
                guard sqlite3_prepare_v2(handle, insertSQL, -1, &insert, nil) == SQLITE_OK else { throw lastError() }
                sqlite3_bind_int64(insert, 1, directoryID)
                sqlite3_bind_text(insert, 2, name, -1, sqliteTransient)
                _ = digest.withUnsafeBytes { sqlite3_bind_blob(insert, 3, $0.baseAddress, Int32(digest.count), sqliteTransient) }
                sqlite3_bind_text(insert, 4, media, -1, sqliteTransient)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    sqlite3_finalize(insert)
                    throw lastError()
                }
                sqlite3_finalize(insert)
            }

            progress(processedFiles)
        }
    }

    private func ensureDirectory(_ path: String) throws -> Int64 {
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT OR IGNORE INTO directories(path) VALUES (?)", -1, &insert, nil) == SQLITE_OK else { throw lastError() }
        sqlite3_bind_text(insert, 1, path, -1, sqliteTransient)
        guard sqlite3_step(insert) == SQLITE_DONE else {
            sqlite3_finalize(insert)
            throw lastError()
        }
        sqlite3_finalize(insert)

        var lookup: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT id FROM directories WHERE path=?", -1, &lookup, nil) == SQLITE_OK else { throw lastError() }
        sqlite3_bind_text(lookup, 1, path, -1, sqliteTransient)
        guard sqlite3_step(lookup) == SQLITE_ROW else {
            sqlite3_finalize(lookup)
            throw lastError()
        }
        let id = sqlite3_column_int64(lookup, 0)
        sqlite3_finalize(lookup)
        return id
    }

    private func data(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }
    private func lastError() -> DatabaseError { .sqlite(String(cString: sqlite3_errmsg(handle))) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var records: [PhotoRecord] = []
    @Published var selected = Set<PhotoRecord.ID>()
    @Published var search = ""
    @Published var mediaFilter = "全部类型"
    @Published var syncFilter = "全部状态"
    @Published var message = LanguageSettings.shared.language == .chinese ? "正在打开数据库..." : "Opening database…"
    @Published var error: String?
    @Published var isIndexing = false
    @Published var indexProgress = ""
    private var database: Database?
    private var locationLookupTask: Task<Void, Never>?

    func start() {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments.first ?? ".").deletingLastPathComponent()
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("synced_photos.db"),
            executableURL.appendingPathComponent("synced_photos.db"),
            executableURL.deletingLastPathComponent().appendingPathComponent("synced_photos.db")
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            error = DatabaseError.notFound(candidates[0]).localizedDescription; return
        }
        do { database = try Database(url: url); reload() } catch let caught { error = caught.localizedDescription }
    }
    func reload() {
        guard let database else { return }
        selected.removeAll()
        do {
            records = try database.records(search: search, mediaFilter: mediaFilter, syncFilter: syncFilter)
            message = LanguageSettings.shared.language == .chinese ? "显示 \(records.count) 条记录" : "Showing \(records.count) records"
        } catch let caught { error = caught.localizedDescription }
    }
    func sort(using order: [KeyPathComparator<PhotoRecord>]) {
        records.sort(using: order)
    }
    func update(status: String) {
        guard let database else { return }
        do { try database.setStatus(ids: Array(selected), status: status); selected.removeAll(); reload() } catch let caught { error = caught.localizedDescription }
    }

    func reindex() {
        guard let database, !isIndexing else { return }
        isIndexing = true
        indexProgress = LanguageSettings.shared.language == .chinese ? "准备扫描..." : "Preparing scan…"
        let root = URL(fileURLWithPath: "/Volumes/Backup Apple/郑景元照片")
        Task.detached {
            do {
                try database.reindex(root: root) { current in
                    Task { @MainActor in
                        self.indexProgress = LanguageSettings.shared.language == .chinese
                            ? "更新数据库：已处理 \(current) 个文件" : "Updating database: \(current) files processed"
                    }
                }
                await MainActor.run {
                    self.isIndexing = false
                    self.indexProgress = LanguageSettings.shared.language == .chinese
                        ? "数据库更新完成" : "Database update complete"
                    self.reload()
                }
            } catch {
                await MainActor.run { self.isIndexing = false; self.error = error.localizedDescription }
            }
        }
    }

    func openInFinder(id: Int64) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: record.directory).appendingPathComponent(record.fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openDirectory(id: Int64) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: record.directory))
    }

    func showDetails(id: Int64) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        let path = URL(fileURLWithPath: record.directory).appendingPathComponent(record.fileName).path
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\"\nset targetFile to POSIX file \"\(escaped)\" as alias\nopen information window of targetFile\nend tell"
        _ = NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    func showEXIF(fileURL: URL) {
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "wmv", "mts", "m2ts", "3gp", "webm", "mpg", "mpeg", "ts", "vob"]
        let fileExtension = fileURL.pathExtension.lowercased()
        let mediaType = audioExtensions.contains(fileExtension) ? "audio" : (videoExtensions.contains(fileExtension) ? "video" : "photo")
        let record = PhotoRecord(id: -1, fileName: fileURL.lastPathComponent,
                                 directory: fileURL.deletingLastPathComponent().path,
                                 mediaType: mediaType, syncStatus: "", md5: "")
        records = [record]
        showEXIF(id: record.id)
    }

    func showEXIF(id: Int64) {
        locationLookupTask?.cancel()
        guard let record = records.first(where: { $0.id == id }) else { return }
        let fileURL = URL(fileURLWithPath: record.directory).appendingPathComponent(record.fileName)
        if record.mediaType == "audio" {
            showAudioInfo(record: record, fileURL: fileURL)
            return
        }
        let candidates = record.mediaType == "video" ? ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"] : ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            EXIFWindowController.shared.show(title: record.fileName, values: [("错误", localizedText("找不到 exiftool"))]); return
        }
        let arguments = record.mediaType == "video"
            ? ["-v", "error", "-show_format", "-show_streams", "-of", "default=noprint_wrappers=1", fileURL.path]
            : ["-G1", "-a", "-s", "-n", fileURL.path]
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        do {
            try process.run()
            // Drain the pipe while the child is still running. Waiting first can deadlock
            // when large metadata or an embedded cover fills the pipe buffer.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            let labels: [String: String] = [
                "ExifToolVersion":"ExifTool 版本", "FileName":"文件名", "Directory":"所在目录", "FileSize":"文件大小",
                "FileModifyDate":"文件修改时间", "FileAccessDate":"文件访问时间", "FileInodeChangeDate":"文件属性修改时间",
                "FilePermissions":"文件权限", "FileType":"文件格式", "FileTypeExtension":"扩展名", "MIMEType":"MIME 类型",
                "ImageWidth":"图像宽度", "ImageHeight":"图像高度", "MajorBrand":"主要格式", "CompatibleBrands":"兼容格式",
                "ColorProfiles":"色彩配置", "ColorPrimaries":"色彩原色", "TransferCharacteristics":"传输特性",
                "MatrixCoefficients":"色彩矩阵", "VideoFullRangeFlag":"全范围色彩", "ChromaFormat":"色度采样格式",
                "BitDepthLuma":"亮度位深", "BitDepthChroma":"色度位深", "ImagePixelDepth":"像素位深",
                "MediaDataSize":"媒体数据大小", "Make":"设备品牌", "Model":"设备型号", "Orientation":"图像方向",
                "ImageDescription":"图像说明", "UserComment":"用户注释", "Artist":"作者", "Copyright":"版权",
                "XPTitle":"标题", "XPComment":"注释", "XPAuthor":"作者", "XPKeywords":"关键词", "XPSubject":"主题",
                "Title":"标题", "Description":"说明", "Comment":"注释", "Headline":"标题", "ObjectName":"对象名称",
                "Caption-Abstract":"说明", "Creator":"创建者", "Credit":"署名", "Source":"来源", "Keywords":"关键词",
                "XResolution":"水平分辨率", "YResolution":"垂直分辨率", "ResolutionUnit":"分辨率单位",
                "Software":"系统版本", "ModifyDate":"修改时间", "HostComputer":"拍摄设备", "ExposureTime":"曝光时间",
                "FNumber":"光圈值", "ExposureProgram":"曝光程序", "ISO":"感光度（ISO）", "ExifVersion":"EXIF 版本",
                "DateTimeOriginal":"拍摄时间", "CreateDate":"创建时间", "OffsetTime":"时区", "OffsetTimeOriginal":"拍摄时区",
                "OffsetTimeDigitized":"数字化时区", "ShutterSpeedValue":"快门速度", "ApertureValue":"光圈",
                "BrightnessValue":"亮度值", "ExposureCompensation":"曝光补偿", "MeteringMode":"测光模式", "Flash":"闪光灯",
                "FocalLength":"焦距", "SubjectArea":"主体区域", "ColorSpace":"色彩空间", "ExifImageWidth":"EXIF 图像宽度",
                "ExifImageHeight":"EXIF 图像高度", "SensingMethod":"感光方式", "SceneType":"场景类型",
                "ExposureMode":"曝光模式", "WhiteBalance":"白平衡", "FocalLengthIn35mmFormat":"等效 35 毫米焦距",
                "LensInfo":"镜头参数", "LensMake":"镜头品牌", "LensModel":"镜头型号", "CompositeImage":"合成图像",
                "ImageCaptureType":"拍摄类型", "HDRHeadroom":"HDR 余量", "SignalToNoiseRatio":"信噪比",
                "PhotoIdentifier":"照片标识符", "ContentIdentifier":"内容标识符", "ColorTemperature":"色温", "CameraType":"相机类型", "FocusPosition":"对焦位置",
                "GPSLatitudeRef":"纬度方向", "GPSLatitude":"纬度", "GPSLongitudeRef":"经度方向", "GPSLongitude":"经度",
                "GPSAltitudeRef":"海拔基准", "GPSAltitude":"海拔", "GPSTimeStamp":"GPS 时间", "GPSSpeedRef":"速度单位",
                "GPSSpeed":"移动速度", "GPSImgDirectionRef":"拍摄方向基准", "GPSImgDirection":"拍摄方向",
                "GPSDateStamp":"GPS 日期", "GPSHPositioningError":"定位精度", "GPSDateTime":"GPS 日期时间",
                "ImageSize":"图像尺寸", "Megapixels":"像素数（百万）", "ShutterSpeed":"快门速度",
                "FOV":"视角", "FocalLength35efl":"等效 35 毫米焦距", "GPSPosition":"GPS 位置",
                "format_name":"封装格式", "format_long_name":"格式名称", "filename":"文件路径", "nb_streams":"媒体流数量",
                "codec_name":"编码格式", "codec_long_name":"编码名称", "codec_type":"媒体流类型", "profile":"编码配置",
                "codec_tag_string":"编码标识", "width":"宽度", "height":"高度", "coded_width":"编码宽度",
                "coded_height":"编码高度", "pix_fmt":"像素格式", "color_range":"色彩范围", "color_space":"色彩空间",
                "color_transfer":"色彩传输", "color_primaries":"色彩原色", "chroma_location":"色度位置",
                "r_frame_rate":"标称帧率", "avg_frame_rate":"平均帧率", "duration":"时长（秒）", "size":"文件大小",
                "bit_rate":"码率", "nb_frames":"帧数", "sample_fmt":"音频采样格式", "sample_rate":"音频采样率",
                "channels":"声道数", "channel_layout":"声道布局", "bits_per_sample":"音频位深", "creation_time":"创建时间",
                "handler_name":"媒体处理器", "encoder":"编码器", "language":"语言", "rotation":"旋转角度",
                "title":"标题", "subtitle":"副标题", "artist":"艺术家", "album":"专辑", "album_artist":"专辑艺术家",
                "composer":"作曲", "genre":"流派", "comment":"注释", "description":"说明", "copyright":"版权",
                "index":"媒体流编号", "has_b_frames":"B 帧数量", "level":"编码级别", "time_base":"时间基准",
                "start_time":"起始时间（秒）", "extradata_size":"编码附加数据大小", "side_data_type":"附加数据类型",
                "crop_top":"顶部裁切", "crop_bottom":"底部裁切", "crop_left":"左侧裁切", "crop_right":"右侧裁切",
                "probe_score":"格式识别可信度", "major_brand":"主要格式", "compatible_brands":"兼容格式",
                "com.apple.quicktime.location.accuracy.horizontal":"定位精度",
                "com.apple.quicktime.content.identifier":"内容标识符", "com.apple.quicktime.location.ISO6709":"拍摄位置",
                "com.apple.quicktime.make":"设备品牌", "com.apple.quicktime.model":"设备型号",
                "com.apple.quicktime.software":"系统版本", "com.apple.quicktime.creationdate":"拍摄时间"
            ]
            let dateKeys: Set<String> = [
                "FileModifyDate", "FileAccessDate", "FileInodeChangeDate", "ModifyDate", "DateTimeOriginal", "CreateDate",
                "SubSecCreateDate", "SubSecDateTimeOriginal", "SubSecModifyDate", "GPSDateStamp", "GPSDateTime",
                "creation_time", "com.apple.quicktime.creationdate"
            ]
            func systemDate(_ value: String) -> String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var date = iso.date(from: value)
                if date == nil {
                    iso.formatOptions = [.withInternetDateTime]
                    date = iso.date(from: value)
                }
                if date == nil {
                    for pattern in ["yyyy:MM:dd HH:mm:ss.SSSXXXXX", "yyyy:MM:dd HH:mm:ssXXXXX", "yyyy:MM:dd HH:mm:ss.SSS", "yyyy:MM:dd HH:mm:ss", "yyyy:MM:dd"] {
                        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = pattern
                        if let parsed = parser.date(from: value) { date = parsed; break }
                    }
                }
                guard let date else { return value }
                let formatter = DateFormatter(); formatter.locale = LanguageSettings.shared.locale; formatter.dateStyle = .medium
                formatter.timeStyle = value.contains(" ") || value.contains("T") ? .medium : .none
                return formatter.string(from: date)
            }
            func displayedValue(for key: String, value: String) -> String {
                var result = dateKeys.contains(key) ? systemDate(value) : value
                func compactNumber(_ number: Double, maximumFractionDigits: Int = 1) -> String {
                    let formatter = NumberFormatter()
                    formatter.numberStyle = .decimal
                    formatter.minimumFractionDigits = 0
                    formatter.maximumFractionDigits = maximumFractionDigits
                    return formatter.string(from: NSNumber(value: number)) ?? String(number)
                }
                func exposureTime(_ seconds: Double) -> String {
                    guard seconds > 0 else { return value }
                    if seconds < 1 {
                        let denominator = max(1, Int((1 / seconds).rounded()))
                        return "1/\(denominator) 秒"
                    }
                    return "\(compactNumber(seconds, maximumFractionDigits: 2)) 秒"
                }
                if ["FileSize", "MediaDataSize", "size"].contains(key), let bytes = Int64(value) {
                    result = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                } else if ["ExposureTime", "ShutterSpeed"].contains(key), let seconds = Double(value) {
                    result = exposureTime(seconds)
                } else if key == "ShutterSpeedValue", let apex = Double(value) {
                    result = exposureTime(pow(2, -apex))
                } else if key == "FNumber", let aperture = Double(value) {
                    result = "ƒ/\(compactNumber(aperture))"
                } else if key == "ApertureValue", let apex = Double(value) {
                    result = "ƒ/\(compactNumber(pow(sqrt(2), apex)))"
                } else if ["FocalLength", "FocalLengthIn35mmFormat"].contains(key), let millimetres = Double(value) {
                    result = "\(compactNumber(millimetres)) mm"
                } else if key == "LensInfo" {
                    let numbers = value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                    if numbers.count >= 4 {
                        let focal = abs(numbers[0] - numbers[1]) < 0.05
                            ? "\(compactNumber(numbers[0])) mm"
                            : "\(compactNumber(numbers[0]))–\(compactNumber(numbers[1])) mm"
                        let aperture = abs(numbers[2] - numbers[3]) < 0.05
                            ? "ƒ/\(compactNumber(numbers[2]))"
                            : "ƒ/\(compactNumber(numbers[2]))–ƒ/\(compactNumber(numbers[3]))"
                        result = "焦距范围：\(focal)\n最大光圈：\(aperture)"
                    }
                } else if key == "bit_rate", let bits = Double(value) {
                    result = String(format: "%.2f Mb/秒", bits / 1_000_000)
                } else if key == "sample_rate", let rate = Int(value) {
                    result = "\(rate.formatted()) Hz"
                } else if ["r_frame_rate", "avg_frame_rate"].contains(key) {
                    let parts = value.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] != 0 { result = String(format: "%.2f 帧/秒", parts[0] / parts[1]) }
                } else if key == "language", value == "und" {
                    result = "未指定"
                } else if key == "codec_type" {
                    result = value == "video" ? "视频" : (value == "audio" ? "音频" : value)
                }
                return result
            }
            func videoPairs(from lines: [String], section: String) -> [(String, String)] {
                lines.compactMap { line in
                    var raw = line.trimmingCharacters(in: .whitespaces)
                    guard !raw.isEmpty, !raw.hasPrefix("000000"), !raw.hasPrefix("DISPOSITION:") else { return nil }
                    if raw.hasPrefix("TAG:") { raw.removeFirst(4) }
                    guard let separator = raw.firstIndex(of: "=") else { return nil }
                    let key = String(raw[..<separator]).trimmingCharacters(in: .whitespaces)
                    let rawValue = String(raw[raw.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                    let value = repairedLegacyMetadataText(rawValue, key: key)
                    if key == "com.apple.quicktime.location.ISO6709" { return nil }
                    guard let label = labels[key], !value.isEmpty, value != "N/A", value != "unknown", value != "0/0" else { return nil }
                    return ("\(section) · \(label)", displayedValue(for: key, value: value))
                }
            }
            func coordinateFromVideo(_ text: String) -> CLLocationCoordinate2D? {
                guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("TAG:com.apple.quicktime.location.ISO6709=") }),
                      let equal = line.firstIndex(of: "=") else { return nil }
                let location = String(line[line.index(after: equal)...])
                let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      let match = expression.firstMatch(in: location, range: NSRange(location.startIndex..., in: location)),
                      let latitudeRange = Range(match.range(at: 1), in: location),
                      let longitudeRange = Range(match.range(at: 2), in: location),
                      let latitude = Double(location[latitudeRange]),
                      let longitude = Double(location[longitudeRange]) else { return nil }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            func coordinateFromPhoto(_ text: String) -> CLLocationCoordinate2D? {
                var latitude: Double?
                var longitude: Double?
                var latitudeReference = "N"
                var longitudeReference = "E"
                for line in text.split(separator: "\n") {
                    let raw = String(line).trimmingCharacters(in: .whitespaces)
                    guard let separator = raw.range(of: " : ") else { continue }
                    let field = String(raw[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let key = field.components(separatedBy: "]").last?.trimmingCharacters(in: .whitespaces) ?? field
                    let value = String(raw[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "GPSLatitude": if latitude == nil { latitude = Double(value) }
                    case "GPSLongitude": if longitude == nil { longitude = Double(value) }
                    case "GPSLatitudeRef": latitudeReference = value
                    case "GPSLongitudeRef": longitudeReference = value
                    default: break
                    }
                }
                guard var latitude, var longitude else { return nil }
                if latitudeReference.uppercased() == "S" { latitude = -abs(latitude) }
                if longitudeReference.uppercased() == "W" { longitude = -abs(longitude) }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            let coordinate = record.mediaType == "video" ? coordinateFromVideo(text) : coordinateFromPhoto(text)
            let coordinateKeys: Set<String> = ["GPSLatitudeRef", "GPSLatitude", "GPSLongitudeRef", "GPSLongitude", "GPSPosition"]
            var values: [(String, String)]
            if record.mediaType == "video" {
                let lines = text.split(separator: "\n").map(String.init)
                var streamBlocks: [[String]] = []
                var current: [String] = []
                var formatLines: [String] = []
                var readingFormat = false
                for line in lines {
                    if line.hasPrefix("filename=") {
                        if !current.isEmpty { streamBlocks.append(current); current = [] }
                        readingFormat = true
                    }
                    if readingFormat {
                        formatLines.append(line)
                    } else if line.hasPrefix("index="), !current.isEmpty {
                        streamBlocks.append(current); current = [line]
                    } else {
                        current.append(line)
                    }
                }
                if !current.isEmpty { streamBlocks.append(current) }
                var parsed: [(String, String)] = []
                for block in streamBlocks {
                    let typeLine = block.first(where: { $0.hasPrefix("codec_type=") }) ?? ""
                    guard typeLine == "codec_type=video" || typeLine == "codec_type=audio" else { continue }
                    parsed += videoPairs(from: block, section: typeLine.hasSuffix("video") ? "视频" : "音频")
                }
                parsed += videoPairs(from: formatLines, section: "文件")
                values = parsed
            } else {
                values = text.split(separator: "\n").compactMap { line -> (String, String)? in
                    let raw = String(line).trimmingCharacters(in: .whitespaces)
                    guard let separator = raw.range(of: " : ") else { return nil }
                    let field = String(raw[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let key = field.components(separatedBy: "]").last?.trimmingCharacters(in: .whitespaces) ?? field
                    let rawValue = String(raw[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                    let value = repairedLegacyMetadataText(rawValue, key: key)
                    if coordinateKeys.contains(key) { return nil }
                    guard let label = labels[key], !value.isEmpty, value != "N/A", value != "unknown", value != "0/0" else { return nil }
                    return (label, displayedValue(for: key, value: value))
                }
            }
            if let coordinate {
                values.append(("位置", "正在查询位置…"))
                let initialValues = values
                let fallback = String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
                locationLookupTask = Task { @MainActor in
                    var locationText = fallback
                    do {
                        guard let request = MKReverseGeocodingRequest(
                            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        ) else { throw CLError(.geocodeFoundNoResult) }
                        request.preferredLocale = LanguageSettings.shared.locale
                        let mapItems = try await request.mapItems
                        try Task.checkCancellation()
                        if let address = mapItems.first?.address?.fullAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                           !address.isEmpty {
                            locationText = address.replacingOccurrences(of: "\n", with: "，")
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        locationText = fallback
                    }
                    var updated = initialValues
                    if let index = updated.lastIndex(where: { $0.0 == "位置" }) { updated[index].1 = locationText }
                    EXIFWindowController.shared.update(title: record.fileName, values: updated)
                }
            }
            let motionPhoto = record.mediaType == "photo"
                ? detectMotionPhoto(fileURL: fileURL, metadataText: text, exiftool: executable)
                : nil
            EXIFWindowController.shared.show(title: record.fileName,
                                             values: values.isEmpty ? [("信息", "没有可用信息")] : values,
                                             mediaType: record.mediaType,
                                             motionPhoto: motionPhoto)
        } catch {
            EXIFWindowController.shared.show(title: record.fileName, values: [("错误", error.localizedDescription)])
        }
    }

    private func showAudioInfo(record: PhotoRecord, fileURL: URL) {
        let exiftoolCandidates = ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"]
        let ffprobeCandidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        guard let exiftool = exiftoolCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            EXIFWindowController.shared.show(title: record.fileName, values: [("错误", localizedText("找不到 exiftool"))], mediaType: "audio")
            return
        }

        func run(_ executable: String, _ arguments: [String]) -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                // Embedded artwork can be much larger than a pipe buffer, so read it
                // concurrently with process execution instead of waiting for exit first.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return data
            } catch { return Data() }
        }

        let exifData = run(exiftool, ["-j", "-G1", "-a", "-s", "-api", "LargeFileSupport=1", fileURL.path])
        let exifObject = (try? JSONSerialization.jsonObject(with: exifData)) as? [[String: Any]]
        let rawExif = exifObject?.first ?? [:]
        var exif: [String: Any] = [:]
        for (key, value) in rawExif {
            let plainKey = key.components(separatedBy: ":").last ?? key
            if exif[plainKey] == nil { exif[plainKey] = value }
        }

        var format: [String: Any] = [:]
        var audioStream: [String: Any] = [:]
        if let ffprobe = ffprobeCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            let probeData = run(ffprobe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", fileURL.path])
            if let probe = (try? JSONSerialization.jsonObject(with: probeData)) as? [String: Any] {
                format = probe["format"] as? [String: Any] ?? [:]
                let streams = probe["streams"] as? [[String: Any]] ?? []
                audioStream = streams.first(where: { ($0["codec_type"] as? String) == "audio" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 })
                    ?? streams.first(where: { ($0["codec_type"] as? String) == "audio" }) ?? [:]
            }
        }

        func string(_ source: [String: Any], _ keys: [String]) -> String? {
            for key in keys {
                guard let value = source[key] else { continue }
                let text: String
                if let value = value as? String { text = value }
                else if let value = value as? NSNumber { text = value.stringValue }
                else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != "N/A", trimmed.lowercased() != "unknown" {
                    return repairedLegacyMetadataText(trimmed, key: key)
                }
            }
            return nil
        }
        let tags = format["tags"] as? [String: Any] ?? [:]
        let streamTags = audioStream["tags"] as? [String: Any] ?? [:]
        func tag(_ keys: [String]) -> String? {
            let variants = keys.flatMap { [$0, $0.lowercased(), $0.uppercased()] }
            return string(tags, variants) ?? string(streamTags, variants) ?? string(exif, keys)
        }
        func add(_ section: String, _ label: String, _ value: String?, to values: inout [(String, String)]) {
            guard let value, !value.isEmpty else { return }
            values.append(("\(section) · \(label)", value))
        }
        func formattedDuration(_ text: String?) -> String? {
            guard let text, let seconds = Double(text), seconds.isFinite else { return text }
            let total = Int(seconds.rounded())
            let hours = total / 3600, minutes = (total % 3600) / 60, remainder = total % 60
            return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder) : String(format: "%d:%02d", minutes, remainder)
        }
        func formattedBitrate(_ text: String?) -> String? {
            guard let text, let bits = Double(text) else { return text }
            return bits >= 1_000_000 ? String(format: "%.2f Mb/秒", bits / 1_000_000) : String(format: "%.0f kb/秒", bits / 1_000)
        }
        func formattedSampleRate(_ text: String?) -> String? {
            guard let text, let rate = Double(text) else { return text }
            return rate >= 1000 ? String(format: rate.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0f kHz" : "%.1f kHz", rate / 1000) : "\(Int(rate)) Hz"
        }
        func formattedSize(_ text: String?) -> String? {
            guard let text, let bytes = Int64(text) else { return text }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        func systemDate(_ text: String?) -> String? {
            guard let text else { return nil }
            for pattern in ["yyyy:MM:dd HH:mm:ssXXXXX", "yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"] {
                let parser = DateFormatter()
                parser.locale = Locale(identifier: "en_US_POSIX")
                parser.dateFormat = pattern
                if let date = parser.date(from: text) {
                    let formatter = DateFormatter()
                    formatter.locale = LanguageSettings.shared.locale
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .medium
                    return formatter.string(from: date)
                }
            }
            return text
        }
        func bitDepthDescription() -> String? {
            let text = string(audioStream, ["bits_per_raw_sample", "bits_per_sample"]) ?? string(exif, ["BitsPerSample"])
            guard let text, let bits = Int(text), bits > 0 else { return nil }
            return "\(bits) 位"
        }
        func channelDescription() -> String? {
            if let layout = string(audioStream, ["channel_layout"]), !layout.isEmpty {
                if layout == "mono" { return "单声道" }
                if layout == "stereo" { return "立体声" }
                return layout
            }
            guard let channels = string(audioStream, ["channels"]) else { return string(exif, ["ChannelMode", "NumChannels"]) }
            return channels == "1" ? "单声道" : (channels == "2" ? "立体声" : "\(channels) 声道")
        }

        var values: [(String, String)] = []
        add("音乐", "标题", tag(["Title"]) ?? fileURL.deletingPathExtension().lastPathComponent, to: &values)
        add("音乐", "艺术家", tag(["Artist"]), to: &values)
        add("音乐", "专辑", tag(["Album"]), to: &values)
        let albumArtist = tag(["AlbumArtist", "Band"])
        if albumArtist != tag(["Artist"]) { add("音乐", "专辑艺术家", albumArtist, to: &values) }
        add("音乐", "作曲", tag(["Composer"]), to: &values)
        add("音乐", "曲目", tag(["Track", "TrackNumber"]), to: &values)
        add("音乐", "碟片", tag(["DiscNumber", "Disc"]), to: &values)
        add("音乐", "年份", tag(["Date", "Year"]), to: &values)
        add("音乐", "流派", tag(["Genre"]), to: &values)
        add("音乐", "ISRC", tag(["ISRC"]), to: &values)
        add("音乐", "条码", tag(["BARCODE", "MCN"]), to: &values)
        add("音乐", "版权", tag(["Copyright"]), to: &values)

        add("音频", "格式", string(exif, ["FileType"]) ?? string(format, ["format_long_name", "format_name"]), to: &values)
        add("音频", "编码", string(audioStream, ["codec_long_name", "codec_name"]) ?? string(exif, ["AudioEncoding"]), to: &values)
        add("音频", "时长", formattedDuration(string(format, ["duration"]) ?? string(audioStream, ["duration"])), to: &values)
        add("音频", "码率", formattedBitrate(string(audioStream, ["bit_rate"]) ?? string(format, ["bit_rate"]) ?? string(exif, ["AudioBitrate"])), to: &values)
        add("音频", "采样率", formattedSampleRate(string(audioStream, ["sample_rate"]) ?? string(exif, ["SampleRate"])), to: &values)
        add("音频", "采样格式", string(audioStream, ["sample_fmt"]), to: &values)
        add("音频", "位深", bitDepthDescription(), to: &values)
        add("音频", "声道", channelDescription(), to: &values)
        add("音频", "编码器", tag(["Encoder", "EncoderSettings"]), to: &values)

        let encoder = tag(["Encoder", "EncoderSettings"])
        if let encoder, encoder.localizedCaseInsensitiveContains("VoiceMemos") {
            add("录音来源", "应用", "Apple 语音备忘录", to: &values)
            add("录音来源", "设备", encoder.localizedCaseInsensitiveContains("iPhone") ? "iPhone" : nil, to: &values)
        }
        add("录音来源", "录制时间", systemDate(tag(["CreateDate", "MediaCreateDate"])), to: &values)

        add("文件", "文件名", fileURL.lastPathComponent, to: &values)
        add("文件", "所在目录", fileURL.deletingLastPathComponent().path, to: &values)
        add("文件", "文件路径", fileURL.path, to: &values)
        add("文件", "文件大小", formattedSize(string(format, ["size"])) ?? string(exif, ["FileSize"]), to: &values)
        add("文件", "MIME 类型", string(exif, ["MIMEType"]), to: &values)
        add("文件", "文件修改时间", systemDate(string(exif, ["FileModifyDate"])), to: &values)
        add("文件", "文件访问时间", systemDate(string(exif, ["FileAccessDate"])), to: &values)
        add("文件", "文件权限", string(exif, ["FilePermissions"]), to: &values)

        var artwork: NSImage?
        for key in ["Picture", "CoverArt"] {
            let data = run(exiftool, ["-b", "-\(key)", fileURL.path])
            if !data.isEmpty, let image = NSImage(data: data) { artwork = image; break }
        }
        EXIFWindowController.shared.show(title: record.fileName,
                                         values: values.isEmpty ? [("信息", "没有可用信息")] : values,
                                         mediaType: "audio", artwork: artwork)
    }

    func preview(id: Int64) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        QuickLookPreview.shared.toggle(URL(fileURLWithPath: record.directory).appendingPathComponent(record.fileName))
    }
}

private final class QuickLookPreview: NSObject, @preconcurrency QLPreviewPanelDataSource, @unchecked Sendable {
    static let shared = QuickLookPreview()
    private var url: URL?

    @MainActor func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor func toggle(_ url: URL) {
        let panel = QLPreviewPanel.shared()
        if panel?.isVisible == true { panel?.orderOut(nil); return }
        show(url)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem { url! as NSURL }
}

private struct MediaInfoField: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

private struct MediaInfoSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    var fields: [MediaInfoField]
}

private struct MediaInfoLayoutPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func reportMediaInfoHeight(_ name: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: MediaInfoLayoutPreferenceKey.self, value: [name: proxy.size.height])
            }
        }
    }
}

@MainActor private final class MediaInfoWindowModel: ObservableObject {
    @Published var fileName: String
    @Published var values: [(String, String)]
    @Published var mediaType: String
    @Published var artwork: NSImage?
    @Published var motionPhoto: MotionPhotoPlayback?
    @Published var showsDetails = false
    var compactHeightChanged: ((CGFloat) -> Void)?
    private var layoutHeights: [String: CGFloat] = [:]

    init(fileName: String, values: [(String, String)], mediaType: String, artwork: NSImage?, motionPhoto: MotionPhotoPlayback?) {
        self.fileName = fileName
        self.values = values
        self.mediaType = mediaType
        self.artwork = artwork
        self.motionPhoto = motionPhoto
    }

    func toggleDetails() {
        showsDetails.toggle()
        if !showsDetails { reportCompactHeightIfReady() }
    }

    func updateLayoutHeights(_ values: [String: CGFloat]) {
        layoutHeights = values
        if !showsDetails { reportCompactHeightIfReady() }
    }

    private func reportCompactHeightIfReady() {
        guard let header = layoutHeights["header"],
              let content = layoutHeights["compact"],
              let footer = layoutHeights["footer"] else { return }
        // Keep a small clearance around compact content so its window shows
        // all fields without needing a scroller.
        compactHeightChanged?(header + content + footer + 40)
    }
}

private final class LoopingPlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var representedURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func configure(url: URL) {
        guard representedURL != url else { return }
        representedURL = url
        player?.pause()
        looper = nil
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
        playerLayer.player = queue
        queue.play()
    }

    func stop() {
        player?.pause()
        playerLayer.player = nil
        looper = nil
        player = nil
        representedURL = nil
    }
}

private struct LoopingMotionPhotoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingPlayerNSView {
        let view = LoopingPlayerNSView()
        view.configure(url: url)
        return view
    }

    func updateNSView(_ nsView: LoopingPlayerNSView, context: Context) { nsView.configure(url: url) }
    static func dismantleNSView(_ nsView: LoopingPlayerNSView, coordinator: Void) { nsView.stop() }
}

/// Captures Space only while the compact image, motion-photo, video, or audio
/// inspector (or its Quick Look panel) is active.
private struct CompactMediaQuickLookKeyHandler: NSViewRepresentable {
    let url: URL?
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.url = url
        context.coordinator.isEnabled = isEnabled
        context.coordinator.window = nsView.window
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        var url: URL?
        var isEnabled = false
        weak var window: NSWindow?
        private var monitor: Any?

        override init() {
            super.init()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.keyCode == 49,
                      self.isEnabled,
                      let url = self.url,
                      (NSApp.isActive && (self.window == nil || self.window?.isKeyWindow == true))
                        || QLPreviewPanel.shared()?.isVisible == true
                else { return event }
                Task { @MainActor in QuickLookPreview.shared.toggle(url) }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }
}

@MainActor private final class MediaThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
    private var representedURL: URL?

    func load(_ url: URL?) {
        guard representedURL != url else { return }
        representedURL = url
        image = nil
        guard let url else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 720, height: 480),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            guard representedURL == url else { return }
            image = representation?.nsImage
        }
    }
}

private struct MediaDimensionDiagram: View {
    @StateObject private var thumbnailLoader = MediaThumbnailLoader()
    @ObservedObject private var language = LanguageSettings.shared
    let width: Int?
    let height: Int?
    let megapixels: Double?
    let framesPerSecond: Double?
    let isVideo: Bool
    let fileURL: URL?
    let motionPhotoURL: URL?

    private var isMotionPhoto: Bool { motionPhotoURL != nil }

    private func arrow(from start: CGPoint, to end: CGPoint, doubleEnded: Bool = true) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        func head(at point: CGPoint, angle: Double, path: inout Path) {
            let length = 7.0
            for offset in [-Double.pi * 0.82, Double.pi * 0.82] {
                path.move(to: point)
                path.addLine(to: CGPoint(x: point.x + cos(angle + offset) * length,
                                         y: point.y + sin(angle + offset) * length))
            }
        }
        head(at: end, angle: angle, path: &path)
        if doubleEnded { head(at: start, angle: angle + .pi, path: &path) }
        return path
    }

    private func imageFrame(in size: CGSize) -> CGRect? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let ratio = Double(width) / Double(height)
        let availableWidth = max(80, size.width - 105)
        let availableHeight = max(60, size.height - 90)
        let rectangleWidth = min(availableWidth, availableHeight * ratio)
        let rectangleHeight = rectangleWidth / ratio
        return CGRect(x: max(22, (size.width - rectangleWidth) / 2 - 8),
                      y: max(24, (size.height - rectangleHeight) / 2 - 8),
                      width: rectangleWidth, height: rectangleHeight)
    }

    var body: some View {
        GeometryReader { proxy in
            let thumbnailFrame = imageFrame(in: proxy.size)
            ZStack {
                if let image = thumbnailLoader.image, let thumbnailFrame {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: thumbnailFrame.width, height: thumbnailFrame.height)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .opacity(isMotionPhoto ? 1 : 0.50)
                        .position(x: thumbnailFrame.midX, y: thumbnailFrame.midY)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onTapGesture(count: 2) {
                            guard !isVideo, let fileURL else { return }
                            QuickLookPreview.shared.show(fileURL)
                        }
                }
                if let motionPhotoURL, let thumbnailFrame {
                    LoopingMotionPhotoView(url: motionPhotoURL)
                        .frame(width: thumbnailFrame.width, height: thumbnailFrame.height)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .position(x: thumbnailFrame.midX, y: thumbnailFrame.midY)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onTapGesture(count: 2) {
                            guard !isVideo, let fileURL else { return }
                            QuickLookPreview.shared.show(fileURL)
                        }
                }
                if isVideo, let fileURL, let thumbnailFrame {
                    Button {
                        QuickLookPreview.shared.show(fileURL)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: min(thumbnailFrame.width, thumbnailFrame.height) * 0.25,
                                          weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                    .accessibilityLabel(localizedText("播放视频预览"))
                    .position(x: thumbnailFrame.midX, y: thumbnailFrame.midY)
                }
                Canvas { context, size in
            guard let width, let height, width > 0, height > 0 else {
                context.draw(Text(localizedText("没有尺寸信息")).font(.callout).foregroundStyle(.secondary),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            guard let frame = imageFrame(in: size) else { return }
            let line = GraphicsContext.Shading.color(.primary.opacity(0.72))
            let secondary = GraphicsContext.Shading.color(.secondary.opacity(0.58))

            if isVideo {
                let offsets = [18.0, 9.0]
                for (index, offset) in offsets.enumerated() {
                    let back = frame.offsetBy(dx: -offset, dy: -offset * 0.65)
                    let occluder = index + 1 < offsets.count
                        ? frame.offsetBy(dx: -offsets[index + 1], dy: -offsets[index + 1] * 0.65)
                        : frame
                    var visibleEdges = Path()
                    let radius = 7.0
                    visibleEdges.move(to: CGPoint(x: back.minX + radius, y: back.minY))
                    visibleEdges.addLine(to: CGPoint(x: back.maxX - radius, y: back.minY))
                    visibleEdges.addQuadCurve(to: CGPoint(x: back.maxX, y: back.minY + radius),
                                              control: CGPoint(x: back.maxX, y: back.minY))
                    if occluder.minY > back.minY + radius {
                        visibleEdges.addLine(to: CGPoint(x: back.maxX, y: occluder.minY))
                    }
                    visibleEdges.move(to: CGPoint(x: back.minX + radius, y: back.minY))
                    visibleEdges.addQuadCurve(to: CGPoint(x: back.minX, y: back.minY + radius),
                                              control: CGPoint(x: back.minX, y: back.minY))
                    visibleEdges.addLine(to: CGPoint(x: back.minX, y: back.maxY - radius))
                    visibleEdges.addQuadCurve(to: CGPoint(x: back.minX + radius, y: back.maxY),
                                              control: CGPoint(x: back.minX, y: back.maxY))
                    visibleEdges.addLine(to: CGPoint(x: occluder.minX, y: back.maxY))
                    context.stroke(visibleEdges, with: secondary,
                                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
            context.stroke(Path(roundedRect: frame, cornerRadius: 7), with: line,
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            let horizontalY = frame.maxY + 25
            var horizontalGuides = Path()
            horizontalGuides.move(to: CGPoint(x: frame.minX, y: frame.maxY))
            horizontalGuides.addLine(to: CGPoint(x: frame.minX, y: horizontalY + 5))
            horizontalGuides.move(to: CGPoint(x: frame.maxX, y: frame.maxY))
            horizontalGuides.addLine(to: CGPoint(x: frame.maxX, y: horizontalY + 5))
            context.stroke(horizontalGuides, with: secondary,
                           style: StrokeStyle(lineWidth: 1, lineCap: .round))
            context.stroke(arrow(from: CGPoint(x: frame.minX, y: horizontalY),
                                 to: CGPoint(x: frame.maxX, y: horizontalY)), with: line,
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            context.draw(Text("\(width.formatted()) px").font(.callout).foregroundStyle(.secondary),
                         at: CGPoint(x: frame.midX, y: horizontalY + 14))

            let verticalX = frame.maxX + 25
            var verticalGuides = Path()
            verticalGuides.move(to: CGPoint(x: frame.maxX, y: frame.minY))
            verticalGuides.addLine(to: CGPoint(x: verticalX + 5, y: frame.minY))
            verticalGuides.move(to: CGPoint(x: frame.maxX, y: frame.maxY))
            verticalGuides.addLine(to: CGPoint(x: verticalX + 5, y: frame.maxY))
            context.stroke(verticalGuides, with: secondary,
                           style: StrokeStyle(lineWidth: 1, lineCap: .round))
            context.stroke(arrow(from: CGPoint(x: verticalX, y: frame.minY),
                                 to: CGPoint(x: verticalX, y: frame.maxY)), with: line,
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            context.drawLayer { layer in
                layer.translateBy(x: verticalX + 15, y: frame.midY)
                layer.rotate(by: .degrees(-90))
                layer.draw(Text("\(height.formatted()) px").font(.callout).foregroundStyle(.secondary), at: .zero)
            }

            let pixelText = megapixels.map { String(format: "%.1f MP", $0) }
                ?? (language.language == .chinese ? "像素" : "Pixels")
            if isMotionPhoto {
                context.draw(Text(pixelText).font(.caption.bold()).foregroundStyle(.blue),
                             at: CGPoint(x: frame.maxX - 32, y: max(17, frame.minY - 14)))
            } else if isVideo {
                let diagonalStart = CGPoint(x: frame.minX + 18, y: frame.maxY - 18)
                let diagonalEnd = CGPoint(x: frame.maxX - 18, y: frame.minY + 18)
                context.stroke(arrow(from: diagonalStart, to: diagonalEnd), with: line,
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                // The right side carries frame rate and the vertical ruler, so
                // keep the pixel-count label outside at the upper left.
                context.draw(Text(pixelText).font(.caption.bold()).foregroundStyle(.blue),
                             at: CGPoint(x: frame.minX + 32, y: max(17, frame.minY - 20)))
            } else {
                let diagonalStart = CGPoint(x: frame.minX + 18, y: frame.maxY - 18)
                let diagonalEnd = CGPoint(x: frame.maxX - 18, y: frame.minY + 18)
                context.stroke(arrow(from: diagonalStart, to: diagonalEnd), with: line,
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                let diagonalAngle = atan2(diagonalEnd.y - diagonalStart.y, diagonalEnd.x - diagonalStart.x)
                context.drawLayer { layer in
                    layer.translateBy(x: (diagonalStart.x + diagonalEnd.x) / 2,
                                      y: (diagonalStart.y + diagonalEnd.y) / 2 - 9)
                    layer.rotate(by: .radians(diagonalAngle))
                    layer.draw(Text(pixelText).font(.caption.bold()).foregroundStyle(.primary), at: .zero)
                }
            }

            if isVideo, let framesPerSecond {
                context.draw(Text(String(format: "%.2f FPS", framesPerSecond)).font(.caption.bold()).foregroundStyle(.blue),
                             at: CGPoint(x: frame.maxX - 32, y: max(10, frame.minY - 20)))
            }
                }
                .allowsHitTesting(false)
            }
        }
        // A GeometryReader expands to fill its proposed height.  Leaving this
        // view flexible made the compact-window measurement feed the current
        // window height back into itself whenever Summary/Details was toggled.
        .frame(height: isMotionPhoto ? 275 : (isVideo ? 360 : 215))
        .task(id: fileURL) { thumbnailLoader.load(fileURL) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localizedText("尺寸图"))
        .accessibilityValue(width.flatMap { w in height.map {
            language.language == .chinese ? "宽 \(w) 像素，高 \($0) 像素" : "Width \(w) pixels, height \($0) pixels"
        } } ?? localizedText("没有尺寸信息"))
    }
}

private struct AudioArtworkView: View {
    @ObservedObject private var language = LanguageSettings.shared
    let artwork: NSImage?
    let fileURL: URL?

    private var displaySize: CGSize {
        guard let artwork, artwork.size.width > 0, artwork.size.height > 0 else {
            return CGSize(width: 230, height: 230)
        }
        let aspectRatio = artwork.size.width / artwork.size.height
        let maximumWidth: CGFloat = 360
        let maximumHeight: CGFloat = 250
        let width = min(maximumWidth, maximumHeight * aspectRatio)
        return CGSize(width: width, height: width / aspectRatio)
    }

    var body: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 62, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityLabel(localizedText("没有嵌入封面"))
            }
            if let fileURL {
                Button {
                    QuickLookPreview.shared.show(fileURL)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: min(displaySize.width, displaySize.height) * 0.25,
                                      weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .accessibilityLabel(localizedText("播放音频预览"))
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.secondary.opacity(0.45), lineWidth: 1.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

private struct MediaInfoView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var model: MediaInfoWindowModel
    @ObservedObject private var language = LanguageSettings.shared

    private let fileFields: Set<String> = [
        "文件名", "所在目录", "文件路径", "文件大小", "文件格式", "格式名称", "扩展名", "MIME 类型", "文件权限",
        "文件修改时间", "文件访问时间", "文件属性修改时间", "主要格式", "兼容格式", "媒体流数量", "格式识别可信度"
    ]
    private let imageFields: Set<String> = [
        "图像宽度", "图像高度", "图像尺寸", "像素数（百万）", "EXIF 图像宽度", "EXIF 图像高度", "图像方向",
        "水平分辨率", "垂直分辨率", "分辨率单位", "色彩配置", "色彩原色", "传输特性", "色彩矩阵", "全范围色彩",
        "色度采样格式", "亮度位深", "色度位深", "像素位深", "色彩空间", "旋转角度", "媒体数据大小"
    ]
    private let cameraFields: Set<String> = [
        "设备品牌", "设备型号", "拍摄设备", "系统版本", "镜头品牌", "镜头型号", "镜头参数", "相机类型",
        "照片标识符", "内容标识符", "ExifTool 版本", "EXIF 版本"
    ]
    private let captureFields: Set<String> = [
        "曝光时间", "曝光程序", "感光度（ISO）", "快门速度", "光圈值", "光圈", "亮度值", "曝光补偿", "测光模式",
        "闪光灯", "焦距", "等效 35 毫米焦距", "主体区域", "感光方式", "场景类型", "曝光模式", "白平衡",
        "拍摄类型", "HDR 余量", "信噪比", "色温", "对焦位置", "视角", "合成图像"
    ]
    private let placeFields: Set<String> = [
        "位置", "拍摄位置", "海拔基准", "海拔", "GPS 时间", "速度单位", "移动速度", "拍摄方向基准", "拍摄方向",
        "GPS 日期", "定位精度", "GPS 日期时间", "拍摄时间", "创建时间", "修改时间", "时区", "拍摄时区", "数字化时区"
    ]

    private var isVideo: Bool {
        let extensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "wmv", "mts", "m2ts", "3gp", "webm", "mpg", "mpeg", "ts", "vob"]
        return extensions.contains((model.fileName as NSString).pathExtension.lowercased())
    }

    private var isAudio: Bool { model.mediaType == "audio" || audioExtensions.contains((model.fileName as NSString).pathExtension.lowercased()) }

    private var parsedValues: [(section: String?, label: String, value: String)] {
        model.values.map { originalLabel, value in
            let parts = originalLabel.components(separatedBy: " · ")
            if parts.count == 2 { return (parts[0], parts[1], value) }
            return (nil, originalLabel, value)
        }
    }

    private func firstValue(_ labels: [String], section: String? = nil) -> String? {
        parsedValues.first { field in
            labels.contains(field.label) && (section == nil || field.section == section)
        }?.value
    }

    private func integerValue(_ labels: [String], section: String? = nil) -> Int? {
        guard let value = firstValue(labels, section: section) else { return nil }
        return Int(value.split(whereSeparator: { !$0.isNumber }).first ?? "")
    }

    private func decimalValue(_ labels: [String], section: String? = nil) -> Double? {
        guard let value = firstValue(labels, section: section) else { return nil }
        let token = value.split(whereSeparator: { !$0.isNumber && $0 != "." }).first ?? ""
        return Double(token)
    }

    private var pixelWidth: Int? {
        isVideo ? integerValue(["宽度", "编码宽度"], section: "视频") : integerValue(["图像宽度", "EXIF 图像宽度"])
    }

    private var pixelHeight: Int? {
        isVideo ? integerValue(["高度", "编码高度"], section: "视频") : integerValue(["图像高度", "EXIF 图像高度"])
    }

    private var megapixels: Double? {
        if let value = decimalValue(["像素数（百万）"]) { return value }
        guard let pixelWidth, let pixelHeight else { return nil }
        return Double(pixelWidth * pixelHeight) / 1_000_000
    }

    private var framesPerSecond: Double? {
        firstValue(["平均帧率", "标称帧率"], section: "视频").flatMap { value in
            Double(value.split(whereSeparator: { !$0.isNumber && $0 != "." }).first ?? "")
        }
    }

    private func captureTimeWithRelativeDescription(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.isLenient = true
        guard let date = formatter.date(from: value), date <= Date() else { return value }
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let twoMonthsAgo = calendar.date(byAdding: .month, value: -2, to: now) ?? now
        let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        let threeYearsAgo = calendar.date(byAdding: .year, value: -3, to: now) ?? now
        let relative: String
        if date >= twoMonthsAgo {
            let days = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                                       to: calendar.startOfDay(for: now)).day ?? 0)
            relative = language.language == .chinese
                ? (days == 0 ? "今天" : "\(days)天前")
                : (days == 0 ? "Today" : "\(days) \(days == 1 ? "day" : "days") ago")
        } else if date >= oneYearAgo {
            let months = max(2, calendar.dateComponents([.month], from: date, to: now).month ?? 2)
            relative = language.language == .chinese ? "\(months)个月前" : "\(months) months ago"
        } else if date >= threeYearsAgo {
            let components = calendar.dateComponents([.year, .month], from: date, to: now)
            let years = max(1, components.year ?? 1)
            let months = max(0, components.month ?? 0)
            if language.language == .chinese {
                relative = months == 0 ? "\(years)年前" : "\(years)年\(months)个月前"
            } else {
                let yearText = "\(years) \(years == 1 ? "year" : "years")"
                relative = months == 0 ? "\(yearText) ago" : "\(yearText) \(months) months ago"
            }
        } else {
            let years = max(1, calendar.dateComponents([.year], from: date, to: now).year ?? 1)
            relative = language.language == .chinese ? "\(years)年前" : "\(years) years ago"
        }
        return "\(value)\n\(relative)"
    }

    private var fileURL: URL? {
        if let path = firstValue(["文件路径"]) { return URL(fileURLWithPath: path) }
        guard let directory = firstValue(["所在目录"]) else { return nil }
        return URL(fileURLWithPath: directory).appendingPathComponent(model.fileName)
    }

    private var compactFields: [(String, String, String)] {
        func combined(_ values: [String?], separator: String = " · ") -> String? {
            let available = values.compactMap { $0 }.filter { !$0.isEmpty }
            return available.isEmpty ? nil : available.joined(separator: separator)
        }
        func named(_ label: String, _ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return "\(label)：\(value)"
        }
        let device = combined([
            named("品牌", firstValue(["设备品牌"])),
            named("型号", firstValue(["设备型号", "拍摄设备"]))
        ], separator: "\n")
        let captureTime = firstValue(["拍摄时间", "创建时间"]).map(captureTimeWithRelativeDescription)
        let format = firstValue(["文件格式", "格式名称", "封装格式"])
        var result: [(String, String, String)] = []
        func add(_ label: String, _ value: String?, _ icon: String) {
            if let value, !value.isEmpty { result.append((label, value, icon)) }
        }
        if isAudio {
            add("标题", firstValue(["标题"], section: "音乐") ?? model.fileName, "music.note")
            add("艺术家", firstValue(["艺术家"], section: "音乐"), "person.fill")
            add("专辑", firstValue(["专辑"], section: "音乐"), "square.stack.fill")
            add("专辑艺术家", firstValue(["专辑艺术家"], section: "音乐"), "person.2.fill")
            add("作曲", firstValue(["作曲"], section: "音乐"), "music.quarternote.3")
            add("曲目", combined([
                named("曲目", firstValue(["曲目"], section: "音乐")),
                named("碟片", firstValue(["碟片"], section: "音乐"))
            ], separator: "\n"), "number")
            add("年份与流派", combined([
                named("年份", firstValue(["年份"], section: "音乐")),
                named("流派", firstValue(["流派"], section: "音乐"))
            ], separator: "\n"), "calendar")
            add("时长与大小", combined([
                named("时长", firstValue(["时长"], section: "音频")),
                named("大小", firstValue(["文件大小"], section: "文件"))
            ], separator: "\n"), "timer")
            add("音频格式", combined([
                named("格式", firstValue(["格式"], section: "音频")),
                named("编码", firstValue(["编码"], section: "音频"))
            ], separator: "\n"), "waveform")
            add("音频参数", combined([
                named("码率", firstValue(["码率"], section: "音频")),
                named("采样率", firstValue(["采样率"], section: "音频")),
                named("位深", firstValue(["位深"], section: "音频")),
                named("声道", firstValue(["声道"], section: "音频"))
            ], separator: "\n"), "slider.horizontal.3")
            add("录音来源", combined([
                named("应用", firstValue(["应用"], section: "录音来源")),
                named("设备", firstValue(["设备"], section: "录音来源")),
                named("时间", firstValue(["录制时间"], section: "录音来源"))
            ], separator: "\n"), "mic.fill")
        } else {
            add("格式", format, "doc.badge.gearshape")
            add("文件大小", firstValue(["文件大小"]), "externaldrive")
        }
        if isVideo {
            add("时长", firstValue(["时长（秒）"], section: "文件") ?? firstValue(["时长（秒）"], section: "视频"), "timer")
            add("设备", device, "iphone")
            add("视频", combined([
                named("编码", firstValue(["编码格式"], section: "视频")),
                named("码率", firstValue(["码率"], section: "视频"))
            ], separator: "\n"), "video")
            add("音频", combined([
                named("编码", firstValue(["编码格式"], section: "音频")),
                named("采样率", firstValue(["音频采样率"], section: "音频")),
                named("声道", firstValue(["声道数"], section: "音频"))
            ], separator: "\n"), "waveform")
        } else if !isAudio {
            add("设备", device, "camera")
            let lensModel = firstValue(["镜头型号"])
            let lensParameters = firstValue(["镜头参数"])
            add("镜头", combined([
                lensModel.map { "型号：\($0)" },
                lensParameters
            ], separator: "\n"), "camera.aperture")
            add("拍摄参数", combined([
                named("快门", firstValue(["快门速度", "曝光时间"])),
                named("光圈", firstValue(["光圈值", "光圈"])),
                named("ISO", firstValue(["感光度（ISO）"])),
                named("焦距", firstValue(["焦距"]))
            ], separator: "\n"), "camera.metering.matrix")
        }
        if !isAudio {
            add("拍摄时间", captureTime, "calendar")
            add("位置", firstValue(["位置"]), "location")
        }
        return result
    }

    private var sections: [MediaInfoSection] {
        var groups: [String: MediaInfoSection] = [:]
        let order = ["音乐", "音频", "录音来源", "文件", "图像", "相机", "拍摄参数", "日期与位置", "视频", "其他"]
        let metadata: [String: (String, String)] = [
            "音乐": ("音乐", "music.note"), "录音来源": ("录音来源", "mic.fill"),
            "文件": ("文件", "doc.fill"), "图像": ("图像", "photo.fill"), "相机": ("相机", "camera.fill"),
            "拍摄参数": ("拍摄参数", "camera.aperture"), "日期与位置": ("日期与位置", "location.fill"),
            "视频": ("视频", "video.fill"), "音频": ("音频", "waveform"), "其他": ("其他", "info.circle.fill")
        ]
        for (originalLabel, value) in model.values {
            let explicit = originalLabel.components(separatedBy: " · ")
            let group: String
            let label: String
            label = explicit.count == 2 ? explicit[1] : originalLabel
            if explicit.first == "音乐" { group = "音乐" }
            else if explicit.first == "录音来源" { group = "录音来源" }
            else if fileFields.contains(label) { group = "文件" }
            else if imageFields.contains(label) { group = "图像" }
            else if cameraFields.contains(label) { group = "相机" }
            else if captureFields.contains(label) { group = "拍摄参数" }
            else if placeFields.contains(label) { group = "日期与位置" }
            else if explicit.first == "视频" { group = "视频" }
            else if explicit.first == "音频" { group = "音频" }
            else if explicit.first == "文件" { group = "文件" }
            else { group = "其他" }
            let description = metadata[group] ?? (group, "info.circle.fill")
            if groups[group] == nil { groups[group] = MediaInfoSection(id: group, title: description.0, icon: description.1, fields: []) }
            groups[group]?.fields.append(MediaInfoField(label: label, value: value))
        }
        return order.compactMap { groups[$0] }
    }

    private func copyDisplayedResults() {
        let rows: [(String, String)]
        if model.showsDetails {
            rows = model.values
        } else {
            rows = [("文件名", model.fileName)] + compactFields.map { ($0.0, $0.1) }
        }
        let separator = language.language == .chinese ? "：" : ": "
        let text = rows.map { "\(localizedFieldLabel($0.0))\(separator)\(localizedMetadataValue($0.1))" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.motionPhoto != nil ? "livephoto" : (isAudio ? "waveform" : (isVideo ? "video.fill" : "photo.fill")))
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.fileName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(localizedText(model.showsDetails ? "全部媒体信息" : "重要媒体信息"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func compactField(named label: String) -> (String, String, String)? {
        compactFields.first { $0.0 == label }
    }

    private func styledValue(_ value: String) -> Text {
        let lines = localizedMetadataValue(value).components(separatedBy: "\n")
        let inlineLabels = Set([
            "品牌", "型号", "焦距范围", "最大光圈", "快门", "光圈", "ISO", "焦距", "曲目", "碟片",
            "年份", "流派", "时长", "大小", "格式", "编码", "码率", "采样率", "位深", "声道", "应用", "设备", "时间",
            "Manufacturer", "Model", "Focal range", "Maximum aperture", "Shutter", "Aperture", "Focal Length", "Track", "Disc",
            "Year", "Genre", "Duration", "Size", "Format", "Codec", "Bit Rate", "Sample Rate", "Bit Depth", "Channels", "Application", "Device", "Time"
        ])
        var output = Text("")
        for (index, line) in lines.enumerated() {
            let styledLine: Text
            if let colon = line.firstIndex(where: { $0 == "：" || $0 == ":" }),
               inlineLabels.contains(String(line[..<colon]).trimmingCharacters(in: .whitespaces)) {
                let valueStart = line.index(after: colon)
                styledLine = Text(String(line[...colon])).foregroundColor(.secondary)
                    + Text(String(line[valueStart...])).foregroundColor(.primary)
            } else {
                styledLine = Text(line).foregroundColor(.primary)
            }
            if index > 0 { output = output + Text("\n") }
            output = output + styledLine
        }
        return output
    }

    @ViewBuilder private func compactFieldView(_ field: (String, String, String)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: field.2)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedText(field.0)).font(.callout).foregroundStyle(.secondary)
                styledValue(field.1).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.vertical, 11)
    }

    @ViewBuilder private func compactRow(_ labels: [String]) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(labels, id: \.self) { label in
                if let field = compactField(named: label) { compactFieldView(field) }
            }
        }
    }

    @ViewBuilder private var compactContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isAudio {
                AudioArtworkView(artwork: model.artwork, fileURL: fileURL)
            } else {
                MediaDimensionDiagram(width: pixelWidth, height: pixelHeight, megapixels: megapixels,
                                      framesPerSecond: framesPerSecond, isVideo: isVideo, fileURL: fileURL,
                                      motionPhotoURL: model.motionPhoto?.url)
                    .padding(.horizontal, 12)
            }
            VStack(spacing: 0) {
                if isAudio {
                    compactRow(["标题", "艺术家", "专辑"])
                    Divider()
                    compactRow(["专辑艺术家", "作曲", "曲目"])
                    Divider()
                    compactRow(["年份与流派", "时长与大小", "音频格式"])
                    Divider()
                    compactRow(["音频参数", "录音来源"])
                } else {
                    compactRow(isVideo ? ["格式", "文件大小", "时长"] : ["格式", "文件大小", "设备"])
                    Divider()
                    compactRow(isVideo ? ["视频", "音频"] : ["镜头", "拍摄参数"])
                    Divider()
                    compactRow(isVideo ? ["设备", "拍摄时间", "位置"] : ["拍摄时间", "位置"])
                }
            }
        }
    }

    @ViewBuilder private var detailedContent: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 12) {
                    Label(localizedText(section.title), systemImage: section.icon).font(.headline)
                    Divider()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 360), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 14) {
                        ForEach(section.fields) { field in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(localizedText(field.label)).font(.callout).foregroundStyle(.secondary)
                                styledValue(field.value).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button {
                model.toggleDetails()
            } label: {
                // Both labels participate in layout, so the native button keeps
                // its compact natural width and never shifts while toggling.
                ZStack(alignment: .leading) {
                    Label(localizedText(model.showsDetails ? "精简信息" : "详细信息"),
                          systemImage: model.showsDetails ? "rectangle.compress.vertical" : "list.bullet.rectangle")
                    Label(localizedText("详细信息"), systemImage: "list.bullet.rectangle").hidden()
                    Label(localizedText("精简信息"), systemImage: "rectangle.compress.vertical").hidden()
                }
            }
            .focusable(false)
            Button(action: copyDisplayedResults) {
                Label(localizedText("复制结果"), systemImage: "doc.on.doc")
            }
            .focusable(false)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .reportMediaInfoHeight("header")
            if model.showsDetails {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        detailedContent
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    compactContent
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .reportMediaInfoHeight("compact")
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Keep the controls in the normal vertical layout instead of overlaying
            // them. The scroll view above therefore always yields this exact space.
            bottomBar
                .reportMediaInfoHeight("footer")
        }
        .frame(minWidth: 680, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
        .onPreferenceChange(MediaInfoLayoutPreferenceKey.self) { model.updateLayoutHeights($0) }
        .background(CompactMediaQuickLookKeyHandler(url: fileURL,
                                                    isEnabled: !model.showsDetails))
    }
}

private struct OpenMediaPromptView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.tint)
            Text(localizedText("请选择一个媒体文件"))
                .font(.title3.weight(.semibold))
            Text(localizedText("请通过“文件 > 打开媒体…”或按 ⌘O 选择图片、视频或音频文件。"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(localizedText("打开媒体…")) {
                EXIFWindowController.shared.openMediaFile()
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(.regularMaterial)
    }
}

@MainActor private final class EXIFWindowController {
    static let shared = EXIFWindowController()
    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var model: MediaInfoWindowModel?
    private var languageObservation: AnyCancellable?
    private let fileOpenModel = AppModel()

    private init() {
        languageObservation = LanguageSettings.shared.$language.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.refreshWindowTitle() }
        }
    }

    private func refreshWindowTitle() {
        guard let model else { return }
        window?.title = "\(localizedText("媒体信息")): \(model.fileName)"
    }

    private func replaceWindowContent(with rootView: AnyView, title: String, contentSize: NSSize) {
        let host = NSHostingController(rootView: rootView)
        hostingController = host
        let targetWindow: NSWindow
        if let window {
            targetWindow = window
            targetWindow.contentViewController = host
        } else {
            targetWindow = NSWindow(contentViewController: host)
            window = targetWindow
        }
        targetWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        targetWindow.title = title
        targetWindow.isReleasedWhenClosed = false
        targetWindow.minSize = NSSize(width: 680, height: 520)
        targetWindow.setContentSize(contentSize)
        targetWindow.backgroundColor = .clear
        targetWindow.isOpaque = false
        targetWindow.titlebarAppearsTransparent = true
        if !targetWindow.isVisible { targetWindow.center() }
    }

    func showOpenMediaPrompt() {
        model = nil
        replaceWindowContent(with: AnyView(OpenMediaPromptView()), title: localizedText("媒体信息"),
                             contentSize: NSSize(width: 800, height: 560))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func resizeForCompactContent(_ contentHeight: CGFloat) {
        guard let window else { return }
        let currentContentHeight = window.contentRect(forFrameRect: window.frame).height
        let visibleHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let titlebarHeight = window.frame.height - currentContentHeight
        let maximumContentHeight = max(520, visibleHeight - titlebarHeight - 28)
        let targetContentHeight = min(max(contentHeight, 520), maximumContentHeight)
        guard abs(currentContentHeight - targetContentHeight) > 2 else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.height += targetContentHeight - currentContentHeight
        frame.origin.y = top - frame.height
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame, frame.minY < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    @discardableResult
    func openMediaFile() -> Bool {
        let panel = NSOpenPanel()
        panel.title = localizedText("打开媒体…")
        panel.prompt = localizedText("打开媒体…")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie, .audio]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        fileOpenModel.showEXIF(fileURL: url)
        return true
    }

    func show(title: String, values: [(String, String)], mediaType: String = "photo", artwork: NSImage? = nil,
              motionPhoto: MotionPhotoPlayback? = nil) {
        if window == nil || model == nil {
            let model = MediaInfoWindowModel(fileName: title, values: values, mediaType: mediaType, artwork: artwork,
                                             motionPhoto: motionPhoto)
            model.compactHeightChanged = { [weak self] height in self?.resizeForCompactContent(height) }
            self.model = model
            replaceWindowContent(with: AnyView(MediaInfoView(model: model)),
                                 title: "\(localizedText("媒体信息")): \(title)",
                                 contentSize: NSSize(width: 800, height: 720))
        } else {
            model?.fileName = title
            model?.values = values
            model?.mediaType = mediaType
            model?.artwork = artwork
            model?.motionPhoto = motionPhoto
            model?.showsDetails = false
            window?.title = "\(localizedText("媒体信息")): \(title)"
            if let size = window?.frame.size, size.width < 680 || size.height < 520 {
                window?.setContentSize(NSSize(width: 800, height: 680))
                window?.center()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(title: String, values: [(String, String)]) {
        guard let window, let model else { return }
        window.title = "\(localizedText("媒体信息")): \(title)"
        model.fileName = title
        model.values = values
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @ObservedObject private var language = LanguageSettings.shared
    @State private var sortOrder: [KeyPathComparator<PhotoRecord>] = [KeyPathComparator(\.fileName)]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(localizedText("搜索文件名或目录"), text: $model.search).textFieldStyle(.roundedBorder)
                Menu(localizedText("筛选")) {
                    Picker(localizedText("类型"), selection: $model.mediaFilter) {
                        Text(localizedText("全部类型")).tag("全部类型")
                        Text(localizedText("照片")).tag("照片")
                        Text(localizedText("视频")).tag("视频")
                    }
                    Picker(localizedText("同步状态"), selection: $model.syncFilter) {
                        Text(localizedText("全部状态")).tag("全部状态")
                        Text(localizedText("已同步")).tag("已同步")
                        Text(localizedText("未同步")).tag("未同步")
                    }
                }
                Button(localizedText("更新数据库")) { model.reindex() }.disabled(model.isIndexing)
                Button(localizedText("刷新")) { model.reload() }
                Button(localizedText("标记已同步")) { model.update(status: "synced") }.disabled(model.selected.isEmpty)
                Button(localizedText("标记未同步")) { model.update(status: "unsynced") }.disabled(model.selected.isEmpty)
            }.padding().contentShape(Rectangle()).onTapGesture { model.selected.removeAll() }
            Table(model.records, selection: $model.selected, sortOrder: $sortOrder) {
                TableColumn(localizedText("文件名"), value: \.fileName).width(min: 180)
                TableColumn(localizedText("目录"), value: \.directory).width(min: 360)
                TableColumn(localizedText("类型"), value: \.mediaType) { record in
                    Image(systemName: record.mediaType == "video" ? "video.fill" : "photo.fill")
                        .foregroundStyle(record.mediaType == "video" ? .purple : .blue)
                        .help(localizedText(record.mediaType == "video" ? "视频" : "照片"))
                }.width(55)
                TableColumn(localizedText("同步"), value: \.syncStatus) { record in
                    Image(systemName: record.syncStatus == "synced" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(record.syncStatus == "synced" ? .green : .red)
                        .help(localizedText(record.syncStatus == "synced" ? "已同步" : "未同步"))
                }.width(55)
                TableColumn("MD5", value: \.md5).width(min: 220)
            }
            .contextMenu(forSelectionType: PhotoRecord.ID.self) { selection in
                Button(localizedText("标记已同步")) {
                    model.selected = selection
                    model.update(status: "synced")
                }.disabled(selection.isEmpty)
                Button(localizedText("标记未同步")) {
                    model.selected = selection
                    model.update(status: "unsynced")
                }.disabled(selection.isEmpty)
                Divider()
                Button(localizedText("在 Finder 中打开文件")) {
                    if let id = selection.first { model.openInFinder(id: id) }
                }.disabled(selection.count != 1)
                Button(localizedText("打开所在目录")) {
                    if let id = selection.first { model.openDirectory(id: id) }
                }.disabled(selection.count != 1)
                Button(localizedText("显示简介")) {
                    if let id = selection.first { model.showDetails(id: id) }
                }.disabled(selection.count != 1)
                Button(localizedText("查看媒体信息")) {
                    if let id = selection.first { model.showEXIF(id: id) }
                }.disabled(selection.count != 1)
            }
            Divider(); HStack {
                if model.isIndexing { ProgressView().controlSize(.small) }
                Text(model.isIndexing ? model.indexProgress : (model.selected.isEmpty ? model.message :
                    (language.language == .chinese
                        ? "已选择 \(model.selected.count) 项，共 \(model.records.count) 条"
                        : "\(model.selected.count) selected, \(model.records.count) total")))
                Spacer()
            }.padding(8).contentShape(Rectangle()).onTapGesture { model.selected.removeAll() }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .background(MainWindowCloseHandler())
        .onAppear { model.start() }
        .onChange(of: model.search) { _ in model.reload() }
        .onChange(of: model.mediaFilter) { _ in model.reload() }
        .onChange(of: model.syncFilter) { _ in model.reload() }
        .onChange(of: sortOrder) { order in model.sort(using: order) }
        .onChange(of: language.language) { _ in model.reload() }
        .background(KeyPreviewHandler(model: model))
        .alert(localizedText("错误"), isPresented: .constant(model.error != nil), presenting: model.error) { _ in
            Button(localizedText("确定")) { model.error = nil }
        } message: { Text($0) }
    }
}

private struct KeyPreviewHandler: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.makeFirstResponder(nsView)
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    final class Coordinator: NSObject {
        let model: AppModel
        private var monitor: Any?
        init(model: AppModel) {
            self.model = model
            super.init()
            let model = model
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifiers.contains(.command),
                   !modifiers.contains(.option), !modifiers.contains(.control),
                   event.charactersIgnoringModifiers?.lowercased() == "i" {
                    Task { @MainActor in
                        guard model.selected.count == 1, let id = model.selected.first else { return }
                        model.showEXIF(id: id)
                    }
                    return nil
                }
                guard event.keyCode == 49 else { return event }
                Task { @MainActor in
                    guard let id = model.selected.first else { return }
                    model.preview(id: id)
                }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private struct MainWindowCloseHandler: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.delegate = context.coordinator
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            NSApp.terminate(nil)
            return true
        }
    }
}

private struct LanguageSettingsView: View {
    @ObservedObject private var settings = LanguageSettings.shared

    var body: some View {
        Form {
            Picker(localizedText("语言"), selection: Binding(
                get: { settings.preferredLanguage },
                set: { settings.select($0) }
            )) {
                Text(localizedText("简体中文")).tag(AppLanguage.chinese)
                Text(localizedText("英语")).tag(AppLanguage.english)
            }
            .pickerStyle(.radioGroup)
            Text(localizedText("语言更改将在下次启动时生效。"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 390, height: 180)
    }
}

#if STANDALONE_MEDIA_INFO
@MainActor
private final class StandaloneMediaInfoDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var currentURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
            EXIFWindowController.shared.showOpenMediaPrompt()
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            EXIFWindowController.shared.show(title: url.lastPathComponent,
                                             values: [("错误", LanguageSettings.shared.language == .chinese
                                                ? "找不到文件：\(url.path)" : "File not found: \(url.path)")])
            return
        }
        currentURL = url
        model.showEXIF(fileURL: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ViewMediaInfoApp: App {
    @NSApplicationDelegateAdaptor(StandaloneMediaInfoDelegate.self) private var delegate
    var body: some Scene {
        Settings { LanguageSettingsView() }
            .commands {
                CommandGroup(after: .newItem) {
                    Button(localizedText("打开媒体…")) {
                        EXIFWindowController.shared.openMediaFile()
                    }
                    .keyboardShortcut("o", modifiers: .command)
                }
            }
    }
}
#else
@main
struct PhotoSyncManagerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
        Settings { LanguageSettingsView() }
    }
}
#endif
