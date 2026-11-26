//
//  MBV47ModelDownloadManager.swift
//  MiniCPM-V-demo
//
//  MiniCPM-V 4.7 的公网下载（35B-A3B MoE 43 个文件 / 1B 2 个文件）。
//
//  与其它下载器的区别：这两个模型是**多文件**的（MoE 的 experts/ 有 40 个分片），
//  所以这里按文件各起一个 MBModelDownloadHelperV2，并用一个小窗口控制并发
//  （43 个一起拉会把带宽和 Flash 都打满）。
//

import Foundation
import UIKit

/// 走这套多文件下载的模型。常量取值集中在 `MiniCPMV47Const` / `MiniCPMV47_1BConst` /
/// `MiniCPM5_15B_A2_5BConst`。
enum MBV47Variant {
    case moe
    case oneB
    /// MiniCPM5-15B-A2.5B 的一个精度：主模型（LES 单文件）+ 专家预测器
    case minicpm5MoE(MiniCPM5_15B_A2_5BConst.Precision)

    var displayedName: String {
        switch self {
        case .moe:  return MiniCPMV47Const.displayedName
        case .oneB: return MiniCPMV47_1BConst.displayedName
        case .minicpm5MoE(let p): return p.displayedName
        }
    }

    var documentsDirName: String {
        switch self {
        case .moe:  return MiniCPMV47Const.documentsDirName
        case .oneB: return MiniCPMV47_1BConst.documentsDirName
        case .minicpm5MoE: return MiniCPM5_15B_A2_5BConst.documentsDirName
        }
    }

    var userDefaultsKey: String {
        switch self {
        case .moe:  return MiniCPMV47Const.userDefaultsKey
        case .oneB: return MiniCPMV47_1BConst.userDefaultsKey
        case .minicpm5MoE: return MiniCPM5_15B_A2_5BConst.userDefaultsKey
        }
    }

    var hfBase: String {
        switch self {
        case .moe:  return MiniCPMV47Const.hfBase
        case .oneB: return MiniCPMV47_1BConst.hfBase
        case .minicpm5MoE(let p): return p.hfBase
        }
    }

    var msBase: String {
        switch self {
        case .moe:  return MiniCPMV47Const.msBase
        case .oneB: return MiniCPMV47_1BConst.msBase
        case .minicpm5MoE(let p): return p.msBase
        }
    }

    var files: [ModelDownloadFile] {
        switch self {
        case .moe:  return MiniCPMV47Const.downloadFiles
        case .oneB: return MiniCPMV47_1BConst.downloadFiles
        case .minicpm5MoE(let p): return MiniCPM5_15B_A2_5BConst.downloadFiles(for: p)
        }
    }

    var modelType: CurrentUsingModelTypeV2 {
        switch self {
        case .moe:  return .V47MoE
        case .oneB: return .V47_1B
        case .minicpm5MoE: return .V5_15B_A2_5B
        }
    }
}

final class MBV47ModelDownloadManager: NSObject {

    static let moe = MBV47ModelDownloadManager(variant: .moe)
    static let oneB = MBV47ModelDownloadManager(variant: .oneB)
    static let minicpm5Q3gud = MBV47ModelDownloadManager(variant: .minicpm5MoE(.q3gud))
    static func minicpm5(_ p: MiniCPM5_15B_A2_5BConst.Precision) -> MBV47ModelDownloadManager {
        switch p {
        case .q3gud: return minicpm5Q3gud
        }
    }

    let variant: MBV47Variant

    /// 同时在传的文件数。43 个一起拉会把带宽打满、也拖慢单文件，
    /// 反而让「先出来」的那个大文件迟迟不完。
    private let maxConcurrent = 3

    private var wrapper: MTMDWrapperExample?
    private let queue = DispatchQueue(label: "com.minicpm.v47.download")

    private init(variant: MBV47Variant) {
        self.variant = variant
        super.init()
    }

    // MARK: - 状态

    /// localName -> helper（懒建，只建一次）
    private var helpers: [String: MBModelDownloadHelperV2] = [:]
    /// localName -> 0...1
    private var fileProgress: [String: CGFloat] = [:]
    private var fileState: [String: DownloadStatus] = [:]
    private var inFlight: Set<String> = []
    private var startTimes: [String: Date] = [:]
    /// 每个文件已经尝试过几次。失败到上限就放弃，避免网络长时间不通时无限重试。
    private var attempts: [String: Int] = [:]
    private let maxAttemptsPerFile = 3

    var detailedProgressHandler: ((DownloadProgressInfo) -> Void)?
    var completionHandler: ((String, Bool) -> Void)?

    /// 上一次失败是不是因为「所有下载源都拿不到这个文件」。
    ///
    /// 与普通网络失败分开，UI 才能提示「模型可能还没开源」而不是笼统的「下载出错」——
    /// 模型没发布时 404 和断网在 FDownLoader 眼里是一样的，光看它分不出来。
    /// 每次 `downloadAll()` 开头复位；`completionHandler(success: false)` 之前置位。
    private(set) var lastFailureWasUnavailable = false

    // MARK: - 路径

    private func documentsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 该文件应落在哪儿（`Documents/<documentsDirName>/<localName>`）。
    func localURL(for file: ModelDownloadFile) -> URL {
        documentsDir()
            .appendingPathComponent(variant.documentsDirName)
            .appendingPathComponent(file.localName)
    }

    // MARK: - 装配

    func setupDownloadManager(with wrapper: MTMDWrapperExample) {
        self.wrapper = wrapper
        for f in variant.files {
            _ = helper(for: f)
        }
        reconcileStatusFromDisk()
        // 先恢复续传（它可能真的把下载跑起来），再清理残片。
        restoreDownloadProgress()
        // 只在**没有下载在跑**时才清理：`purgeStaleCacheEntries` 按「尺寸 != 期望」判定，
        // 而下到一半的临时文件尺寸必然不符 —— 若此时清理，会把正在续传的进度删掉。
        if !hasAnyDownloadActive() {
            purgeStaleCacheEntries()
        }
    }

    // MARK: - 残留缓存清理

    /// 删掉「尺寸对不上」的缓存/临时文件。
    ///
    /// 为什么必须做：`FDownLoader` 一旦在缓存目录看到同名文件就直接报成功
    /// （`if (fileExists(downLoaderPath)) { state = PauseSuccess; }`）。
    /// 而下载失败时落下的残片（例如服务端返回 200 + 一小段错误 JSON）会让它
    /// **永远下不到真文件**；更糟的是带 Range 续传会把残片和真数据拼成一个坏文件。
    ///
    /// 缓存文件名是 `FDownLoader` 私有的（`md5(url) + "." + ext`），这里按同样规则
    /// 反推出来比对。
    private func purgeStaleCacheEntries() {
        let fm = FileManager.default
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? ""
        let tmp = NSTemporaryDirectory()
        for f in variant.files {
            for (url, expected) in sourceURLs(for: f) {
                guard let digested = url.md5() else { continue }
                let ext = URL(string: url)?.pathExtension ?? "bin"
                let name = "\(digested).\(ext)"
                for dir in [caches, tmp] {
                    let path = (dir as NSString).appendingPathComponent(name)
                    guard fm.fileExists(atPath: path) else { continue }
                    var size: Int64 = 0
                    if let attrs = try? fm.attributesOfItem(atPath: path),
                       let s = attrs[.size] as? Int64 {
                        size = s
                    }
                    if size != expected {
                        try? fm.removeItem(atPath: path)
                        debugLog("-->> 清理尺寸不符的下载残留 \(name)（\(size) != \(expected)）")
                    }
                }
            }
        }
    }

    /// 该 variant 实际可用的下载源（空地址代表「暂无该镜像」，不能拿去拼 URL）。
    ///
    /// 拼 URL 的地方一律走这里，别直接拼 `variant.msBase`：镜像没建时它是空串，
    /// `"\(空串)/文件名"` 会变成 `"/文件名"`，既不报错也下载不到，只会白白多一次失败。
    private var downloadBases: [String] {
        [variant.hfBase, variant.msBase].filter { !$0.isEmpty }
    }

    /// 某个源下该文件的仓库内路径。两个源的目录结构可能不同（见 `ModelDownloadFile.msRemotePath`）。
    private func remotePath(for file: ModelDownloadFile, under base: String) -> String {
        base == variant.msBase ? (file.msRemotePath ?? file.remotePath) : file.remotePath
    }

    /// 该文件参与下载的全部地址及各自的期望字节数：主源、备用源，再加旧版镜像。
    private func sourceURLs(for file: ModelDownloadFile) -> [(url: String, bytes: Int64)] {
        downloadBases.map { ("\($0)/\(remotePath(for: file, under: $0))", file.bytes) }
            + file.legacyMirrors.map { ($0.url, $0.bytes) }
    }

    /// 探测「这个文件在各源上到底存不存在」。
    ///
    /// 为什么不能靠下载器报错判断：`FDownLoader` 对 404、连接被拒、超时一律回同一个
    /// `failed`，所以模型还没开源时用户只会看到「下载失败」，会以为是 App 或网络的锅。
    /// 这里在真正开下之前先 HEAD 一遍，把「所有源都没有这个文件」单独识别出来。
    ///
    /// 判定口径（`notPublished` = true 表示「文件确实不在，几乎可以肯定是没开源」）：
    /// - 任一源 200/206            → 能下，交给下载器
    /// - 没有源能拿到，但有源明确回 404/401/403 → 判定未公开。404 是「不存在」，401/403 是
    ///   「仓库还是 private」，两者对用户都是「还没开放」。
    /// - 所有源都连不上（DNS/超时/5xx） → 不判未公开，按普通网络失败处理，免得误导。
    ///
    /// 最后一条只要求**至少一个源明确说不存在**，而不是所有源都如此：国内网络下 HF 经常
    /// 直接连不上（连 401 都收不到），而 MS 会明确回 404。这时「MS 说不存在 + HF 连不上」
    /// 的真实结论就是「没开源」，不该因为 HF 超时而退化成一个笼统的失败。
    ///
    /// **某个源一确认能下就立刻返回**，不等其它源超时：国内直连 HF 会卡满超时，
    /// 若等所有源都回来，用户每次点下载都要先白等十几秒才看到进度条。
    private func probeAvailability(of file: ModelDownloadFile,
                                   completion: @escaping (Bool) -> Void) {
        let urls = sourceURLs(for: file).map(\.url)
        guard !urls.isEmpty else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        let lock = NSLock()
        var sawReachable = false           // 任一源能拿到
        var sawDefinitelyAbsent = false    // 任一源明确 404/401/403
        var pending = urls.count           // 还没回来的源
        var finished = false               // 已给出结论，后续回调一律丢弃

        /// 收一个结果。能下就立刻返回；「未公开」必须等所有源都回来（要确认没有可用的）。
        func settle(_ reachable: Bool?, _ absent: Bool, verdict: @escaping (Bool) -> Void) {
            lock.lock()
            if finished { lock.unlock(); return }
            if reachable == true { sawReachable = true }
            if absent { sawDefinitelyAbsent = true }
            pending -= 1
            let decideNow = sawReachable            // 有一个能下就够了
            let allBack = pending <= 0
            let notPublished = !sawReachable && sawDefinitelyAbsent
            if decideNow || allBack { finished = true }
            lock.unlock()

            if decideNow {
                verdict(false)
            } else if allBack {
                verdict(notPublished)
            }
        }

        for urlString in urls {
            guard let url = URL(string: urlString) else {
                settle(nil, false, verdict: completion)
                continue
            }
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 8     // 国内直连 HF 会卡满；8 秒足够判断「连不上」
            req.cachePolicy = .reloadIgnoringLocalCacheData

            URLSession.shared.dataTask(with: req) { _, response, error in
                guard let http = response as? HTTPURLResponse else {
                    // 连不上（DNS/超时/被墙）：不构成「文件不存在」的证据。
                    if let error = error {
                        debugLog("-->> 探测: \(String(urlString.prefix(80))) 无响应（\(error.localizedDescription)）")
                    }
                    settle(nil, false, verdict: completion)
                    return
                }
                switch http.statusCode {
                case 200, 206:
                    settle(true, false, verdict: completion)
                case 401, 403, 404:
                    settle(nil, true, verdict: completion)
                default:
                    settle(nil, false, verdict: completion)   // 5xx：不当作不存在
                }
            }.resume()
        }
    }

    private func helper(for file: ModelDownloadFile) -> MBModelDownloadHelperV2? {
        if let h = queue.sync(execute: { helpers[file.localName] }) { return h }
        guard let wrapper = wrapper ?? sharedWrapperProbe else { return nil }
        let h = MBModelDownloadHelperV2(
            wrapper: wrapper,
            modelName: variant.displayedName,
            modelUrl: "\(variant.hfBase)/\(file.remotePath)",
            filename: fullLocalName(file),
            // MS 是单个公共仓库、按模型分子目录存放，路径可能与 HF 不同（见 msRemotePath）。
            backupModelUrl: variant.msBase.isEmpty
                ? nil
                : "\(variant.msBase)/\(file.msRemotePath ?? file.remotePath)",
            extraModelUrls: file.legacyMirrors.map(\.url)
        )
        queue.sync { helpers[file.localName] = h }
        return h
    }

    /// `setupDownloadManager` 之前的兜底：详情页一定会先调 setup，
    /// 这里只是防止极端时序下拿到 nil。
    private var sharedWrapperProbe: MTMDWrapperExample? { MBV47WrapperHolder.shared }

    /// helper 的 `filename` 必须带上模型子目录，否则会平铺到 Documents 根。
    private func fullLocalName(_ file: ModelDownloadFile) -> String {
        "\(variant.documentsDirName)/\(file.localName)"
    }

    // MARK: - 状态查询

    func isFileDownloaded(_ file: ModelDownloadFile) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: file).path)
    }

    func fileStatus(_ file: ModelDownloadFile) -> String {
        if isFileDownloaded(file) { return "downloaded" }
        return (queue.sync { fileState[file.localName] }) == .failed ? "failed" : "download"
    }

    func allFilesDownloaded() -> Bool {
        variant.files.allSatisfy { isFileDownloaded($0) }
    }

    func hasAnyDownloadActive() -> Bool {
        !queue.sync { inFlight }.isEmpty
    }

    /// 已下载的字节 / 总字节（用常量里的期望尺寸当分母，不必等 HEAD）。
    func overallProgress() -> CGFloat {
        let files = variant.files
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return 0 }
        var done: Double = 0
        let prog = queue.sync { fileProgress }
        for f in files {
            if isFileDownloaded(f) {
                done += Double(f.bytes)
            } else {
                done += Double(f.bytes) * Double(prog[f.localName] ?? 0)
            }
        }
        return CGFloat(min(1.0, done / Double(total)))
    }

    func downloadedBytes() -> Int64 {
        let files = variant.files
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        return Int64(Double(total) * Double(overallProgress()))
    }

    func totalBytes() -> Int64 {
        variant.files.reduce(Int64(0)) { $0 + $1.bytes }
    }

    // MARK: - 与磁盘对账

    /// 与磁盘对账：只把**确实存在**的文件标成完成，绝不把已有状态（尤其 `.failed`）
    /// 往回退成 `.notStarted`。
    ///
    /// 早先这里无条件写 `.notStarted`，而详情页每次 UI 刷新都会调它 —— 于是下载失败后
    /// `.failed` 立刻被抹掉，`pump()` 又从头重试，形成无限重试循环（实测刷出 696 次
    /// "多源 race 启动"、把 app 打崩）。
    func reconcileStatusFromDisk() {
        for f in variant.files {
            let exists = isFileDownloaded(f)
            queue.sync {
                if exists {
                    fileState[f.localName] = .completed
                    fileProgress[f.localName] = 1.0
                } else if fileState[f.localName] == nil {
                    fileState[f.localName] = .notStarted
                }
            }
        }
    }

    /// App 被杀后重进：FDownLoader 里还留着「下载中」的缓存条目，接着跑。
    private func restoreDownloadProgress() {
        let info = FDownLoaderManager.shareInstance().downLoaderInfo
        guard let info = info, info.count > 0 else { return }
        var resumed = false
        for f in variant.files where !isFileDownloaded(f) {
            guard let h = helper(for: f),
                  let key = String(stringLiteral: h.modelUrl).md5() as String?,
                  let obj = info[key] as? FDownLoader,
                  obj.state == .downLoading else { continue }
            resumed = true
            break
        }
        if resumed {
            debugLog("-->> V47(\(variant.documentsDirName)) 检测到未完成下载，自动续传")
            downloadAll()
        }
    }

    // MARK: - 下载

    func downloadAll() {
        reconcileStatusFromDisk()
        lastFailureWasUnavailable = false

        // 每次**用户主动点下载**都重新给满重试额度、并复位 helper 的粘性 status。
        //
        // 两个跨页面存活的状态会把重试卡死（退出详情页也没用，只有重启 App 能恢复）：
        //
        //   1. `MBModelDownloadHelperV2.status` 失败后被置成 "failed"，而进度回调会把它
        //      原样回传；helper 在本 manager 里是**缓存复用**的（比页面活得久），
        //      于是重试的第一个回调就带着陈旧的 "failed" 回来，当场又判失败。
        //   2. `attempts` 到达上限后 `pump()` 一个请求都不发（本意是防内部自旋）。
        //
        // 清在这里（用户主动入口）是安全的：`maxAttemptsPerFile` 要拦的是 pump() 的
        // 自动重试，不该拦用户手动重试。别把这个清理挪进 pump()。
        queue.sync { attempts.removeAll() }
        for (_, h) in queue.sync(execute: { helpers }) {
            h.status = "download"
        }

        let pending = variant.files.filter { !isFileDownloaded($0) }
        debugLog("-->> V47(\(variant.documentsDirName)) 待下载 \(pending.count) 个文件，"
                 + "窗口 \(maxConcurrent)")

        for f in pending {
            queue.sync { fileState[f.localName] = .notStarted }
        }

        guard let firstPending = pending.first else {
            pump()
            return
        }

        // 开下之前先确认文件真的在。模型还没开源时两个源都是 404，下载器只会回一个
        // 笼统的 failed，用户看不出是「还没发布」；这里提前区分开。
        probeAvailability(of: firstPending) { [weak self] notPublished in
            guard let self = self else { return }
            if notPublished {
                debugLog("-->> 所有下载源都没有 \(firstPending.remotePath)，判定为尚未发布/未公开")
                self.queue.sync {
                    for f in pending {
                        self.fileState[f.localName] = .failed
                    }
                    self.attempts.removeAll()
                }
                self.lastFailureWasUnavailable = true
                // 回调可能来自 URLSession 的线程；completionHandler 的消费者都在改 UI。
                DispatchQueue.main.async {
                    self.completionHandler?(self.variant.displayedName, false)
                }
                return
            }
            self.pump()
        }
    }

    /// 用「完成一个补一个」的窗口调度，替代一次性全部并发。
    private func pump() {
        // 注意：不要在 filter 里写 `queue.sync { ... $0 ... }` —— 内层闭包的 `$0`
        // 会遮蔽外层元素，编译期报 "expects 0 arguments"。显式取名字。
        let pending = variant.files.filter { f in
            if isFileDownloaded(f) { return false }
            if queue.sync(execute: { inFlight.contains(f.localName) }) { return false }
            if queue.sync(execute: { fileState[f.localName] == .failed }) { return false }
            // 试过太多次就放弃：网络长时间不通时不要一直重启，那只会把 app 刷崩。
            if queue.sync(execute: { attempts[f.localName] ?? 0 }) >= maxAttemptsPerFile { return false }
            return true
        }
        let free = maxConcurrent - queue.sync { inFlight.count }
        guard free > 0, !pending.isEmpty else {
            if !hasAnyDownloadActive() { finishIfComplete() }
            return
        }
        for f in pending.prefix(free) {
            start(f)
        }
    }

    private func start(_ file: ModelDownloadFile) {
        guard let h = helper(for: file) else { return }
        queue.sync {
            inFlight.insert(file.localName)
            fileState[file.localName] = .downloading
            startTimes[file.localName] = Date()
            fileProgress[file.localName] = 0
            attempts[file.localName] = (attempts[file.localName] ?? 0) + 1
        }

        h.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // 用 `status == "downloaded"` 判完成，**不能**用 `progress >= 1`。
                //
                // FDownLoader 在「最后一块数据到达」时就把 progress 打到 1.0，而
                // 真正的落盘（Caches → Documents）发生在**之后**的
                // handleDownloadSuccess 里。用 progress 判会在文件还没搬过去时就摘掉
                // inFlight、pump() 收工、finishIfComplete() 发现文件不在 → 弹「下载失败」，
                // 而几毫秒后文件其实落好了（表现为"报失败但模型能用"）。
                //
                // status 只在 moveItem / copyItem 成功之后才置为 "downloaded"，
                // 所以它才是"文件确实在位"的信号。
                let isDone = (status == "downloaded")
                if isDone {
                    self.queue.sync {
                        self.fileProgress[file.localName] = 1.0
                        self.fileState[file.localName] = .completed
                        self.inFlight.remove(file.localName)
                    }
                    self.report(file)
                    self.pump()
                } else if status == "failed" {
                    self.queue.sync {
                        self.fileState[file.localName] = .failed
                        self.inFlight.remove(file.localName)
                    }
                    self.report(file)
                    self.pump()
                } else {
                    self.queue.sync { self.fileProgress[file.localName] = progress }
                    self.report(file)
                }
            }
        })
    }

    private func report(_ file: ModelDownloadFile) {
        var speed: Double = 0
        let st = queue.sync { startTimes[file.localName] }
        if let st = st {
            let el = Date().timeIntervalSince(st)
            let p = queue.sync { fileProgress[file.localName] } ?? 0
            if el > 0, p > 0 {
                speed = Double(file.bytes) * Double(p) / el
            }
        }
        let info = DownloadProgressInfo(
            modelName: file.localName,
            status: queue.sync { fileState[file.localName] } ?? .notStarted,
            progress: queue.sync { fileProgress[file.localName] } ?? 0,
            downloadedBytes: Int64(Double(file.bytes) * Double(queue.sync { fileProgress[file.localName] } ?? 0)),
            totalBytes: file.bytes,
            speed: speed,
            estimatedTimeRemaining: speed > 0
                ? Double(file.bytes) * (1 - Double(queue.sync { fileProgress[file.localName] } ?? 0)) / speed
                : 0
        )
        detailedProgressHandler?(info)
    }

    /// 全部文件到齐后做一次整体校验：header 能解析出 `les.moe.layout`，且总字节数
    /// 不少于清单里的期望值（截断的尾部正好是专家区，只看 header 发现不了）。
    private func finishIfComplete() {
        // MiniCPM5-15B-A2.5B：一个文件（专家 + 预测头都内联），但同样要过 header + 大小校验。
        if case .minicpm5MoE(let p) = variant, let main = variant.files.first {
            guard isFileDownloaded(main) else {
                completionHandler?(variant.displayedName, false)
                return
            }
            let problems = MiniCPM5_15B_A2_5BConst.modelProblems(precision: p, at: localURL(for: main))
            if !problems.isEmpty {
                debugLog("-->> MiniCPM5 模型校验失败：\(problems.map { $0.text }.joined(separator: "; "))")
            }
            completionHandler?(variant.displayedName, problems.isEmpty)
            return
        }
        guard allFilesDownloaded() else {
            completionHandler?(variant.displayedName, false)
            return
        }
        if case .moe = variant {
            let root = documentsDir().appendingPathComponent(variant.documentsDirName)
            let modelURL = root.appendingPathComponent(MiniCPMV47Const.modelFileNameResolved())
            let problems = MiniCPMV47Const.modelProblems(at: modelURL)
            guard problems.isEmpty else {
                debugLog("-->> V47 模型校验失败 \(problems.count) 项，判定下载失败")
                completionHandler?(variant.displayedName, false)
                return
            }
        }
        completionHandler?(variant.displayedName, true)
    }

    // MARK: - 删除 / 重置

    func deleteAllDownloadedFiles() {
        let fm = FileManager.default
        for f in variant.files {
            let url = localURL(for: f)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
        // 引擎不再支持的旧布局残留：老用户从上一版升级时要清掉，否则白占约 14 GiB
        //（`-les.gguf` 1.55 GiB + `experts/` 12.89 GiB）。
        if case .moe = variant {
            let root = documentsDir().appendingPathComponent(variant.documentsDirName)
            for name in MiniCPMV47Const.legacyDirectoryNames {
                try? fm.removeItem(at: root.appendingPathComponent(name))
            }
            for name in MiniCPMV47Const.legacyFileNames {
                try? fm.removeItem(at: root.appendingPathComponent(name))
            }
        }
        resetDownloadStates()
        reconcileStatusFromDisk()
    }

    func resetDownloadStates() {
        queue.sync {
            fileState.removeAll()
            fileProgress.removeAll()
            inFlight.removeAll()
            startTimes.removeAll()
            attempts.removeAll()
        }
        for (_, h) in queue.sync(execute: { helpers }) {
            h.status = "download"
        }
    }

    func cancelAllDownloads() {
        FDownLoaderManager.shareInstance().downLoaderInfo.removeAllObjects()
        resetDownloadStates()
    }

    var mainModelManager: MBModelDownloadHelperV2? {
        guard let f = variant.files.first(where: { $0.localName.hasSuffix(".gguf") && !$0.localName.contains("/") })
        else { return nil }
        return helper(for: f)
    }
}

/// 详情页 push 之前 manager 可能还没拿到 wrapper；用一个极小的持有者兜底。
final class MBV47WrapperHolder {
    static var shared: MTMDWrapperExample?
}
