//
//  MBOcrModelDetailViewController.swift
//  MiniCPM-V-demo
//
//  OCR 模型详情页面 VC（下载管理 + 使用该模型）
//

import Foundation
import UIKit
import SnapKit

@objc public class MBOcrModelDetailViewController: UIViewController, UIGestureRecognizerDelegate {

    var modelName: String = "MiniCPM-OCR 1.0"

    private let downloadManager = MBOcrModelDownloadManager.shared

    private var mtmdWrapperExample: MTMDWrapperExample?

    lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .grouped)
        tv.register(MBSettingsTableViewCell.self, forCellReuseIdentifier: "MBSettingsTableViewCell")
        tv.estimatedRowHeight = 48
        tv.separatorStyle = .none
        tv.separatorColor = .clear
        tv.dataSource = self
        tv.delegate = self
        return tv
    }()

    var dataArray = [MBSettingsModel]()

    lazy var useModelButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.mb_color(with: "#007AFF")
        button.layer.cornerRadius = 8
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: #selector(useModelButtonTapped), for: .touchUpInside)
        return button
    }()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    init(with wrapper: MTMDWrapperExample) {
        self.mtmdWrapperExample = wrapper
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupSubViews()
        setupDownloadManager()
        loadTableViewData()
        setupDownloadManagerCallbacks()
        updateUseModelButtonState()
        UIApplication.shared.isIdleTimerDisabled = true
        self.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        self.navigationController?.interactivePopGestureRecognizer?.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(applyLanguage),
                                               name: .languageDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyLanguage() {
        loadTableViewData()
        updateUseModelButtonState()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return self.navigationController?.viewControllers.count ?? 0 > 1
    }

    // MARK: - UI

    func setupSubViews() {
        self.title = modelName
        let titleDict: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.black]
        self.navigationController?.navigationBar.titleTextAttributes = titleDict
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

    func setupNavView() {
        let img = UIImage(systemName: "chevron.left")
        let leftNavIcon = UIBarButtonItem(image: img, style: .plain, target: self,
                                          action: #selector(handleLeftNavIcon))
        leftNavIcon.tintColor = .black
        self.navigationItem.leftBarButtonItem = leftNavIcon

        let refreshImg = UIImage(systemName: "arrow.clockwise")
        let rightNavButton = UIBarButtonItem(image: refreshImg, style: .plain, target: self,
                                             action: #selector(handleRightNavButton))
        rightNavButton.tintColor = .black
        self.navigationItem.rightBarButtonItem = rightNavButton

        self.navigationController?.setNavigationBackgroundColor(UIColor.mb_color(with: "#F9FAFC") ?? .white)
    }

    @objc public func handleLeftNavIcon() {
        self.navigationController?.popViewController(animated: true)
    }

    @objc public func handleRightNavButton() {
        showRedownloadAlert()
    }

    @objc public func useModelButtonTapped() {
        switch currentButtonState() {
        case .needsDownload:
            downloadManager.downloadAll()
            updateUseModelButtonState()
        case .downloading: break
        case .ready:
            setAsCurrentModel()
        }
    }

    private enum MainButtonState { case needsDownload, downloading, ready }

    private func currentButtonState() -> MainButtonState {
        if checkAllModelsDownloaded() { return .ready }
        if downloadManager.hasAnyDownloadActive() { return .downloading }
        return .needsDownload
    }

    private func showRedownloadAlert() {
        let alert = UIAlertController(title: L.ModelDetail.redownloadTitle.loc,
                                      message: L.ModelDetail.redownloadMessage.loc,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L.Common.cancel.loc, style: .cancel))
        alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .destructive) { [weak self] _ in
            self?.performRedownload()
        })
        present(alert, animated: true)
    }

    private func performRedownload() {
        let hud = MBHUD.showAdded(to: self.view, animated: true)
        hud.label.text = L.ModelDetail.redownloadHudCleaning.loc
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.downloadManager.deleteAllDownloadedFiles()
            self.downloadManager.cleanupCacheFiles()
            self.downloadManager.resetDownloadStates()
            self.downloadManager.llmManager?.status = "download"
            self.downloadManager.mmprojManager?.status = "download"
            self.downloadManager.layoutManager?.status = "download"
            DispatchQueue.main.async {
                hud.hide(animated: true)
                self.loadTableViewData()
                let successHud = MBHUD.showAdded(to: self.view, animated: true)
                successHud.mode = .text
                successHud.label.text = L.ModelDetail.redownloadHudCleaned.loc
                successHud.hide(animated: true, afterDelay: 2.0)
            }
        }
    }

    // MARK: - 下载管理器

    private func setupDownloadManager() {
        if let mtmdWrapperExample = mtmdWrapperExample {
            downloadManager.setupDownloadManager(with: mtmdWrapperExample)
        } else {
            let alert = UIAlertController(title: L.Common.error.loc,
                                          message: L.ModelDetail.alertNoWrapper.loc,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .default) { _ in
                self.navigationController?.popViewController(animated: true)
            })
            self.present(alert, animated: true)
        }
    }

    private func setupDownloadManagerCallbacks() {
        downloadManager.progressHandler = { [weak self] modelName, progress in
            DispatchQueue.main.async { self?.updateCellProgress(modelName: modelName, progress: progress) }
        }
        downloadManager.completionHandler = { [weak self] modelName, success in
            DispatchQueue.main.async { self?.updateCellCompletion(modelName: modelName, success: success) }
        }
    }

    // MARK: - Cell 状态更新

    private func updateCellProgress(modelName: String, progress: CGFloat) {
        guard self.isViewLoaded, self.view.window != nil else { return }
        for (index, model) in dataArray.enumerated() where model.title == modelName {
            model.statusString = progress >= 1.0 ? L.Download.statusDownloaded.loc
                               : progress > 0    ? "\(Int(progress * 100))%"
                               : L.Download.statusDownloading.loc
            if let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? MBSettingsTableViewCell {
                cell.configure(with: model)
            }
            break
        }
        updateUseModelButtonState()
    }

    private func updateCellCompletion(modelName: String, success: Bool) {
        for (index, model) in dataArray.enumerated() where model.title == modelName {
            model.statusString = success ? L.Download.statusDownloaded.loc : L.Download.statusFailed.loc
            if let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? MBSettingsTableViewCell {
                cell.configure(with: model)
            }
            let hud = MBHUD.showAdded(to: self.view, animated: true)
            hud.mode = .text
            hud.label.text = String(format: (success ? L.ModelDetail.toastDownloadSuccessFormat : L.ModelDetail.toastDownloadFailedFormat).loc, modelName)
            hud.hide(animated: true, afterDelay: 2.0)
            updateUseModelButtonState()
            break
        }
    }
}

// MARK: - UITableViewDataSource
extension MBOcrModelDetailViewController: UITableViewDataSource {
    public func numberOfSections(in tableView: UITableView) -> Int { 1 }
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { dataArray.count }
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 48 }
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MBSettingsTableViewCell", for: indexPath) as! MBSettingsTableViewCell
        cell.configure(with: dataArray[indexPath.row])
        return cell
    }
    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 0 }
    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? { nil }
}

// MARK: - UITableViewDelegate
extension MBOcrModelDetailViewController: UITableViewDelegate {
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let model = dataArray[indexPath.row]
        guard let title = model.title else { return }
        switch title {
        case MiniCPMModelConst.ocr_LLMDisplayedName:
            handleModelDownload(modelName: title) { [weak self] in self?.downloadManager.downloadLLM() }
        case MiniCPMModelConst.ocr_MMProjDisplayedName:
            handleModelDownload(modelName: title) { [weak self] in self?.downloadManager.downloadMMProj() }
        case MiniCPMModelConst.ocr_LayoutDisplayedName:
            handleModelDownload(modelName: title) { [weak self] in self?.downloadManager.downloadLayout() }
        default: break
        }
    }

    private func handleModelDownload(modelName: String, downloadAction: @escaping () -> Void) {
        if checkIfModelDownloaded(modelName: modelName) {
            let alert = UIAlertController(title: L.ModelDetail.alertAlreadyDownloadedTitle.loc,
                                          message: String(format: L.ModelDetail.alertAlreadyDownloadedMessageFormat.loc, modelName),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L.Common.ok.loc, style: .default))
            present(alert, animated: true)
        } else {
            downloadAction()
        }
    }

    private func checkIfModelDownloaded(modelName: String) -> Bool {
        switch modelName {
        case MiniCPMModelConst.ocr_LLMDisplayedName:    return downloadManager.getLLMStatus() == "downloaded"
        case MiniCPMModelConst.ocr_MMProjDisplayedName: return downloadManager.getMMProjStatus() == "downloaded"
        case MiniCPMModelConst.ocr_LayoutDisplayedName: return downloadManager.getLayoutStatus() == "downloaded"
        default: return false
        }
    }
}

// MARK: - 数据配置 / 使用模型
extension MBOcrModelDetailViewController {

    public func loadTableViewData() {
        dataArray.removeAll()

        let llmModel = MBSettingsModel()
        llmModel.title = MiniCPMModelConst.ocr_LLMDisplayedName
        llmModel.icon = UIImage(systemName: "cpu")
        llmModel.statusString = getInitialStatus(for: downloadManager.getLLMStatus())
        llmModel.shouldShowStatusText = true
        dataArray.append(llmModel)

        let mmprojModel = MBSettingsModel()
        mmprojModel.title = MiniCPMModelConst.ocr_MMProjDisplayedName
        mmprojModel.icon = UIImage(systemName: "cpu")
        mmprojModel.statusString = getInitialStatus(for: downloadManager.getMMProjStatus())
        mmprojModel.shouldShowStatusText = true
        dataArray.append(mmprojModel)

        let layoutModel = MBSettingsModel()
        layoutModel.title = MiniCPMModelConst.ocr_LayoutDisplayedName
        layoutModel.icon = UIImage(systemName: "cpu")
        layoutModel.statusString = getInitialStatus(for: downloadManager.getLayoutStatus())
        layoutModel.shouldShowStatusText = true
        dataArray.append(layoutModel)

        tableView.reloadData()
    }

    private func getInitialStatus(for downloadStatus: String) -> String {
        switch downloadStatus {
        case "downloaded":  return L.Download.statusDownloaded.loc
        case "downloading": return L.Download.statusDownloading.loc
        case "failed":      return L.Download.statusFailed.loc
        default:            return L.Download.statusNotDownloaded.loc
        }
    }

    private func checkAllModelsDownloaded() -> Bool {
        downloadManager.reconcileStatusFromDisk()
        return downloadManager.getLLMStatus() == "downloaded" &&
               downloadManager.getMMProjStatus() == "downloaded" &&
               downloadManager.getLayoutStatus() == "downloaded"
    }

    fileprivate func updateUseModelButtonState() {
        switch currentButtonState() {
        case .needsDownload:
            useModelButton.isEnabled = true
            useModelButton.setTitle(L.Download.downloadAll.loc, for: .normal)
            useModelButton.backgroundColor = UIColor.mb_color(with: "#007AFF")
            useModelButton.setTitleColor(.white, for: .normal)
        case .downloading:
            useModelButton.isEnabled = false
            let percent = Int(downloadManager.overallProgress() * 100)
            useModelButton.setTitle(String(format: L.ModelDetail.mainButtonDownloadingFormat.loc, percent), for: .normal)
            useModelButton.backgroundColor = UIColor.mb_color(with: "#CCCCCC")
            useModelButton.setTitleColor(.darkGray, for: .normal)
        case .ready:
            useModelButton.isEnabled = true
            useModelButton.setTitle(L.ModelDetail.mainButtonUseThis.loc, for: .normal)
            useModelButton.backgroundColor = UIColor.mb_color(with: "#007AFF")
            useModelButton.setTitleColor(.white, for: .normal)
        }
    }

    private func setAsCurrentModel() {
        mtmdWrapperExample?.currentUsingModelType = .OcrModel
        UserDefaults.standard.setValue("OcrModel", forKey: "current_selected_model")
        NotificationCenter.default.post(name: .mbModelSelectionChanged, object: nil)

        let hud = MBHUD.showAdded(to: self.view, animated: true)
        hud.mode = .text
        hud.label.text = String(format: L.ModelDetail.toastSetAsCurrentFormat.loc, modelName)
        hud.hide(animated: true, afterDelay: 2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.navigationController?.popViewController(animated: true)
        }
    }
}
