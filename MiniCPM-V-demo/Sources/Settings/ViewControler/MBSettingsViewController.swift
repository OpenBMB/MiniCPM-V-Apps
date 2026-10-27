//
//  MBSettingsViewController.swift
//  MiniCPM-V-demo
//
//  Created by Assistant on 2024/12/19.
//

import Foundation
import UIKit
import SnapKit
import llama

/// 新设置页面 VC
@objc public class MBSettingsViewController: UIViewController, UIGestureRecognizerDelegate {
    
    /// 这是由外部（home）传入的引用
    var mtmdWrapperExample: MTMDWrapperExample?
    
    /// 更新选中的模型
    var updateUsingModeltype: ((CurrentUsingModelTypeV2) -> Void)?
    
    /// 一个列表
    lazy var tableView: UITableView = {
        // grouped has section title
        let tv = UITableView(frame: .zero, style: .grouped)
        tv.register(MBSettingsTableViewCell.self, forCellReuseIdentifier: "MBSettingsTableViewCell")
        tv.estimatedRowHeight = 48
        tv.separatorStyle = .none
        tv.separatorColor = .clear
        tv.dataSource = self
        tv.delegate = self
        return tv
    }()
    
    /// 列表对应的数据源 [[]]
    var dataArray = [[MBSettingsModel]]()
    
    // MARK: - view life cycle
    
    init(with wrapper: MTMDWrapperExample) {
        self.mtmdWrapperExample = wrapper
        super.init(nibName: nil, bundle: nil)
    }
    
    // 这是指定的初始化方法
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        // step 1, create ui
        setupSubViews()
        
        // step 2, 配置 UI 数据
        loadTableViewData()
        
        // 禁止熄屏
        UIApplication.shared.isIdleTimerDisabled = true
        
        // Enable the interactive pop gesture recognizer
        self.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        self.navigationController?.interactivePopGestureRecognizer?.delegate = self

        // 监听运行时语言切换：用户在本页选了 English 之后，此通知会让
        // 整页重建（标题 + 4 个 section header + 全部 cell title / detailText）
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applyLanguage),
                                               name: .languageDidChange,
                                               object: nil)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showCacheWindowRevertNoticeIfNeeded()
    }

    /// 若上次启动因缓存设得过大而回退，这里告知用户 —— 回退是静默发生的。
    private func showCacheWindowRevertNoticeIfNeeded() {
        guard let attempted = MiniCPMV47Const.consumeCacheWindowRevertNotice() else { return }
        let alert = UIAlertController(
            title: L.Settings.cacheWindowRevertedTitle.loc,
            message: String(format: L.Settings.cacheWindowRevertedBody.loc, "\(attempted)"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .default))
        present(alert, animated: true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 当 LocalizationManager.shared.currentLanguage 变化时调用：刷新本页所有可见文案。
    @objc private func applyLanguage() {
        self.title = L.Settings.title.loc
        // loadTableViewData 内部 removeAll + 重新组装 4 个 section + reloadData
        loadTableViewData()
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // 刷新模型管理section，以反映最新的选中状态
        refreshModelManagementSection()
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // 允许熄屏
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return self.navigationController?.viewControllers.count ?? 0 > 1
    }
    
    // MARK: - 创建子视图
    
    func setupSubViews() {
        self.title = L.Settings.title.loc
        
        let titleDict: [NSAttributedString.Key : Any] = [NSAttributedString.Key.foregroundColor: UIColor.label]
        self.navigationController?.navigationBar.titleTextAttributes = titleDict

        self.view.backgroundColor = UIColor.mb_color(with: "#F9FAFC")

        setupNavView()
        
        tableView.sectionHeaderTopPadding = 0

        tableView.backgroundColor = UIColor.mb_color(with: "#F6F6F6")

        tableView.contentInsetAdjustmentBehavior = .never
        tableView.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.top.equalTo(self.view.safeAreaLayoutGuide.snp.top)
            make.left.right.bottom.equalTo(self.view)
        }
    }
    
    func setupNavView() {
        
        let img = UIImage(systemName: "chevron.left")
        let leftNavIcon = UIBarButtonItem(image: img,
                                          style: .plain,
                                          target: self,
                                          action: #selector(handleLeftNavIcon))
        leftNavIcon.tintColor = UIColor.mbIconTint
        self.navigationItem.leftBarButtonItem = leftNavIcon
        
        // 白色顶导
        self.navigationController?.setNavigationBackgroundColor(UIColor.mb_color(with: "#F9FAFC") ?? .white)
    }

    // MARK: - 顶导返回按钮 点击 事件
    
    @objc public func handleLeftNavIcon() {
        self.navigationController?.popViewController(animated: true)
    }
    
    public override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        self.tableView.reloadData()
    }
}

// MARK: - UITableViewDataSource
extension MBSettingsViewController: UITableViewDataSource {
    
    public func numberOfSections(in tableView: UITableView) -> Int {
        return dataArray.count
    }
    
    // 返回表格中的行数
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return dataArray[section].count
    }
    
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 48
    }
    
    // 设置每个单元格的内容
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        let cell = tableView.dequeueReusableCell(withIdentifier: "MBSettingsTableViewCell", for: indexPath) as! MBSettingsTableViewCell
        
        let model = dataArray[indexPath.section][indexPath.row]
        cell.configure(with: model)
        
        return cell
    }
    
    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if dataArray[section].isEmpty { return 0 }
        return 40
    }
    
    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let headerView = UIView()
        headerView.backgroundColor = UIColor.mb_color(with: "#F6F6F6")
        
        let titleLabel = UILabel()
        titleLabel.textColor = UIColor.mbPrimaryText
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textAlignment = .left
        
        switch section {
        case 0:
            titleLabel.text = L.Settings.sectionMultimodal.loc
        case 1:
            titleLabel.text = L.Settings.sectionLanguageModel.loc
        case 2:
            titleLabel.text = L.Settings.sectionTts.loc
        case 3:
            titleLabel.text = L.Settings.sectionOcr.loc
        case 4:
            titleLabel.text = L.Settings.sectionFeature.loc
        case 5:
            titleLabel.text = L.Settings.sectionOther.loc
        default:
            titleLabel.text = ""
        }
        
        headerView.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.left.equalTo(16)
            make.centerY.equalTo(headerView)
            make.right.equalTo(-16)
        }
        
        return headerView
    }
}

// MARK: - UITableViewDelegate
extension MBSettingsViewController: UITableViewDelegate {
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let model = dataArray[indexPath.section][indexPath.row]
        if model.isSwitchEnabled {
            // 开关型 cell：整行点击给一条说明（DSpark 开关不在当前会话内生效）。
            if model.title == L.Settings.rowDspark.loc {
                let alert = UIAlertController(title: L.Settings.rowDspark.loc,
                                              message: L.Settings.dsparkHint.loc,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L.Common.gotIt.loc, style: .default))
                present(alert, animated: true)
            } else if model.title == L.Settings.rowLiveTps.loc {
                let alert = UIAlertController(title: L.Settings.rowLiveTps.loc,
                                              message: L.Settings.liveTpsHint.loc,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L.Common.gotIt.loc, style: .default))
                present(alert, animated: true)
            } else if model.title == L.Settings.rowOcrLiveTps.loc {
                let alert = UIAlertController(title: L.Settings.rowOcrLiveTps.loc,
                                              message: L.Settings.ocrLiveTpsHint.loc,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L.Common.gotIt.loc, style: .default))
                present(alert, animated: true)
            }
            return
        }

        switch indexPath.section {
        case 0, 1, 2, 3: // 多模态 / 语言 / TTS / OCR 模型
            handleModelSelection(model: model, at: indexPath)
        case 4: // 功能设置
            handleFeatureSelection(model: model, at: indexPath)
        case 5: // 其他设置
            handleOtherSettings(model: model, at: indexPath)
        default:
            break
        }
    }
    
    private func handleModelSelection(model: MBSettingsModel, at indexPath: IndexPath) {
        guard let mtmdWrapperExample else {
            // 如果没有传入 mtmdWrapperExample，创建一个新的实例
            let alert = UIAlertController(title: L.Common.error.loc,
                                          message: L.Settings.alertNoWrapper.loc,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .default, handler: { _ in
                self.navigationController?.popViewController(animated: true)
            }))
            self.present(alert, animated: true, completion: nil)
            return
        }
        
        if model.status == "disabled" {
            let totalRAM = ProcessInfo.processInfo.physicalMemory
            let ramGB = String(format: "%.0f", Double(totalRAM) / 1024 / 1024 / 1024)
            let modelName = model.title ?? L.Settings.alertModelFallback.loc
            let alertMessage = String(format: L.Settings.alertDeviceUnsupportedMessageFormat.loc, modelName, ramGB)
            let alert = UIAlertController(title: L.Settings.alertDeviceUnsupportedTitle.loc,
                                          message: alertMessage,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L.Common.gotIt.loc, style: .default))
            present(alert, animated: true)
            return
        }
        
        if let title = model.title {
            if title == "MiniCPM-V 2.6 8B" {
                let detailVC = MBV26ModelDetailViewController(with: mtmdWrapperExample)
                self.navigationController?.pushViewController(detailVC, animated: true)
            } else if title == "MiniCPM-V 4.0 4B" {
                let detailVC = MBV4ModelDetailViewController(with: mtmdWrapperExample)
                self.navigationController?.pushViewController(detailVC, animated: true)
            } else if title == "MiniCPM-V 4.6" {
                let detailVC = MBV46ModelDetailViewController(with: mtmdWrapperExample)
                self.navigationController?.pushViewController(detailVC, animated: true)
            } else if title == "MiniCPM5-1B" {
                let detailVC = MBV5ModelDetailViewController(with: mtmdWrapperExample)
                self.navigationController?.pushViewController(detailVC, animated: true)
            } else if title == "MiniCPM5-2B" {
                let detailVC = MBV526ModelDetailViewController(with: mtmdWrapperExample)
                self.navigationController?.pushViewController(detailVC, animated: true)
            } else if title == MiniCPMModelConst.voxcpm2_DisplayedName {
                let detailVC = MBVoxcpm2ModelDetailViewController(with: mtmdWrapperExample)
                self.navigationController?.pushViewController(detailVC, animated: true)
            } else if title == MiniCPMModelConst.ocr_DisplayedName {
                let detailVC = MBOcrModelDetailViewController(with: mtmdWrapperExample)
                self.navigationController?.pushViewController(detailVC, animated: true)
            } else if title == MiniCPMV47Const.displayedName {
                // 4.7 MoE：进下载/详情页（模型槽位等专家设置移到「功能设置」，且仅在用 MoE 时显示）
                let vc = MBV47ModelDetailViewController(moeWith: mtmdWrapperExample)
                self.navigationController?.pushViewController(vc, animated: true)
            } else if title == MiniCPMV47_1BConst.displayedName {
                let vc = MBV47ModelDetailViewController(oneBWith: mtmdWrapperExample)
                self.navigationController?.pushViewController(vc, animated: true)
            }
        }
    }

    /// 夜间模式三档选择。
    ///
    /// 选完立即调用 `MBTheme.apply()` 切窗口外观 —— UIKit 会重解析所有动态色并触发
    /// `traitCollectionDidChange`，所以不需要重建页面。
    private func showAppearancePicker() {
        let sheet = UIAlertController(title: L.Settings.appearanceTitle.loc,
                                      message: nil,
                                      preferredStyle: .actionSheet)
        for option in MBAppearance.allCases {
            let isCurrent = (option == MBTheme.current)
            let title = option.displayNameKey + (isCurrent ? "  ✓" : "")
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                MBTheme.current = option
                MBTheme.apply()
                DispatchQueue.main.async { self?.loadTableViewData() }
            })
        }
        sheet.addAction(UIAlertAction(title: L.Common.cancel.loc, style: .cancel))

        // iPad 上 actionSheet 必须挂 popover，否则直接崩。
        if let pop = sheet.popoverPresentationController {
            let row = indexPathForAppearanceRow()
            pop.sourceView = self.tableView
            pop.sourceRect = row.map { self.tableView.rectForRow(at: $0) }
                ?? CGRect(x: self.tableView.bounds.midX, y: self.tableView.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func indexPathForAppearanceRow() -> IndexPath? {
        for (section, rows) in dataArray.enumerated() {
            if let row = rows.firstIndex(where: { $0.title == L.Settings.rowAppearance.loc }) {
                return IndexPath(row: row, section: section)
            }
        }
        return nil
    }

    /// 4.7 的「专家槽位（slot bank）」设置行：点开弹滑条。
    ///
    /// 原先它挂在「点击 MoE 模型」的流程里，现在模型点击直接进下载/详情页，
    /// 这个旋钮就挪到「功能设置」里，和预读 / 缓存 / 预热放一起，且**仅在用 MoE 时显示**。
    private func presentV47SlotBankPicker() {
        let box = MBSlotBankSliderBox(frame: CGRect(x: 0, y: 0, width: 270, height: 72))
        let host = UIViewController()
        host.view = box
        host.preferredContentSize = CGSize(width: 270, height: 72)

        let alert = UIAlertController(title: L.Settings.slotBankTitle.loc,
                                      message: L.Settings.slotBankMessage.loc,
                                      preferredStyle: .alert)
        alert.setValue(host, forKey: "contentViewController")
        alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .default) { [weak self] _ in
            MiniCPMV47Const.setSlotBank(box.bank)
            self?.loadTableViewData()
        })
        alert.addAction(UIAlertAction(title: L.Common.cancel.loc, style: .cancel))
        present(alert, animated: true)
    }

    private func handleFeatureSelection(model: MBSettingsModel, at indexPath: IndexPath) {
        // 处理功能设置逻辑。
        // 注意：用 .loc 后的字符串比较，意味着用户在英文环境下点 "Language"
        // cell 也能命中（loc 返回 "Language"），中文环境下点"语言"也能命中。
        guard let title = model.title else { return }
        if title == L.Settings.rowLanguage.loc {
            showLanguagePicker()
        } else if title == L.Settings.rowLookaheadPrefetchDepth.loc {
            presentLookaheadPrefetchDepthPicker()
        } else if title == L.Settings.rowCacheWindow.loc {
            presentCacheWindowPicker()
        } else if title == L.Settings.rowPrewarm.loc {
            presentPrewarmPicker()
        } else if title == L.Settings.rowSlotBank.loc {
            presentV47SlotBankPicker()
        } else if title == L.Settings.rowAppearance.loc {
            showAppearancePicker()
        } else if title == L.Realtime.title.loc {
            showRealtimeUnderstandingPage()
        }
    }
    
    private func handleOtherSettings(model: MBSettingsModel, at indexPath: IndexPath) {
        // 处理其他设置逻辑
        if let title = model.title, title == L.Settings.rowAbout.loc {
            // 关于我们的处理逻辑
            showAboutUs()
        }
    }

    private func presentLookaheadPrefetchDepthPicker() {
        let box = MBLookaheadPrefetchDepthSliderBox(frame: CGRect(x: 0, y: 0, width: 270, height: 88))
        let host = UIViewController()
        host.view = box
        host.preferredContentSize = CGSize(width: 270, height: 88)

        let alert = UIAlertController(
            title: L.Settings.lookaheadPrefetchDepthTitle.loc,
            message: L.Settings.lookaheadPrefetchDepthMessage.loc,
            preferredStyle: .alert
        )
        alert.setValue(host, forKey: "contentViewController")
        alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .default) { [weak self] _ in
            self?.mtmdWrapperExample?.setMoeLookaheadPrefetchDepth(box.depth)
            self?.loadTableViewData()
        })
        alert.addAction(UIAlertAction(title: L.Common.cancel.loc, style: .cancel))
        present(alert, animated: true)
    }

    /// 缓存槽数 c 选择器。改完需重载模型才生效。
    private func presentCacheWindowPicker() {
        let box = MBCacheWindowSliderBox(frame: CGRect(x: 0, y: 0, width: 270, height: 88))
        let host = UIViewController()
        host.view = box
        host.preferredContentSize = CGSize(width: 270, height: 88)

        let alert = UIAlertController(
            title: L.Settings.cacheWindowTitle.loc,
            message: L.Settings.cacheWindowMessage.loc,
            preferredStyle: .alert
        )
        alert.setValue(host, forKey: "contentViewController")
        alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .default) { [weak self] _ in
            MiniCPMV47Const.setCacheWindowC(box.c)
            self?.loadTableViewData()
        })
        alert.addAction(UIAlertAction(title: L.Common.cancel.loc, style: .cancel))
        present(alert, animated: true)
    }

    /// 缓存预热档位选择器（关 / 8 / 16 / 32 / 48 / 64）。改完需重载模型才生效。
    /// 用 ActionSheet 而不是滑条：档位是离散的，且只有 5 档。
    private func presentPrewarmPicker() {
        let alert = UIAlertController(title: L.Settings.prewarmTitle.loc,
                                      message: L.Settings.prewarmMessage.loc,
                                      preferredStyle: .actionSheet)
        let current = MiniCPMV47Const.prewarmLevel()

        let off = UIAlertAction(title: current <= 0 ? "\(L.Settings.prewarmOff.loc)  ✓"
                                                    : L.Settings.prewarmOff.loc,
                                style: .default) { [weak self] _ in
            MiniCPMV47Const.setPrewarmLevel(0)
            self?.loadTableViewData()
        }
        alert.addAction(off)

        for level in MiniCPMV47Const.prewarmLevelsForDevice() {
            let title = level == current ? "\(level)  ✓" : "\(level)"
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                MiniCPMV47Const.setPrewarmLevel(level)
                self?.loadTableViewData()
            })
        }
        alert.addAction(UIAlertAction(title: L.Common.cancel.loc, style: .cancel))

        // iPad action sheet 必须 anchor 到 sourceView 否则 crash（同语言选择器）。
        if let pop = alert.popoverPresentationController {
            pop.sourceView = self.view
            if let idx = tableView.indexPathForSelectedRow,
               let cell = tableView.cellForRow(at: idx) {
                pop.sourceView = cell
                pop.sourceRect = cell.bounds
            } else {
                pop.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
        }
        present(alert, animated: true)
    }

    /// 弹 ActionSheet 让用户在中文 / English 之间二选一。    /// 选好后调 LocalizationManager.setLanguage()，会通过通知触发本页 + 已打开
    /// 的其它 VC 全部 reload，无需重启 app。
    private func showLanguagePicker() {
        let alert = UIAlertController(title: L.LanguagePicker.title.loc,
                                      message: L.LanguagePicker.message.loc,
                                      preferredStyle: .actionSheet)

        for lang in AppLanguage.allCases {
            let isCurrent = (LocalizationManager.shared.currentLanguage == lang)
            // 给当前选中那行末尾加 ✓ 提示，避免用户重复点同一项造成困惑。
            let title = isCurrent ? "\(lang.displayName)  ✓" : lang.displayName
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                LocalizationManager.shared.setLanguage(lang)
                // 立刻刷新本页：监听 .languageDidChange 已经会做这件事，
                // 这里再调一次保证用户在切换瞬间就看到反馈，不依赖通知派发顺序。
                self?.applyLanguage()
            })
        }
        alert.addAction(UIAlertAction(title: L.Common.cancel.loc, style: .cancel))

        // iPad action sheet 必须 anchor 到 sourceView 否则 crash。anchor 到
        // tableView 的当前选中行，没选中行则 fallback 到 view 中央。
        if let pop = alert.popoverPresentationController {
            pop.sourceView = self.view
            if let idx = tableView.indexPathForSelectedRow,
               let cell = tableView.cellForRow(at: idx) {
                pop.sourceView = cell
                pop.sourceRect = cell.bounds
            } else {
                pop.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
        }
        present(alert, animated: true)
    }

    private func showRealtimeUnderstandingPage() {
        // 显示实时理解设置页面
        let realtimeVC = MBRealtimeUnderstandingViewController()
        self.navigationController?.pushViewController(realtimeVC, animated: true)
    }
    
    private func showAboutUs() {
        // 显示关于我们的页面
        let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ??
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "MiniCPM Demo App"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let appBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        let versionInfo = "\(appVersion) (\(appBuildNumber))"
        let message = "\(appName)\n\(L.Settings.aboutVersionLabel.loc) \(versionInfo)"
        let alert = UIAlertController(title: L.Common.about.loc, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .default))
        present(alert, animated: true)
    }
    
    private func showInfoTips(_ message: String) {
        let hud = MBHUD.showAdded(to: self.view, animated: true)
        hud.mode = .text
        hud.label.text = message
        hud.hide(animated: true, afterDelay: 1.5)
    }
}

// MARK: - 数据配置
extension MBSettingsViewController {
    
    /// 配置列表数据用于展示 cell
    public func loadTableViewData() {
        dataArray.removeAll()
        setupMultimodalModelSection()
        setupLanguageModelSection()
        setupTtsModelSection()
        setupOcrModelSection()
        setupFeatureSettingsSection()
        setupOtherSettingsSection()
        
        tableView.reloadData()
    }
    
    /// Section 0: 多模态模型 (VLM)
    private func setupMultimodalModelSection() {
        var section = [MBSettingsModel]()
        
        let currentSelectedModel = UserDefaults.standard.string(forKey: "current_selected_model")
        
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let deviceSupports8B = totalRAM >= 12 * 1024 * 1024 * 1024

        // MiniCPM-V 2.6 8B
        let model1 = MBSettingsModel()
        model1.title = "MiniCPM-V 2.6 8B"
        model1.icon = UIImage(systemName: "cpu")
        model1.accessoryIcon = UIImage(named: "setting_accessory_icon")
        model1.selectedIcon = UIImage(systemName: "checkmark.circle.fill")
        
        if !deviceSupports8B {
            model1.status = "disabled"
            let ramGB = String(format: "%.0f", Double(totalRAM) / 1024 / 1024 / 1024)
            model1.statusString = String(format: L.Settings.statusInsufficientRAMFormat.loc, ramGB)
        } else if currentSelectedModel == "V26MultiModel" {
            model1.status = "selected"
            model1.statusString = L.Settings.statusInUse.loc
        } else {
            model1.status = "none"
        }
        
        section.append(model1)
        
        // MiniCPM-V 4.0 4B
        let model2 = MBSettingsModel()
        model2.title = "MiniCPM-V 4.0 4B"
        model2.icon = UIImage(systemName: "cpu")
        model2.accessoryIcon = UIImage(named: "setting_accessory_icon")
        model2.selectedIcon = UIImage(systemName: "checkmark.circle.fill")
        
        if currentSelectedModel == "V4MultiModel" {
            model2.status = "selected"
            model2.statusString = L.Settings.statusInUse.loc
        } else {
            model2.status = "none"
        }
        
        section.append(model2)
        
        // MiniCPM-V 4.6
        let model3 = MBSettingsModel()
        model3.title = "MiniCPM-V 4.6"
        model3.icon = UIImage(systemName: "cpu")
        model3.accessoryIcon = UIImage(named: "setting_accessory_icon")
        model3.selectedIcon = UIImage(systemName: "checkmark.circle.fill")
        
        if currentSelectedModel == "V46MultiModel" {
            model3.status = "selected"
            model3.statusString = L.Settings.statusInUse.loc
        } else {
            model3.status = "none"
        }
        
        section.append(model3)

        let qwen = MBSettingsModel()
        qwen.title = MiniCPMV47Const.displayedName
        qwen.icon = UIImage(systemName: "cpu")
        qwen.accessoryIcon = UIImage(named: "setting_accessory_icon")
        qwen.selectedIcon = UIImage(systemName: "checkmark.circle.fill")
        if MiniCPMV47Const.resolveArtifacts() != nil && currentSelectedModel == MiniCPMV47Const.userDefaultsKey {
            qwen.status = "selected"
            if mtmdWrapperExample?.multiModelLoadingSuccess == true {
                qwen.statusString = L.Settings.statusInUse.loc
            } else {
                qwen.statusString = "待加载"
            }
        } else if MiniCPMV47Const.resolveArtifacts() != nil {
            qwen.status = "none"
            qwen.statusString = "已下载"
        } else {
            qwen.status = "none"
            qwen.statusString = "点此安装"
        }
        section.append(qwen)

        // MiniCPM-V 4.7 1B（dense）。权重靠本地脚本推送，App 不做下载，
        // 所以这里只反映「本地文件在不在」。
        let v47_1b = MBSettingsModel()
        v47_1b.title = MiniCPMV47_1BConst.displayedName
        v47_1b.icon = UIImage(systemName: "cpu")
        v47_1b.accessoryIcon = UIImage(named: "setting_accessory_icon")
        v47_1b.selectedIcon = UIImage(systemName: "checkmark.circle.fill")
        if MiniCPMV47_1BConst.filesExist {
            if currentSelectedModel == MiniCPMV47_1BConst.userDefaultsKey {
                v47_1b.status = "selected"
                v47_1b.statusString = mtmdWrapperExample?.multiModelLoadingSuccess == true
                    ? L.Settings.statusInUse.loc : "待加载"
            } else {
                v47_1b.status = "none"
                v47_1b.statusString = "已就位"
            }
        } else {
            v47_1b.status = "none"
            v47_1b.statusString = "点此查看如何放入文件"
        }
        section.append(v47_1b)
        
        dataArray.append(section)
    }
    
    /// Section 1: 语言模型 (LLM)
    private func setupLanguageModelSection() {
        var section = [MBSettingsModel]()
        
        let currentSelectedModel = UserDefaults.standard.string(forKey: "current_selected_model")
        
        let model = MBSettingsModel()
        model.title = "MiniCPM5-1B"
        model.icon = UIImage(systemName: "text.bubble")
        model.accessoryIcon = UIImage(named: "setting_accessory_icon")
        model.selectedIcon = UIImage(systemName: "checkmark.circle.fill")
        
        if currentSelectedModel == "V5TextModel" {
            model.status = "selected"
            model.statusString = L.Settings.statusInUse.loc
        } else {
            model.status = "none"
        }
        
        section.append(model)

        let model26 = MBSettingsModel()
        model26.title = "MiniCPM5-2B"
        model26.icon = UIImage(systemName: "text.bubble")
        model26.accessoryIcon = UIImage(named: "setting_accessory_icon")
        model26.selectedIcon = UIImage(systemName: "checkmark.circle.fill")

        if currentSelectedModel == "V526TextModel" {
            model26.status = "selected"
            model26.statusString = L.Settings.statusInUse.loc
        } else {
            model26.status = "none"
        }

        section.append(model26)
        
        dataArray.append(section)
    }

    /// Section 2: TTS 模型 (VoxCPM2)
    private func setupTtsModelSection() {
        var section = [MBSettingsModel]()

        let currentSelectedModel = UserDefaults.standard.string(forKey: "current_selected_model")

        let model = MBSettingsModel()
        model.title = MiniCPMModelConst.voxcpm2_DisplayedName
        model.icon = UIImage(systemName: "waveform.circle")
        model.accessoryIcon = UIImage(named: "setting_accessory_icon")
        model.selectedIcon = UIImage(systemName: "checkmark.circle.fill")

        if currentSelectedModel == "Voxcpm2Model" {
            model.status = "selected"
            model.statusString = L.Settings.statusInUse.loc
        } else {
            model.status = "none"
        }

        section.append(model)
        dataArray.append(section)
    }

    /// Section 3: OCR 模型 (MiniCPM-OCR 1.0)
    private func setupOcrModelSection() {
        var section = [MBSettingsModel]()

        let currentSelectedModel = UserDefaults.standard.string(forKey: "current_selected_model")

        let model = MBSettingsModel()
        model.title = MiniCPMModelConst.ocr_DisplayedName
        model.icon = UIImage(systemName: "doc.text.viewfinder")
        model.accessoryIcon = UIImage(named: "setting_accessory_icon")
        model.selectedIcon = UIImage(systemName: "checkmark.circle.fill")

        if currentSelectedModel == "OcrModel" {
            model.status = "selected"
            model.statusString = L.Settings.statusInUse.loc
        } else {
            model.status = "none"
        }

        section.append(model)
        dataArray.append(section)
    }

    /// Section 4: 功能设置
    private func setupFeatureSettingsSection() {
        var section = [MBSettingsModel]()
        
        // 实时理解设置（暂未调通，暂时隐藏）
        // let realtimeSetting = MBSettingsModel()
        // realtimeSetting.title = L.Realtime.title.loc
        // realtimeSetting.icon = UIImage(systemName: "brain.head.profile")
        // realtimeSetting.accessoryIcon = UIImage(named: "setting_accessory_icon")
        // section.append(realtimeSetting)

        // 语言切换：detailText 显示当前选中的语言，点击后弹 ActionSheet。
        // detailText 永远在 displayName 上读（"中文" / "English"），不参与
        // i18n 字典——这是有意的：用户不论在哪种 UI 语言下都能直接识别母语。
        let langModel = MBSettingsModel()
        langModel.title = L.Settings.rowLanguage.loc
        langModel.icon = UIImage(systemName: "globe")
        langModel.accessoryIcon = UIImage(named: "setting_accessory_icon")
        langModel.detailText = LocalizationManager.shared.currentLanguage.displayName
        section.append(langModel)

        // 以下都是 MoE 专属旋钮，只在当前用 35B-A3B MoE 时显示 —— 用 1B 或别的模型
        // 看到这些专家设置只会困惑。
        if isMoEModelActive {
            let lookaheadPrefetchModel = MBSettingsModel()
            lookaheadPrefetchModel.title = L.Settings.rowLookaheadPrefetchDepth.loc
            lookaheadPrefetchModel.icon = UIImage(systemName: "arrow.down.circle")
            lookaheadPrefetchModel.accessoryIcon = UIImage(named: "setting_accessory_icon")
            lookaheadPrefetchModel.detailText = {
                let n = MiniCPMV47Const.lookaheadPrefetchDepth()
                return n == 0 ? L.Settings.lookaheadPrefetchDepthOff.loc : "\(n)"
            }()
            section.append(lookaheadPrefetchModel)

            // 每层缓存槽数 c，改完需重载模型。
            let cacheWindowModel = MBSettingsModel()
            cacheWindowModel.title = L.Settings.rowCacheWindow.loc
            cacheWindowModel.icon = UIImage(systemName: "internaldrive")
            cacheWindowModel.accessoryIcon = UIImage(named: "setting_accessory_icon")
            cacheWindowModel.detailText = {
                let c = MiniCPMV47Const.cacheWindowC()
                if c <= 0 { return "关" }
                return "\(c)（\(Int(MiniCPMV47Const.cacheWindowCoverage(c) * 100))%）"
            }()
            section.append(cacheWindowModel)

            // 缓存预热档位（每层预读多少个开头常用专家）。改完需重载模型。
            let prewarmModel = MBSettingsModel()
            prewarmModel.title = L.Settings.rowPrewarm.loc
            prewarmModel.icon = UIImage(systemName: "flame")
            prewarmModel.accessoryIcon = UIImage(named: "setting_accessory_icon")
            prewarmModel.detailText = {
                let n = MiniCPMV47Const.prewarmLevel()
                return n <= 0 ? L.Settings.prewarmOff.loc : "\(n)"
            }()
            section.append(prewarmModel)

            // 专家槽位（slot bank）。原先挂在「点击 MoE 模型」的流程里，现在模型点击直接进
            // 下载/详情页，所以挪到这里和其他专家旋钮放在一起。
            let slotBankModel = MBSettingsModel()
            slotBankModel.title = L.Settings.rowSlotBank.loc
            slotBankModel.icon = UIImage(systemName: "square.grid.3x3")
            slotBankModel.accessoryIcon = UIImage(named: "setting_accessory_icon")
            slotBankModel.detailText = "\(MiniCPMV47Const.slotBank())"
            section.append(slotBankModel)
        }

        // 显示 P/D 速度：拨一下即时生效（只控制工具条上那行文字是否显示，不影响推理）。
        let showPerfSpeedModel = MBSettingsModel()
        showPerfSpeedModel.title = L.Settings.rowShowPerfSpeed.loc
        showPerfSpeedModel.icon = UIImage(systemName: "speedometer")
        showPerfSpeedModel.isSwitchEnabled = true
        showPerfSpeedModel.switchIsOn = MiniCPMV47Const.showPerfSpeedEnabled()
        showPerfSpeedModel.switchValueChanged = { [weak self] on in
            MiniCPMV47Const.setShowPerfSpeedEnabled(on)
            // 广播给主页：让它把已渲染回复上的速度文案一起刷新（否则要等下一轮生成才变）。
            NotificationCenter.default.post(name: .mbPerfSpeedVisibilityChanged, object: nil)
            DispatchQueue.main.async { self?.loadTableViewData() }
        }
        section.append(showPerfSpeedModel)

        // 实时速度：生成过程中就实时刷新 decode t/s（上面那个是**生成结束后**给最终值）。
        // 两个开关各管一段、互不干扰：都关则不显示，都开则流式期间显示实时值、完成后换成最终值。
        let liveTpsModel = MBSettingsModel()
        liveTpsModel.title = L.Settings.rowLiveTps.loc
        liveTpsModel.icon = UIImage(systemName: "speedometer")
        liveTpsModel.isSwitchEnabled = true
        liveTpsModel.switchIsOn = MiniCPMV47Const.liveTpsEnabled()
        liveTpsModel.switchValueChanged = { [weak self] on in
            MiniCPMV47Const.setLiveTpsEnabled(on)
            NotificationCenter.default.post(name: .mbPerfSpeedVisibilityChanged, object: nil)
            DispatchQueue.main.async { self?.loadTableViewData() }
        }
        section.append(liveTpsModel)

        let ocrLiveTpsModel = MBSettingsModel()
        ocrLiveTpsModel.title = L.Settings.rowOcrLiveTps.loc
        ocrLiveTpsModel.icon = UIImage(systemName: "speedometer")
        ocrLiveTpsModel.isSwitchEnabled = true
        ocrLiveTpsModel.switchIsOn = MiniCPMV47Const.ocrLiveTpsEnabled()
        ocrLiveTpsModel.switchValueChanged = { [weak self] on in
            MiniCPMV47Const.setOcrLiveTpsEnabled(on)
            NotificationCenter.default.post(name: .ocrLiveTpsChanged, object: nil)
            DispatchQueue.main.async { self?.loadTableViewData() }
        }
        section.append(ocrLiveTpsModel)

        // 夜间模式：跟随系统 / 始终开启 / 始终关闭。改完即时生效，不用重载模型。
        let appearanceModel = MBSettingsModel()
        appearanceModel.title = L.Settings.rowAppearance.loc
        appearanceModel.icon = UIImage(systemName: "moon.stars")
        appearanceModel.accessoryIcon = UIImage(named: "setting_accessory_icon")
        appearanceModel.detailText = MBTheme.current.displayNameKey
        section.append(appearanceModel)

        // 实时渲染 Markdown 开关：**当前隐藏**（暂时不暴露该入口，代码保留，恢复时解注释即可）。
        // 默认关（流式期间纯文本，整段完成后一次上样式）；打开后走增量解析边生成边上样式，无需重载模型。
        //
        // let streamingMarkdownModel = MBSettingsModel()
        // streamingMarkdownModel.title = L.Settings.rowStreamingMarkdown.loc
        // streamingMarkdownModel.icon = UIImage(systemName: "textformat")
        // streamingMarkdownModel.isSwitchEnabled = true
        // streamingMarkdownModel.switchIsOn = MiniCPMV47Const.streamingMarkdownEnabled()
        // streamingMarkdownModel.switchValueChanged = { [weak self] on in
        //     MiniCPMV47Const.setStreamingMarkdownEnabled(on)
        //     DispatchQueue.main.async { self?.loadTableViewData() }
        // }
        // section.append(streamingMarkdownModel)

        // DSpark 开关：**当前隐藏**（暂时不暴露该入口，代码保留，恢复时解注释即可）。
        // 不会立即生效 —— 投机器在模型加载时按这个值建，改完要重载模型；点开这一行会给出提示。
        //
        // let dsparkModel = MBSettingsModel()
        // dsparkModel.title = L.Settings.rowDspark.loc
        // dsparkModel.icon = UIImage(systemName: "bolt.horizontal.circle")
        // dsparkModel.isSwitchEnabled = true
        // dsparkModel.switchIsOn = MiniCPMV47Const.dsparkEnabled()
        // dsparkModel.switchValueChanged = { [weak self] on in
        //     MiniCPMV47Const.setDsparkEnabled(on)
        //     // 异步重建数据源：在当前回调里 reloadData 会把正在发 valueChanged 的
        //     // UISwitch 连同 cell 一起拆掉。这一行同时刷新上面「预读专家数」的显示值。
        //     DispatchQueue.main.async {
        //         self?.loadTableViewData()
        //         if on { self?.offerDsparkDraftDownloadIfMissing() }
        //     }
        // }
        // section.append(dsparkModel)

        dataArray.append(section)
    }

    /// 当前选中的模型是不是 4.7 的 35B-A3B MoE。
    ///
    /// 直接读 UserDefaults 而不看 `mtmdWrapperExample.currentUsingModelType`：
    /// 后者要等模型加载流程才会被赋值，设置页刚进来时可能还是 .Unknown。
    private var isMoEModelActive: Bool {
        UserDefaults.standard.string(forKey: "current_selected_model") == MiniCPMV47Const.userDefaultsKey
    }
    
    /// Section 3: 其他设置
    private func setupOtherSettingsSection() {
        var section = [MBSettingsModel]()
        
        let aboutModel = MBSettingsModel()
        aboutModel.title = L.Settings.rowAbout.loc
        aboutModel.icon = UIImage(systemName: "info.circle")
        aboutModel.accessoryIcon = UIImage(named: "setting_accessory_icon")
        
        section.append(aboutModel)
        
        dataArray.append(section)
    }
    
    /// 刷新模型相关 section
    private func refreshModelManagementSection() {
        var currentSelectedModel = UserDefaults.standard.string(forKey: "current_selected_model")
        
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let hasEnoughRAMFor8B = totalRAM >= 12 * 1024 * 1024 * 1024
        if currentSelectedModel == "V26MultiModel" && !hasEnoughRAMFor8B {
            UserDefaults.standard.removeObject(forKey: "current_selected_model")
            currentSelectedModel = nil
            mtmdWrapperExample?.currentUsingModelType = .Unknown
        }
        
        if currentSelectedModel == "V26MultiModel" {
            mtmdWrapperExample?.currentUsingModelType = .V26MultiModel
        } else if currentSelectedModel == "V4MultiModel" {
            mtmdWrapperExample?.currentUsingModelType = .V4MultiModel
        } else if currentSelectedModel == "V46MultiModel" {
            mtmdWrapperExample?.currentUsingModelType = .V46MultiModel
        } else if currentSelectedModel == "V5TextModel" {
            mtmdWrapperExample?.currentUsingModelType = .V5TextModel
        } else if currentSelectedModel == "V526TextModel" {
            mtmdWrapperExample?.currentUsingModelType = .V526TextModel
        } else if currentSelectedModel == "Voxcpm2Model" {
            mtmdWrapperExample?.currentUsingModelType = .Voxcpm2Model
        } else if currentSelectedModel == "OcrModel" {
            mtmdWrapperExample?.currentUsingModelType = .OcrModel
        } else if currentSelectedModel == MiniCPMV47Const.userDefaultsKey {
            mtmdWrapperExample?.currentUsingModelType = .V47MoE
        } else if currentSelectedModel == MiniCPMV47_1BConst.userDefaultsKey {
            mtmdWrapperExample?.currentUsingModelType = .V47_1B
        }
        
        // 完整重建数据源（loadTableViewData 内部 removeAll + append）
        loadTableViewData()
        
        if let currentType = mtmdWrapperExample?.currentUsingModelType {
            updateUsingModeltype?(currentType)
        }
    }
}

/// Slot bank 滑条。步进 8，范围 [minSlotBank, maxSlotBank]
private final class MBSlotBankSliderBox: UIView {
    private(set) var bank: Int

    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let hintLabel = UILabel()

    override init(frame: CGRect) {
        bank = MiniCPMV47Const.slotBank()
        super.init(frame: frame)
        backgroundColor = .clear

        valueLabel.textAlignment = .center
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        valueLabel.textColor = .label
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.minimumValue = Float(MiniCPMV47Const.minSlotBank)
        slider.maximumValue = Float(MiniCPMV47Const.maxSlotBank)
        slider.value = Float(bank)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)

        hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(valueLabel)
        addSubview(slider)
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            valueLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            slider.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hintLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        refreshLabels()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        bank = MiniCPMV47Const.clampSlotBank(Int(slider.value.rounded()))
        slider.setValue(Float(bank), animated: false)
        refreshLabels()
    }

    private func refreshLabels() {
        valueLabel.text = "slot bank = \(bank)"
        hintLabel.text = "全层共用 expert 槽（步进 \(MiniCPMV47Const.slotBankStep)）。256 格约 0.5 GiB，不超过旧的每层 32 格。"
    }
}

/// 跳层专家预读深度滑条。范围 [0, 16]，0 = 关闭预测和预读。
private final class MBLookaheadPrefetchDepthSliderBox: UIView {
    private(set) var depth: Int

    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let hintLabel = UILabel()

    override init(frame: CGRect) {
        depth = MiniCPMV47Const.lookaheadPrefetchDepth()
        super.init(frame: frame)
        backgroundColor = .clear

        valueLabel.textAlignment = .center
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        valueLabel.textColor = .label
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.minimumValue = Float(MiniCPMV47Const.minLookaheadPrefetchDepth)
        slider.maximumValue = Float(MiniCPMV47Const.maxLookaheadPrefetchDepth)
        slider.value = Float(depth)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)

        hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.text = L.Settings.lookaheadPrefetchDepthHint.loc

        addSubview(valueLabel)
        addSubview(slider)
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            valueLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            slider.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hintLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        refreshLabels()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        depth = MiniCPMV47Const.clampLookaheadPrefetchDepth(Int(slider.value.rounded()))
        slider.setValue(Float(depth), animated: false)
        refreshLabels()
    }

    private func refreshLabels() {
        if depth == 0 {
            valueLabel.text = L.Settings.lookaheadPrefetchDepthOff.loc
        } else {
            valueLabel.text = "\(depth)"
        }
    }
}

/// 每层缓存槽数 c 的滑条，范围 [0, maxCacheWindowCForDevice()]，步进 8；0 = 关窗口。
/// 同时显示覆盖率与窗口占用（后者需从 experts 读每 slot 字节）。
private final class MBCacheWindowSliderBox: UIView {
    private(set) var c: Int

    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let hintLabel = UILabel()

    override init(frame: CGRect) {
        c = MiniCPMV47Const.cacheWindowC()
        super.init(frame: frame)
        backgroundColor = .clear

        valueLabel.textAlignment = .center
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = 2
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.minimumValue = Float(MiniCPMV47Const.minCacheWindowC)
        slider.maximumValue = Float(MiniCPMV47Const.maxCacheWindowCForDevice())
        slider.value = Float(c)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)

        hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 3
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.text = L.Settings.cacheWindowHint.loc

        addSubview(valueLabel)
        addSubview(slider)
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            valueLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            slider.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hintLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        refreshLabels()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        c = MiniCPMV47Const.clampCacheWindowC(Int(slider.value.rounded()))
        slider.setValue(Float(c), animated: false)
        refreshLabels()
    }

    private func refreshLabels() {
        if c <= 0 {
            valueLabel.text = "c=0（关闭窗口）"
            return
        }
        let cov = Int((MiniCPMV47Const.cacheWindowCoverage(c) * 100).rounded())
        // 窗口内存需从 experts 的每 slot 字节数换算；读不到就只报 c。
        if let gib = MiniCPMV47Const.windowGiB(
                forC: c,
                kSlots: MiniCPMV47Const.decodeWindowPrefetchSlots()) {
            valueLabel.text = String(format: "c=%d（覆盖 %d%%）\n窗口 %.2f GiB", c, cov, gib)
        } else {
            valueLabel.text = "c=\(c)（覆盖 \(cov)%）"
        }
    }
} 
