//
//  MBV47ModelDetailViewController.swift
//  MiniCPM-V-demo
//
//  MiniCPM-V 4.7 详情页：下载（多文件）+ 设为当前模型。
//
//  一个类服务多个模型（4.7 35B-A3B MoE / 4.7 1B / MiniCPM5-15B-A2.5B 的每个精度），由 `variant`
//  决定行数与文案 —— 对用户就是各自独立的页面（设置页点哪个模型进哪个）。
//
//  行按「用途」聚合，而不是一文件一行：MoE 有 43 个文件（experts 就占 41 个），
//  每个都列出来既看不懂也没必要。
//

import Foundation
import UIKit
import SnapKit
import llama

@objc public class MBV47ModelDetailViewController: UIViewController, UIGestureRecognizerDelegate {

    private let variant: MBV47Variant
    private var mtmdWrapperExample: MTMDWrapperExample?

    private var downloadManager: MBV47ModelDownloadManager {
        switch variant {
        case .moe:  return .moe
        case .oneB: return .oneB
        case .minicpm5MoE(let p): return .minicpm5(p)
        }
    }

    /// 页面上的一行 = 一组文件（主模型 / 视觉塔 / 专家分片）
    private struct Row {
        let title: String
        let files: [ModelDownloadFile]
        var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    }

    private var rows: [Row] = []
    private var dataArray = [MBSettingsModel]()
    /// 上一次整表刷新的时间，用于节流进度回调。
    private var lastRowRefresh = Date.distantPast

    lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .grouped)
        tv.register(MBSettingsTableViewCell.self, forCellReuseIdentifier: "MBSettingsTableViewCell")
        tv.estimatedRowHeight = 48
        tv.separatorStyle = .none
        tv.dataSource = self
        tv.delegate = self
        return tv
    }()

    lazy var useModelButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.mb_color(with: "#007AFF")
        button.layer.cornerRadius = 8
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: #selector(useModelButtonTapped), for: .touchUpInside)
        return button
    }()

    // MARK: - init

    /// `MTMDWrapperExample` 是纯 Swift 类型，不能标 @objc。
    public init(moeWith wrapper: MTMDWrapperExample) {
        self.variant = .moe
        self.mtmdWrapperExample = wrapper
        super.init(nibName: nil, bundle: nil)
    }

    public init(oneBWith wrapper: MTMDWrapperExample) {
        self.variant = .oneB
        self.mtmdWrapperExample = wrapper
        super.init(nibName: nil, bundle: nil)
    }

    /// MiniCPM5-15B-A2.5B 的一个精度：主模型 + 专家预测器。预测器可选：只有主模型也能用。
    init(minicpm5MoEWith wrapper: MTMDWrapperExample, precision: MiniCPM5_15B_A2_5BConst.Precision) {
        self.variant = .minicpm5MoE(precision)
        self.mtmdWrapperExample = wrapper
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - life cycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        buildRows()
        setupSubViews()
        setupDownloadManager()
        setupDownloadManagerCallbacks()
        loadTableViewData()

        UIApplication.shared.isIdleTimerDisabled = true
        self.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        self.navigationController?.interactivePopGestureRecognizer?.delegate = self

        NotificationCenter.default.addObserver(self, selector: #selector(applyLanguage),
                                               name: .languageDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        (self.navigationController?.viewControllers.count ?? 0) > 1
    }

    @objc private func applyLanguage() {
        if let rightBtn = navigationItem.rightBarButtonItem {
            rightBtn.accessibilityLabel = L.ModelDetail.redownloadA11yLabel.loc
            rightBtn.accessibilityHint = L.ModelDetail.redownloadA11yHint.loc
        }
        loadTableViewData()
    }

    // MARK: - 行划分

    private func buildRows() {
        let files = variant.files
        // 目录里的相对路径带 "/" 的是 experts 分片及其 manifest，其余是顶层文件。
        let nested = files.filter { $0.localName.contains("/") }
        let flat = files.filter { !$0.localName.contains("/") }

        var r: [Row] = []
        switch variant {
        case .moe:
            if let model = flat.first(where: { $0.localName.hasSuffix(".gguf") }) {
                r.append(Row(title: L.ModelDetail.v47RowMainModel.loc, files: [model]))
            }
            if let mmproj = flat.first(where: { $0.localName.contains("mmproj") }) {
                r.append(Row(title: L.ModelDetail.v47RowVisionTower.loc, files: [mmproj]))
            }
            if !nested.isEmpty {
                r.append(Row(title: L.ModelDetail.v47RowExperts.loc, files: nested))
            }
        case .oneB:
            if let model = flat.first(where: { $0.localName.hasSuffix(".gguf") }) {
                r.append(Row(title: L.ModelDetail.v47RowMainModel.loc, files: [model]))
            }
            if let mmproj = flat.first(where: { $0.localName.contains("mmproj") }) {
                r.append(Row(title: L.ModelDetail.v47RowVisionTower.loc, files: [mmproj]))
            }
        case .minicpm5MoE:
            // downloadFiles 的顺序：[主模型, 预测器]
            if let model = files.first {
                r.append(Row(title: L.ModelDetail.v47RowMainModel.loc, files: [model]))
            }
            if files.count > 1 {
                r.append(Row(title: L.ModelDetail.minicpm5RowPredictor.loc, files: [files[1]]))
            }
        }
        rows = r
    }

    // MARK: - UI

    private func setupSubViews() {
        self.title = variant.displayedName
        self.view.backgroundColor = UIColor.mb_color(with: "#F9FAFC")

        setupNavView()

        tableView.sectionHeaderTopPadding = 0
        tableView.backgroundColor = UIColor.mb_color(with: "#F6F6F6")
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)

        view.addSubview(tableView)
        view.addSubview(useModelButton)

        tableView.snp.makeConstraints { make in
            make.top.equalTo(self.view.safeAreaLayoutGuide.snp.top)
            make.left.right.equalTo(self.view)
            make.bottom.equalTo(useModelButton.snp.top).offset(-20)
        }
        useModelButton.snp.makeConstraints { make in
            make.left.equalTo(self.view).offset(20)
            make.right.equalTo(self.view).offset(-20)
            make.bottom.equalTo(self.view.safeAreaLayoutGuide.snp.bottom).offset(-20)
            make.height.equalTo(50)
        }
    }

    private func setupNavView() {
        let img = UIImage(systemName: "chevron.left")
        let leftNavIcon = UIBarButtonItem(image: img, style: .plain,
                                          target: self, action: #selector(handleLeftNavIcon))
        leftNavIcon.tintColor = UIColor.mbIconTint
        self.navigationItem.leftBarButtonItem = leftNavIcon

        let refreshImg = UIImage(systemName: "arrow.clockwise")
        let rightBtn = UIBarButtonItem(image: refreshImg, style: .plain,
                                       target: self, action: #selector(handleRightNavButton))
        rightBtn.tintColor = UIColor.mbIconTint
        rightBtn.accessibilityLabel = L.ModelDetail.redownloadA11yLabel.loc
        rightBtn.accessibilityHint = L.ModelDetail.redownloadA11yHint.loc
        self.navigationItem.rightBarButtonItem = rightBtn

        self.navigationController?.setNavigationBackgroundColor(
            UIColor.mb_color(with: "#F9FAFC") ?? .white)
    }

    @objc private func handleLeftNavIcon() {
        self.navigationController?.popViewController(animated: true)
    }

    @objc private func handleRightNavButton() {
        guard downloadManager.hasAnyDownloadActive() == false else { return }
        let alert = UIAlertController(title: L.ModelDetail.redownloadTitle.loc,
                                      message: L.ModelDetail.redownloadMessage.loc,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L.Common.cancel.loc, style: .cancel))
        alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            let hud = MBHUD.showAdded(to: self.view, animated: true)
            hud.label.text = L.ModelDetail.redownloadHudCleaning.loc
            self.downloadManager.cancelAllDownloads()
            self.downloadManager.deleteAllDownloadedFiles()
            hud.hide(animated: true)
            self.loadTableViewData()
        })
        present(alert, animated: true)
    }

    // MARK: - 主按钮

    private enum MainButtonState { case needsDownload, downloading, ready }

    private func currentButtonState() -> MainButtonState {
        // 不要在这里调 reconcileStatusFromDisk()：那是 UI 查询，不该改下载状态。
        // （早先它会把 .failed 抹成 .notStarted，配合 pump() 形成无限重试。）
        if downloadManager.allFilesDownloaded() { return .ready }
        // 预测器可选：主模型在（下载完或 USB 放入）就能用，缺的预测器可以在行上单独补下。
        if case .minicpm5MoE(let p) = variant, !downloadManager.hasAnyDownloadActive(),
           MiniCPM5_15B_A2_5BConst.resolveArtifacts(precision: p) != nil {
            return .ready
        }
        if downloadManager.hasAnyDownloadActive() { return .downloading }
        return .needsDownload
    }

    @objc private func useModelButtonTapped() {
        switch currentButtonState() {
        case .needsDownload:
            downloadManager.downloadAll()
            updateUseModelButtonState()
        case .downloading:
            break
        case .ready:
            setAsCurrentModel()
        }
    }

    private func updateUseModelButtonState() {
        switch currentButtonState() {
        case .needsDownload:
            useModelButton.isEnabled = true
            useModelButton.setTitle(downloadTitle(), for: .normal)
            useModelButton.backgroundColor = UIColor.mb_color(with: "#007AFF")
            useModelButton.setTitleColor(.white, for: .normal)
        case .downloading:
            useModelButton.isEnabled = false
            let percent = Int(downloadManager.overallProgress() * 100)
            useModelButton.setTitle(String(format: L.ModelDetail.mainButtonDownloadingFormat.loc, percent),
                                    for: .normal)
            useModelButton.backgroundColor = UIColor.mb_color(with: "#CCCCCC")
            useModelButton.setTitleColor(.darkGray, for: .normal)
        case .ready:
            useModelButton.isEnabled = true
            useModelButton.setTitle(L.ModelDetail.mainButtonUseThis.loc, for: .normal)
            useModelButton.backgroundColor = UIColor.mb_color(with: "#007AFF")
            useModelButton.setTitleColor(.white, for: .normal)
        }
    }

    private func downloadTitle() -> String {
        switch variant {
        case .moe:  return L.ModelDetail.mainButtonOneTapDownloadV47Moe.loc
        case .oneB: return L.ModelDetail.mainButtonOneTapDownloadV471B.loc
        case .minicpm5MoE:
            let total = variant.files.reduce(Int64(0)) { $0 + $1.bytes }
            return String(format: L.ModelDetail.mainButtonOneTapDownloadMiniCPM5MoE.loc,
                          ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
        }
    }

    private func setAsCurrentModel() {
        if case .minicpm5MoE(let p) = variant {
            // 各精度是同一个模型类型，靠精度区分加载哪个文件。
            MiniCPM5_15B_A2_5BConst.setSelectedPrecision(p)
        }
        UserDefaults.standard.setValue(variant.userDefaultsKey, forKey: "current_selected_model")
        mtmdWrapperExample?.currentUsingModelType = variant.modelType
        NotificationCenter.default.post(name: .mbModelSelectionChanged, object: nil)

        let hud = MBHUD.showAdded(to: self.view, animated: true)
        hud.mode = .text
        hud.label.text = String(format: L.ModelDetail.toastSetAsCurrentFormat.loc, variant.displayedName)
        hud.hide(animated: true, afterDelay: 2.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.navigationController?.popViewController(animated: true)
        }
    }

    // MARK: - 下载管理器

    private func setupDownloadManager() {
        guard let wrapper = mtmdWrapperExample else {
            let alert = UIAlertController(title: L.Common.error.loc,
                                          message: L.ModelDetail.alertNoWrapper.loc,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .default, handler: { _ in
                self.navigationController?.popViewController(animated: true)
            }))
            self.present(alert, animated: true, completion: nil)
            return
        }
        MBV47WrapperHolder.shared = wrapper
        downloadManager.setupDownloadManager(with: wrapper)
    }

    private func setupDownloadManagerCallbacks() {
        downloadManager.detailedProgressHandler = { [weak self] _ in
            // 节流：进度回调很密（每 token/每块），整表 reload 会把 UI 打爆。
            // 50ms 一次对人眼已经连续，和下载器内部的 flush 节奏一致。
            DispatchQueue.main.async {
                guard let self = self else { return }
                let now = Date()
                if now.timeIntervalSince(self.lastRowRefresh) < 0.05 { return }
                self.lastRowRefresh = now
                self.refreshVisibleRows()
            }
        }
        downloadManager.completionHandler = { [weak self] _, success in
            DispatchQueue.main.async {
                self?.refreshVisibleRows()
                if !success {
                    let hud = MBHUD.showAdded(to: self?.view ?? UIView(), animated: true)
                    hud.mode = .text
                    hud.label.text = L.Download.statusFailed.loc
                    hud.hide(animated: true, afterDelay: 2.0)
                }
            }
        }
    }

    private func refreshVisibleRows() {
        loadTableViewData()
        updateUseModelButtonState()
    }

    // MARK: - 数据

    private func loadTableViewData() {
        dataArray.removeAll()
        for row in rows {
            let model = MBSettingsModel()
            model.title = row.title
            model.icon = UIImage(systemName: "cpu")
            model.shouldShowStatusText = true
            model.statusString = statusText(for: row)
            model.detailText = ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)
            dataArray.append(model)
        }
        tableView.reloadData()
        updateUseModelButtonState()
    }

    private func statusText(for row: Row) -> String {
        let done = row.files.filter { downloadManager.isFileDownloaded($0) }.count
        if done == row.files.count { return L.Download.statusDownloaded.loc }
        let active = row.files.contains { downloadManager.fileStatus($0) == "failed" }
        if active {
            // 预测器是可选文件：失败不影响使用，提示可以点这一行重试。
            if case .minicpm5MoE = variant, row.title == L.ModelDetail.minicpm5RowPredictor.loc {
                return L.ModelDetail.minicpm5PredictorFailedTapToRetry.loc
            }
            return L.Download.statusFailed.loc
        }
        if done == 0 {
            if case .minicpm5MoE = variant, row.title == L.ModelDetail.minicpm5RowPredictor.loc,
               !downloadManager.hasAnyDownloadActive() {
                return L.ModelDetail.minicpm5PredictorTapToDownload.loc
            }
            return L.Download.statusNotDownloaded.loc
        }
        return String(format: "%@ %d/%d", L.Download.statusDownloading.loc, done, row.files.count)
    }
}

// MARK: - UITableViewDataSource / Delegate
extension MBV47ModelDetailViewController: UITableViewDataSource, UITableViewDelegate {
    public func numberOfSections(in tableView: UITableView) -> Int { 1 }
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        dataArray.count
    }
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 48 }
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MBSettingsTableViewCell",
                                                 for: indexPath) as! MBSettingsTableViewCell
        cell.configure(with: dataArray[indexPath.row])
        return cell
    }
    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 0 }
    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? { nil }
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // MiniCPM5：主模型已在、只缺预测器时，主按钮是「使用此模型」，点预测器这一行单独补下。
        // downloadAll 只下还没落盘的文件。
        if case .minicpm5MoE = variant, indexPath.row > 0, indexPath.row < rows.count,
           !rows[indexPath.row].files.allSatisfy({ downloadManager.isFileDownloaded($0) }),
           !downloadManager.hasAnyDownloadActive() {
            downloadManager.downloadAll()
            refreshVisibleRows()
        }
    }
}
