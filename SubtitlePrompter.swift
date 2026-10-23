// 字幕提词器：打开视频后自动匹配同名 SRT，以歌词滚动 + 卡拉 OK 填充的方式显示字幕，方便对着念配音。
import SwiftUI
import AVFoundation
import AppKit
import NaturalLanguage
import UniformTypeIdentifiers

let accent = Color(red: 0.19, green: 0.82, blue: 0.55)
let amber = Color(red: 0.91, green: 0.64, blue: 0.24)

// MARK: - SRT

struct Cue: Identifiable, Equatable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
    var duration: Double { max(end - start, 0.001) }
}

enum SRT {
    static func parse(_ raw: String) -> [Cue] {
        let s = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var items: [(Double, Double, String)] = []
        var lines: [String] = []
        func flush() {
            defer { lines.removeAll() }
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { return }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let b = time(parts[1]) else { return }
            let text = lines[(ti + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { items.append((a, b, text)) }
        }
        for line in s.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { lines.append(line) }
        }
        flush()
        return items.sorted { $0.0 < $1.0 }.enumerated().map { Cue(id: $0.offset, start: $0.element.0, end: $0.element.1, text: $0.element.2) }
    }

    static func time(_ s: String) -> Double? {
        let tok = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let c = tok.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard c.count == 3, let h = Double(c[0]), let m = Double(c[1]), let sec = Double(c[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// 按顺序找：同目录同名 → 「xx视频」对应的「xx字幕」目录 → 名字规范化后相同 → 编号前缀（如 02_19）相同
    static func findSubtitle(for video: URL) -> URL? {
        findCompanion(for: video, exts: ["srt"], folderWord: "字幕")
    }

    /// 没有字幕时找同名台词（.txt / .md），目录换成「文稿」「台词」
    static func findScript(for video: URL) -> URL? {
        findCompanion(for: video, exts: ["txt", "md"], folderWord: "文稿")
            ?? findCompanion(for: video, exts: ["txt", "md"], folderWord: "台词")
    }

    static func findCompanion(for video: URL, exts: [String], folderWord: String) -> URL? {
        let fm = FileManager.default
        let base = video.deletingPathExtension().lastPathComponent
        let dir = video.deletingLastPathComponent()
        let parent = dir.deletingLastPathComponent()
        var dirs = [dir]
        if dir.lastPathComponent.contains("视频") {
            dirs.append(parent.appendingPathComponent(dir.lastPathComponent.replacingOccurrences(of: "视频", with: folderWord)))
        }
        for name in ["粗剪" + folderWord, "成品" + folderWord, folderWord] {
            dirs.append(parent.appendingPathComponent(name))
            dirs.append(dir.appendingPathComponent(name))
        }
        for d in dirs {
            for ext in exts {
                let u = d.appendingPathComponent(base + "." + ext)
                if fm.fileExists(atPath: u.path) { return u }
            }
        }
        var seen = Set<String>()
        let candidates = dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { exts.contains($0.pathExtension.lowercased()) && seen.insert($0.standardizedFileURL.path).inserted }
        let key = normalize(base)
        if let m = candidates.first(where: { normalize($0.deletingPathExtension().lastPathComponent) == key }) { return m }
        guard let prefix = numberPrefix(base) else { return nil }
        let same = candidates.filter { numberPrefix($0.deletingPathExtension().lastPathComponent) == prefix }
        return same.max { commonPrefix(normalize($0.deletingPathExtension().lastPathComponent), key) < commonPrefix(normalize($1.deletingPathExtension().lastPathComponent), key) }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "workbduy", with: "workbuddy")
            .filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
    }

    static func numberPrefix(_ s: String) -> String? {
        guard let r = s.range(of: #"^\d+_\d+"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    static func format(_ cues: [Cue]) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(t, 0) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.enumerated().map { i, c in "\(i + 1)\n\(ts(c.start)) --> \(ts(c.end))\n\(c.text)\n" }
            .joined(separator: "\n")
    }
}

// MARK: - 台词 → 时间码

/// 把没有时间码的台词按口播节奏估出时间：切成 8～15 字的字幕行，按语速算时长，在标点、段落和【停顿】处留出停顿
enum ScriptTimer {
    static let maxUnits = 15.0, minDuration = 1.2, startAt = 0.5
    static let pauseComma = 0.2, pauseSentence = 0.5, pauseColon = 0.3, pauseParagraph = 1.2, pauseMarker = 1.5, pauseTransition = 0.3
    static let transitions = ["接下来", "首先", "其次", "然后", "最后", "另外", "总结一下", "总的来说", "那么"]

    /// 念起来的分量：汉字、数字每个 1，英文单词每个 2，标点和空格不算
    static func units(_ s: String) -> Double {
        var u = 0.0, inWord = false
        for ch in s {
            if ch.isASCII && ch.isLetter {
                if !inWord { u += 2; inWord = true }
            } else {
                inWord = false
                if ch.isLetter || ch.isNumber { u += 1 }
            }
        }
        return u
    }

    /// 去掉 Markdown 记号（加粗、标题、引用、列表），保留文字
    static func plainText(_ md: String) -> String {
        md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil { return "" }
            l = l.replacingOccurrences(of: #"^(#{1,6}|>|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
            return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        }.joined(separator: "\n")
    }

    static func cues(from raw: String, rate: Double) -> [Cue] {
        // 1. 分段：空行或 --- 分隔
        var paragraphs: [String] = [], buf: [String] = []
        for line in plainText(raw).components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { if !buf.isEmpty { paragraphs.append(join(buf)); buf = [] } } else { buf.append(t) }
        }
        if !buf.isEmpty { paragraphs.append(join(buf)) }

        // 2. 每段按标点切成小句，记下每句后面停多久
        var clauses: [(text: String, pause: Double)] = []
        let marker = try! NSRegularExpression(pattern: #"【\s*停顿\s*(?:([0-9.]+)\s*秒)?\s*】"#)
        for para in paragraphs {
            var cur = ""
            func emit(_ pause: Double) {
                let t = cur.trimmingCharacters(in: .whitespaces)
                cur = ""
                if !t.isEmpty && units(t) > 0 { clauses.append((t, pause)) }
                else if !clauses.isEmpty { clauses[clauses.count - 1].pause = max(clauses[clauses.count - 1].pause, pause) }
            }
            // 先把【停顿】换成占位符，扫描时再处理
            let ns = para as NSString
            var pieces: [(String, Double?)] = []
            var last = 0
            for m in marker.matches(in: para, range: NSRange(location: 0, length: ns.length)) {
                pieces.append((ns.substring(with: NSRange(location: last, length: m.range.location - last)), nil))
                let secs = m.range(at: 1).location != NSNotFound ? Double(ns.substring(with: m.range(at: 1))) : nil
                pieces.append(("", secs ?? pauseMarker))
                last = m.range.location + m.range.length
            }
            pieces.append((ns.substring(from: last), nil))

            for (text, markerPause) in pieces {
                if let p = markerPause { emit(p); continue }
                let chars = Array(text)
                for (i, ch) in chars.enumerated() {
                    let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                    let prev: Character? = i > 0 ? chars[i - 1] : nil
                    let asciiBreak = next == nil || next == " "
                    switch ch {
                    case "，": emit(pauseComma)
                    case "。": emit(pauseSentence)
                    case "？", "！": cur.append(ch); emit(pauseSentence)
                    case "；", "：": emit(pauseColon)
                    case ",": if asciiBreak { emit(pauseComma) } else { cur.append(ch) }
                    case ";": if asciiBreak { emit(pauseColon) } else { cur.append(ch) }
                    case ":": if asciiBreak { emit(pauseColon) } else { cur.append(ch) }
                    case "?", "!": if asciiBreak { cur.append(ch); emit(pauseSentence) } else { cur.append(ch) }
                    case ".": if asciiBreak && !(prev?.isNumber ?? false) { emit(pauseSentence) } else { cur.append(ch) }
                    default: cur.append(ch)
                    }
                }
            }
            emit(pauseParagraph)
            if !clauses.isEmpty { clauses[clauses.count - 1].pause = max(clauses[clauses.count - 1].pause, pauseParagraph) }
        }

        // 3. 「这节课，」「接下来，」这种很短的小句并到下一句里，免得一行只有两三个字
        var merged: [(text: String, pause: Double)] = []
        var i = 0
        while i < clauses.count {
            var c = clauses[i]
            while c.pause <= pauseColon, units(c.text) < 5, i + 1 < clauses.count,
                  units(c.text) + units(clauses[i + 1].text) <= maxUnits {
                i += 1
                c = (c.text + (c.pause == pauseColon ? "：" : "，") + clauses[i].text, clauses[i].pause)
            }
            merged.append(c)
            i += 1
        }
        clauses = merged

        // 4. 太长的小句再按词切成几行，行与行之间不停顿
        var lines: [(text: String, pause: Double)] = []
        for c in clauses {
            let parts = split(c.text)
            for (i, part) in parts.enumerated() { lines.append((part, i == parts.count - 1 ? c.pause : 0)) }
        }
        // 转场词前多停一下
        for i in 1..<max(lines.count, 1) where transitions.contains(where: { lines[i].text.hasPrefix($0) }) {
            lines[i - 1].pause += pauseTransition
        }

        // 5. 逐行累加时间
        var t = startAt
        var out: [Cue] = []
        for (i, l) in lines.enumerated() {
            let d = max(minDuration, units(l.text) / max(rate, 0.5))
            out.append(Cue(id: i, start: t, end: t + d, text: l.text))
            t += d + l.pause
        }
        return out
    }

    /// 多行合成一段：中文之间直接连，英文之间补空格
    private static func join(_ lines: [String]) -> String {
        lines.dropFirst().reduce(lines[0]) { acc, l in
            (acc.last?.isASCII ?? false) && (l.first?.isASCII ?? false) ? acc + " " + l : acc + l
        }
    }

    /// 超过 15 个字的句子在词与词之间切开，最后一段太短就并回上一行
    private static func split(_ text: String) -> [String] {
        guard units(text) > maxUnits else { return [text] }
        var starts = Set<Int>()
        let tok = NLTokenizer(unit: .word)
        tok.string = text
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            starts.insert(text.distance(from: text.startIndex, to: r.lowerBound))
            starts.insert(text.distance(from: text.startIndex, to: r.upperBound))
            return true
        }
        let chars = Array(text)
        var parts: [String] = [], from = 0
        while from < chars.count {
            let rest = String(chars[from...])
            if units(rest) <= maxUnits { parts.append(rest); break }
            // 平均分：总共要分几行，这一行就取差不多 1/n
            let n = (units(rest) / maxUnits).rounded(.up)
            let target = units(rest) / n
            var best = -1, bestDiff = Double.infinity
            for i in (from + 1)..<chars.count where starts.contains(i) || chars[i - 1] == " " {
                let u = units(String(chars[from..<i]))
                if u > maxUnits { break }
                if abs(u - target) < bestDiff { bestDiff = abs(u - target); best = i }
            }
            if best < 0 { best = min(from + Int(maxUnits), chars.count) }
            parts.append(String(chars[from..<best]).trimmingCharacters(in: .whitespaces))
            from = best
        }
        if parts.count > 1, units(parts.last!) < 4, units(parts[parts.count - 2] + parts.last!) <= 18 {
            let tail = parts.removeLast()
            parts[parts.count - 1] += tail
        }
        return parts.filter { !$0.isEmpty }
    }
}

// MARK: - 播放

final class Engine: ObservableObject {
    @Published var cues: [Cue] = []
    @Published var videoURL: URL?
    @Published var srtURL: URL?
    @Published var isPlaying = false
    @Published var rate: Float = 1 { didSet { applyRate() } }
    @Published var muted = false { didSet { player?.isMuted = muted } }
    @Published var message: String?
    @Published var mediaDuration: Double?
    @Published var refresh = 0
    @Published var dropTargeted = false
    /// 从台词估出来的时间码：记下原文和语速，改语速时重新算
    @Published var scriptURL: URL?
    @Published var scriptText: String?
    @Published var speechRate: Double = UserDefaults.standard.object(forKey: "speechRate") as? Double ?? 4.5 {
        didSet {
            UserDefaults.standard.set(speechRate, forKey: "speechRate")
            if let s = scriptText { cues = ScriptTimer.cues(from: s, rate: speechRate); refresh += 1 }
        }
    }

    private(set) var player: AVPlayer?
    private var manualBase = 0.0
    private var manualStart: Date?
    private var endObserver: Any?
    private var ticker: Timer?

    init() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.player == nil, self.isPlaying, self.time >= self.duration else { return }
            self.pause()
        }
    }

    var duration: Double {
        if let d = mediaDuration, d.isFinite, d > 0 { return d }
        return (cues.last?.end ?? 0) + 2
    }

    var time: Double {
        if let p = player {
            let t = p.currentTime().seconds
            return t.isFinite ? t : 0
        }
        if let s = manualStart { return min(manualBase + Date().timeIntervalSince(s) * Double(rate), duration) }
        return manualBase
    }

    var title: String {
        (videoURL ?? srtURL ?? scriptURL)?.deletingPathExtension().lastPathComponent
            ?? (scriptText != nil ? "粘贴的台词" : "字幕提词器")
    }

    func activeIndex(at t: Double) -> Int? {
        cues.firstIndex { $0.start <= t && t < $0.end }
    }

    func nextIndex(at t: Double) -> Int? {
        cues.firstIndex { $0.start > t }
    }

    // MARK: 打开文件

    static let scriptExts: Set<String> = ["txt", "md", "markdown"]

    func open(_ urls: [URL]) {
        let ext = { (u: URL) in u.pathExtension.lowercased() }
        let subs = urls.filter { ext($0) == "srt" }
        let scripts = urls.filter { Engine.scriptExts.contains(ext($0)) }
        let media = urls.filter { ext($0) != "srt" && !Engine.scriptExts.contains(ext($0)) }
        if let v = media.first { openMedia(v, autoMatch: subs.isEmpty && scripts.isEmpty) }
        if let s = subs.first { openSRT(s) } else if let s = scripts.first { openScript(s) }
    }

    func openMedia(_ url: URL, autoMatch: Bool) {
        pause()
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = muted
        p.actionAtItemEnd = .pause
        player = p
        videoURL = url
        mediaDuration = nil
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.isPlaying = false
        }
        Task { @MainActor in
            if let d = try? await item.asset.load(.duration) { self.mediaDuration = d.seconds }
        }
        guard autoMatch else { return }
        if let s = SRT.findSubtitle(for: url) {
            openSRT(s)
        } else if let s = SRT.findScript(for: url) {
            openScript(s)
        } else {
            cues = []
            srtURL = nil
            scriptURL = nil
            scriptText = nil
            message = "没找到同名字幕或台词，请点「打开」选一个 SRT 或台词文件"
        }
    }

    func openSRT(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            message = "读不了这个字幕文件：\(url.lastPathComponent)"
            return
        }
        let parsed = SRT.parse(text)
        guard !parsed.isEmpty else {
            message = "这个文件里没有解析出字幕：\(url.lastPathComponent)"
            return
        }
        cues = parsed
        srtURL = url
        scriptURL = nil
        scriptText = nil
        message = nil
        if player == nil { manualBase = 0; manualStart = nil }
        refresh += 1
    }

    /// 读台词文件，按当前语速估出时间码
    func openScript(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            message = "读不了这个台词文件：\(url.lastPathComponent)"
            return
        }
        loadScript(text, from: url)
    }

    /// 从剪贴板粘贴台词
    func pasteScript() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "剪贴板里没有文字"
            return
        }
        loadScript(text, from: nil)
    }

    private func loadScript(_ text: String, from url: URL?) {
        let generated = ScriptTimer.cues(from: text, rate: speechRate)
        guard !generated.isEmpty else {
            message = "台词里没有可以念的文字"
            return
        }
        scriptText = text
        scriptURL = url
        srtURL = nil
        cues = generated
        message = nil
        if player == nil { manualBase = 0; manualStart = nil }
        refresh += 1
    }

    /// 把当前时间码存成 SRT（默认放在台词旁边，同名）
    func exportSRT() {
        guard !cues.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "srt")!]
        panel.nameFieldStringValue = title + ".srt"
        if let dir = (scriptURL ?? videoURL ?? srtURL)?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SRT.format(cues).write(to: url, atomically: true, encoding: .utf8)
            message = "已导出：\(url.lastPathComponent)"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    func choose(subtitleOnly: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = !subtitleOnly
        panel.canChooseDirectories = false
        let textTypes = Engine.scriptExts.compactMap { UTType(filenameExtension: $0) } + [.plainText]
        panel.allowedContentTypes = subtitleOnly
            ? [.init(filenameExtension: "srt")!] + textTypes
            : [.movie, .audio, .init(filenameExtension: "srt")!] + textTypes
        panel.message = subtitleOnly
            ? "选择 SRT 字幕，或没有时间码的台词（.txt / .md，会自动估出时间码）"
            : "选择视频（会自动匹配同名 SRT 或台词），也可以同时选视频和字幕"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    // MARK: 控制

    /// 从头开始（还没到第一句）时先等这么多秒，给人看清第一句、准备开口
    static let leadInLength = 2.0
    /// 预备倒数的结束时刻；倒数期间时间停在原处，倒数完才真正开始走
    @Published private(set) var leadInEnd: Date?
    private var leadInToken = UUID()

    var leadInRemaining: Double { max(0, leadInEnd?.timeIntervalSinceNow ?? 0) }

    func play() {
        let atEnd = time >= duration - 0.05
        if atEnd { seek(0) }
        isPlaying = true
        // 还没念到第一句（含刚播完重来）：先倒数 2 秒
        if atEnd || time <= (cues.first?.start ?? 0) + 0.05 {
            let token = UUID()
            leadInToken = token
            leadInEnd = Date().addingTimeInterval(Engine.leadInLength)
            DispatchQueue.main.asyncAfter(deadline: .now() + Engine.leadInLength) { [weak self] in
                guard let self, self.leadInToken == token, self.leadInEnd != nil else { return }
                self.endLeadIn()
            }
        } else {
            startClock()
        }
    }

    /// 结束倒数，真正开始走
    private func endLeadIn() {
        leadInEnd = nil
        leadInToken = UUID()
        if isPlaying { startClock() }
    }

    private func startClock() {
        if let p = player { p.playImmediately(atRate: rate) } else { manualStart = Date() }
    }

    func pause() {
        leadInEnd = nil
        leadInToken = UUID()
        if let p = player { p.pause() } else if manualStart != nil { manualBase = time; manualStart = nil }
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(_ t: Double) {
        let t = max(0, min(t, duration))
        if leadInEnd != nil && t > 0.05 { endLeadIn() }
        if let p = player {
            p.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh += 1 }
            }
        } else {
            manualBase = t
            if manualStart != nil { manualStart = Date() }
            refresh += 1
        }
    }

    /// 跳到下一句。正在念一句时，跳到下一句前 1 秒（好看到倒数）；
    /// 已经在停顿里时，直接跳到下一句开头，不再回到停顿的开头
    func nextLine() {
        // 预备倒数中按 →：跳过倒数，马上开始
        if leadInEnd != nil { endLeadIn(); return }
        let t = time
        guard let i = cues.firstIndex(where: { $0.start > t + 0.05 }) else { return }
        let target = cues[i].start - preroll(i)
        seek(activeIndex(at: t) == nil || target <= t + 0.05 ? cues[i].start : target)
    }

    /// 当前句播了超过 1 秒就回到本句开头，否则回到上一句
    func prevLine() {
        let t = time
        if let a = activeIndex(at: t), t - cues[a].start > 1 { seek(cues[a].start - preroll(a)); return }
        if let i = cues.lastIndex(where: { $0.start < t - 0.05 - 1 }) { seek(cues[i].start - preroll(i)) }
        else { seek(0) }
    }

    private func preroll(_ i: Int) -> Double {
        let prevEnd = i > 0 ? cues[i - 1].end : 0
        return min(1, max(0, cues[i].start - prevEnd))
    }

    private func applyRate() {
        if let p = player { if isPlaying { p.rate = rate } }
        else if manualStart != nil { manualBase = time; manualStart = Date() }
    }
}

// MARK: - 界面

@main
struct SubtitlePrompterApp: App {
    @StateObject private var engine = Engine()

    var body: some Scene {
        WindowGroup("字幕提词器") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 460, minHeight: 560)
                .onAppear {
                    let args = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !args.isEmpty { engine.open(args) }
                }
        }
        .defaultSize(width: 620, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { engine.choose(subtitleOnly: false) }.keyboardShortcut("o")
                Button("更换字幕…") { engine.choose(subtitleOnly: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("粘贴台词") { engine.pasteScript() }.keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("导出 SRT…") { engine.exportSRT() }.keyboardShortcut("s").disabled(engine.cues.isEmpty)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var e: Engine
    @AppStorage("mirrored") private var mirrored = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderView()
                if e.cues.isEmpty {
                    EmptyHint()
                } else {
                    TimelineView(.animation(minimumInterval: nil, paused: !e.isPlaying)) { _ in
                        let t = e.time
                        let _ = e.refresh
                        VStack(spacing: 0) {
                            LyricsList(time: t)
                            ControlsView(time: t)
                        }
                    }
                }
            }

            // 镜像：整个画面上下翻转。iPad 平放、顶部朝外时，经提词器玻璃反射后文字就是正的
            .scaleEffect(x: 1, y: mirrored ? -1 : 1)

            if e.dropTargeted {
                RoundedRectangle(cornerRadius: 16).stroke(accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $e.dropTargeted) { providers in
            let group = DispatchGroup()
            var urls: [URL] = []
            let lock = NSLock()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { e.open(urls) }
            return true
        }
    }
}

struct HeaderView: View {
    @EnvironmentObject var e: Engine
    @AppStorage("fontSize") private var fontSize = 30.0
    @AppStorage("mirrored") private var mirrored = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Spacer().frame(width: 64) // 留给左上角红绿灯
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let s = e.srtURL {
                        Text("字幕：\(s.lastPathComponent) · 共 \(e.cues.count) 句")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    } else if e.scriptText != nil {
                        Text("\(e.scriptURL.map { "台词：" + $0.lastPathComponent } ?? "粘贴的台词") · 估算时间码 · 共 \(e.cues.count) 句")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                Spacer()
                if e.scriptText != nil {
                    Menu {
                        ForEach([3.0, 3.5, 4.0, 4.5, 5.0, 5.5], id: \.self) { r in
                            Button("\(r.formatted()) 字/秒" + (r == 4.5 ? "（默认）" : "")) { e.speechRate = r }
                        }
                    } label: { Text("\(e.speechRate.formatted()) 字/秒") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("估算时间码用的语速：念不完就调低，念完了字幕还没走完就调高")
                }
                Menu {
                    ForEach([0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5], id: \.self) { r in
                        Button(r == 1 ? "1×（原速）" : "\(r.formatted())×") { e.rate = Float(r) }
                    }
                } label: { Text("\(Double(e.rate).formatted())×") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("播放速度")
                IconButton(system: e.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: e.muted ? "取消静音" : "静音原声") { e.muted.toggle() }
                IconButton(system: "textformat.size.smaller", help: "缩小字号") { fontSize = max(18, fontSize - 2) }
                IconButton(system: "textformat.size.larger", help: "放大字号") { fontSize = min(60, fontSize + 2) }
                Button { mirrored.toggle() } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                        .foregroundStyle(mirrored ? accent : .primary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("m", modifiers: [])
                .help(mirrored ? "取消镜像（M）" : "镜像显示（M）")
                IconButton(system: "arrow.up.left.and.arrow.down.right", help: "全屏（F）") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [])
                Menu {
                    Button { e.choose(subtitleOnly: false) } label: { Label("打开…", systemImage: "folder") }
                    Button { e.choose(subtitleOnly: true) } label: { Label("更换字幕…", systemImage: "captions.bubble") }
                    Button { e.pasteScript() } label: { Label("粘贴台词", systemImage: "doc.on.clipboard") }
                    Divider()
                    Button { e.exportSRT() } label: { Label("导出 SRT…", systemImage: "square.and.arrow.up") }
                        .disabled(e.cues.isEmpty)
                } label: { Image(systemName: "folder") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("打开")
            }
            if let m = e.message {
                Text(m).font(.system(size: 12)).foregroundStyle(amber)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.black)
    }
}

struct IconButton: View {
    let system: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: system).frame(width: 22, height: 22) }
            .buttonStyle(.borderless).help(help)
    }
}

struct EmptyHint: View {
    @EnvironmentObject var e: Engine
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            VideoCaptionGlyph().frame(width: 96, height: 70)
            Text("把视频、字幕或台词拖进来").font(.system(size: 22, weight: .semibold))
            Text("视频会自动找同名 SRT；没有字幕就找同名台词（.txt / .md）。\n没有时间码的台词会按语速自动估出时间码，停顿也会算进去。")
                .multilineTextAlignment(.center).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 12) {
                Button("打开文件…") { e.choose(subtitleOnly: false) }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                Button("粘贴台词") { e.pasteScript() }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// 空白页的图标：一块视频画面，中间是播放键，底部两条字幕
struct VideoCaptionGlyph: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.16)
                    .stroke(accent, lineWidth: max(3, w * 0.045))
                Image(systemName: "play.fill")
                    .font(.system(size: h * 0.26))
                    .foregroundStyle(accent)
                    .offset(x: w * 0.02, y: -h * 0.12)
                VStack(spacing: h * 0.07) {
                    Capsule().fill(accent).frame(width: w * 0.62, height: h * 0.075)
                    Capsule().fill(accent.opacity(0.55)).frame(width: w * 0.42, height: h * 0.075)
                }
                .offset(y: h * 0.27)
            }
        }
    }
}

// MARK: 歌词列表

enum Phase { case past, active, upcoming, future }

struct LyricsList: View {
    @EnvironmentObject var e: Engine
    @AppStorage("fontSize") private var fontSize = 30.0
    let time: Double

    var body: some View {
        // 预备倒数期间：还没开始念，当前这句也算「下一句」，前面显示一段停顿条
        let lead = e.leadInRemaining
        let active = lead > 0 ? nil : e.activeIndex(at: time)
        let next = lead > 0 ? (e.activeIndex(at: time) ?? e.nextIndex(at: time)) : e.nextIndex(at: time)
        // 停在两句之间、且这段停顿有单独一行时，镜头对准停顿行
        let focus = active ?? next.map { lead > 0 || gap(before: $0) >= minGap ? gapID($0) : $0 } ?? max(e.cues.count - 1, 0)

        GeometryReader { geo in
        // 一行最多能放多宽（减掉左右边距），超过就拆成两行
        let lineWidth = (geo.size.width - 56).rounded()
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: fontSize * 0.45) {
                    Color.clear.frame(height: 240)
                    ForEach(e.cues) { cue in
                        let g = gap(before: cue.id)
                        if lead > 0 && cue.id == next {
                            // 预备倒数：2 秒加上离这句开口还剩的时间
                            let wait = max(cue.start - time, 0)
                            GapRow(duration: Engine.leadInLength + wait,
                                   remaining: lead + wait,
                                   isPast: false,
                                   fontSize: fontSize)
                                .id(gapID(cue.id))
                        } else if g >= minGap {
                            let gapStart = cue.start - g
                            GapRow(duration: g,
                                   remaining: (time >= gapStart && time < cue.start) ? cue.start - time : nil,
                                   isPast: time >= cue.start,
                                   fontSize: fontSize)
                                .id(gapID(cue.id))
                        }
                        let phase: Phase = cue.id == active ? .active
                            : (active == nil && cue.id == next) ? .upcoming
                            : cue.end <= time ? .past : .future
                        CueRow(cue: cue,
                               phase: phase,
                               progress: phase == .active ? min(max((time - cue.start) / cue.duration, 0), 1) : (phase == .past ? 1 : 0),
                               fontSize: fontSize,
                               lineWidth: lineWidth)
                            .id(cue.id)
                            .contentShape(Rectangle())
                            .onTapGesture { e.seek(cue.start) }
                    }
                    Color.clear.frame(height: 360)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: focus) { _, f in
                withAnimation(.smooth(duration: 0.7)) { proxy.scrollTo(f, anchor: UnitPoint(x: 0.5, y: 0.42)) }
            }
            .onAppear { proxy.scrollTo(focus, anchor: UnitPoint(x: 0.5, y: 0.42)) }
        }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    /// 短于这个秒数的停顿不单独显示
    private let minGap = 1.0

    /// 第 i 句开口前的停顿秒数（第一句从视频开头算起）
    private func gap(before i: Int) -> Double {
        e.cues[i].start - (i > 0 ? e.cues[i - 1].end : 0)
    }

    /// 停顿行用负数 ID，和句子的 ID 区分开
    private func gapID(_ i: Int) -> Int { -(i + 1) }
}

/// 所有行都用同一字号排版，当前句用 scaleEffect 从中心放大、其余行缩小变淡，
/// 这样切换时只有缩放和透明度在动画，不会因为字号、字重变化而跳动
struct CueRow: View {
    let cue: Cue
    let phase: Phase
    let progress: Double
    let fontSize: Double
    let lineWidth: Double

    var body: some View {
        let lines = LineSplitter.lines(cue.text, size: fontSize, maxWidth: lineWidth)
        KaraokeText(lines: lines, progress: progress, highlighted: phase == .active, size: fontSize)
            .opacity(opacity)
            .scaleEffect(phase == .active ? 1 : 0.74, anchor: .center)
            .frame(minHeight: fontSize * 1.35)
            .animation(.smooth(duration: 0.6), value: phase)
    }

    private var opacity: Double {
        switch phase {
        case .active: return 1
        case .upcoming: return 0.85
        case .future: return 0.55
        case .past: return 0.3
        }
    }
}

/// 一句可能拆成一到两行；绿色按字数比例先填第一行、再填第二行
struct KaraokeText: View {
    let lines: [String]
    let progress: Double
    let highlighted: Bool
    let size: Double

    var body: some View {
        let counts = lines.map { Double(max($0.count, 1)) }
        let total = counts.reduce(0, +)
        VStack(spacing: size * 0.15) {
            ForEach(lines.indices, id: \.self) { i in
                let before = counts[..<i].reduce(0, +)
                KaraokeLine(text: lines[i],
                            progress: min(max((progress * total - before) / counts[i], 0), 1),
                            highlighted: highlighted)
            }
        }
        .font(.system(size: size, weight: .semibold))
    }
}

struct KaraokeLine: View {
    let text: String
    let progress: Double
    let highlighted: Bool

    var body: some View {
        ZStack {
            Text(text).foregroundStyle(.white.opacity(0.92))
            // 绿色层一直在，只靠透明度淡入淡出，读完的句子会慢慢褪回白色
            Text(text).foregroundStyle(accent)
                .mask(alignment: .leading) {
                    GeometryReader { g in Rectangle().frame(width: g.size.width * progress) }
                }
                .opacity(highlighted ? 1 : 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.4)
    }
}

/// 一行放不下时拆成两行：只在词与词之间断开（中文用系统分词），优先标点后，两半宽度尽量相等
enum LineSplitter {
    static let breakAfter: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", ",", ";", ":", "!", "?", " "]
    static let noLineEnd: Set<Character> = ["（", "(", "「", "《", "“"]
    static let noLineStart: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", ",", ".", ";", ":", "!", "?", "）", ")", "」", "》", "”"]

    static func width(_ s: String, _ size: Double) -> Double {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]).width
    }

    static func lines(_ text: String, size: Double, maxWidth: Double) -> [String] {
        guard maxWidth > 0, width(text, size) > maxWidth else { return [text] }
        let chars = Array(text)
        // 分词，记下每个词的起点（按字符下标）
        var wordStarts = Set<Int>()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            wordStarts.insert(text.distance(from: text.startIndex, to: r.lowerBound))
            wordStarts.insert(text.distance(from: text.startIndex, to: r.upperBound))
            return true
        }
        var best: (score: Double, left: String, right: String)?
        for i in 1..<chars.count {
            let a = chars[i - 1], b = chars[i]
            if !wordStarts.contains(i) && !breakAfter.contains(a) { continue }
            if isWordChar(a) && isWordChar(b) { continue }
            if noLineStart.contains(b) || noLineEnd.contains(a) { continue }
            let left = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
            let right = String(chars[i...]).trimmingCharacters(in: .whitespaces)
            guard !left.isEmpty, !right.isEmpty else { continue }
            let wl = width(left, size), wr = width(right, size)
            var score = abs(wl - wr) / (wl + wr)
            if breakAfter.contains(a) { score -= 0.3 }
            if best == nil || score < best!.score { best = (score, left, right) }
        }
        guard let best else { return [text] }
        return [best.left, best.right]
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }
}

/// 两句之间的停顿：条的长度和停顿秒数成正比（1 秒 ≈ 40 像素），提前就能看出要等多久。
/// 停顿进行中，条从右往左缩短；最后 1 秒变成绿色，提示准备开口。
struct GapRow: View {
    let duration: Double
    let remaining: Double?
    let isPast: Bool
    let fontSize: Double

    var body: some View {
        let active = remaining != nil
        let width = min(max(duration * 40 * fontSize / 30, 28), 420)
        let fraction = remaining.map { min(max($0 / duration, 0), 1) } ?? (isPast ? 0 : 1)
        let color: Color = !active ? .white.opacity(isPast ? 0.25 : 0.45)
            : (remaining! <= 1 ? accent : amber)
        HStack(spacing: 10) {
            Image(systemName: "pause.fill").font(.system(size: 11))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(color).frame(width: width * fraction)
            }
            .frame(width: width, height: active ? 8 : 5)
            // 3 秒以上的长停顿才写秒数，短停顿只看横条
            if duration >= 3 {
                Text("停顿 \(Int(duration.rounded())) 秒")
                    .font(.system(size: 13, weight: active ? .semibold : .regular).monospacedDigit())
            }
        }
        .foregroundStyle(color)
        .scaleEffect(active ? 1.15 : 1)
        .padding(.vertical, 4)
        .animation(.smooth(duration: 0.5), value: active)
        .animation(.easeInOut(duration: 0.3), value: remaining.map { $0 <= 1 })
    }
}

// MARK: 底部控制

struct ControlsView: View {
    @EnvironmentObject var e: Engine
    let time: Double

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(fmt(time)).monospacedDigit()
                Slider(value: Binding(get: { min(time, e.duration) }, set: { e.seek($0) }), in: 0...max(e.duration, 0.1))
                    .tint(accent)
                    .controlSize(.small)
                Text(fmt(e.duration)).monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: 34) {
                RoundControl(system: "backward.end.fill", size: 40) { e.prevLine() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("上一句（←）")
                RoundControl(system: e.isPlaying ? "pause.fill" : "play.fill", size: 58) { e.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("播放 / 暂停（空格）")
                RoundControl(system: "forward.end.fill", size: 40) { e.nextLine() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("下一句（→）")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(Color.black)
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(max(t, 0))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct RoundControl: View {
    let system: String
    let size: Double
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(accent, lineWidth: 2)
                Image(systemName: system).font(.system(size: size * 0.36)).foregroundStyle(accent)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
