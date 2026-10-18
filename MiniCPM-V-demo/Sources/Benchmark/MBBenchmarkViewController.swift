//
//  MBBenchmarkViewController.swift
//  MiniCPM-V-demo
//
//  批量基准测试的界面：设参数 → 跑 → 看统计 → 导出。
//
//  ⚠️ 这里**没有档位、没有合格/不合格判定**。
//  界面只负责把实验跑完并把统计量如实呈现，判定留给读报告的人。
//
//  界面刻意做得很朴：这是一个**测量工具**而不是演示 Demo。所有可调项都写进
//  结果 JSON 的 `config` 段，导出的文件自包含、可独立复核。
//

import UIKit
import Combine

@MainActor
public final class MBBenchmarkViewController: UIViewController {

    // MARK: - 输入

    private let wrapperExample: MTMDWrapperExample

    public init(with wrapperExample: MTMDWrapperExample) {
        self.wrapperExample = wrapperExample
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 状态

    private let runner = BenchmarkRunner()
    private var cancellables = Set<AnyCancellable>()

    private var repetitions: Int = 3
    private var decodeTokenLimit: Int = 256
    private var warmupEnabled: Bool = true
    private var cooldownSec: Int = 0

    // MARK: - 视图

    private let repStepper = UIStepper()
    private let repLabel = UILabel()
    private let tokenStepper = UIStepper()
    private let tokenLabel = UILabel()
    private let warmupSwitch = UISwitch()
    private let warmupLabel = UILabel()
    private let cooldownStepper = UIStepper()
    private let cooldownLabel = UILabel()
    private let tempLabel = UILabel()
    private let datasetButton = UIButton(type: .system)
    private let startButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let progressLabel = UILabel()
    private let resultTextView = UITextView()
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    // MARK: - 生命周期

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "批量基准测试"
        view.backgroundColor = .systemBackground
        setupUI()
        bind()
        refreshDatasetButtonTitle()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTempLabel()
    }

    // MARK: - UI

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        repStepper.minimumValue = 1
        repStepper.maximumValue = 10
        repStepper.value = Double(repetitions)
        repStepper.addTarget(self, action: #selector(repChanged), for: .valueChanged)
        repLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)

        tokenStepper.minimumValue = 1
        tokenStepper.maximumValue = 256
        tokenStepper.stepValue = 1
        tokenStepper.value = Double(decodeTokenLimit)
        tokenStepper.addTarget(self, action: #selector(tokenChanged), for: .valueChanged)
        tokenLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)

        warmupSwitch.isOn = warmupEnabled
        warmupSwitch.addTarget(self, action: #selector(warmupChanged), for: .valueChanged)
        warmupLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)

        cooldownStepper.minimumValue = 0
        cooldownStepper.maximumValue = 300
        cooldownStepper.stepValue = 15
        cooldownStepper.value = Double(cooldownSec)
        cooldownStepper.addTarget(self, action: #selector(cooldownChanged), for: .valueChanged)
        cooldownLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)

        tempLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        tempLabel.numberOfLines = 0

        datasetButton.addTarget(self, action: #selector(datasetButtonTapped), for: .touchUpInside)

        startButton.setTitle("开始跑批", for: .normal)
        startButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        startButton.addTarget(self, action: #selector(startRun), for: .touchUpInside)

        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelRun), for: .touchUpInside)
        cancelButton.isEnabled = false

        exportButton.setTitle("导出最近一次结果", for: .normal)
        exportButton.addTarget(self, action: #selector(exportResult), for: .touchUpInside)
        exportButton.isEnabled = false

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        progressLabel.numberOfLines = 0
        progressLabel.text = "未开始"

        resultTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        resultTextView.isEditable = false
        resultTextView.layer.borderWidth = 0.5
        resultTextView.layer.borderColor = UIColor.separator.cgColor
        resultTextView.layer.cornerRadius = 6
        resultTextView.heightAnchor.constraint(equalToConstant: 420).isActive = true

        let stack = UIStackView(arrangedSubviews: [
            makeSectionTitle("重复轮数"),
            hstack(repLabel, repStepper),
            makeHint("跨 case 的方差通常远大于同 case 重复间的方差，所以「多 case × 少重复」" +
                "比「少 case × 多重复」信息量大。轮数主要用来估可复现性和压低标准误。"),
            makeSectionTitle("固定输出 token 数"),
            hstack(tokenLabel, tokenStepper),
            makeHint("输出长度必须固定：权重走 SSD，输出越长搬运越多，长度不同则跨 case 不可比。" +
                "达到该步数前**忽略 EOG**，保证每条长度一致。"),
            makeSectionTitle("短预热"),
            hstack(warmupSwitch, warmupLabel),
            makeHint("正式跑批前先跑一句「\(BenchmarkRunConfig.warmupPrompt)」、只出 "
                + "\(BenchmarkRunConfig.warmupTokens) 个 token，把专家层与 GPU 频率走热。"
                + "这条会落盘留证但不计入统计。各轮之间还会轮转 case 顺序，避免位次冷热伪装成 case 差异。"),
            makeSectionTitle("轮间冷却"),
            hstack(cooldownLabel, cooldownStepper),
            makeHint("每轮开始前静止等待，让 SoC 回到相近温度。长跑时建议 30~60 秒，" +
                "否则热降频会让后面的轮次系统性变慢。"),
            makeHint("内置 12 条真实 case（图来自 35BA3B_cases，提示词为文档原文）。" +
                "提示词长度不等，会混进 prefill token 数差异，明细里已记 promptUTF8Length 供校正。"),
            tempLabel,
            datasetButton,
            hstack(startButton, cancelButton),
            exportButton,
            makeSectionTitle("进度与统计"),
            progressLabel,
            resultTextView
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])

        updateStepperLabels()
    }

    private func hstack(_ a: UIView, _ b: UIView) -> UIStackView {
        let s = UIStackView(arrangedSubviews: [a, b])
        s.axis = .horizontal
        s.spacing = 12
        s.alignment = .center
        return s
    }

    private func makeSectionTitle(_ t: String) -> UILabel {
        let l = UILabel()
        l.text = t
        l.font = .systemFont(ofSize: 16, weight: .semibold)
        return l
    }

    private func makeHint(_ t: String) -> UILabel {
        let l = UILabel()
        l.text = t
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }

    private func updateStepperLabels() {
        repLabel.text = "\(repetitions) 轮"
        tokenLabel.text = "\(decodeTokenLimit) token"
        warmupLabel.text = warmupEnabled
            ? "开启（「\(BenchmarkRunConfig.warmupPrompt)」\(BenchmarkRunConfig.warmupTokens) token）"
            : "关闭"
        cooldownLabel.text = cooldownSec == 0 ? "不冷却" : "\(cooldownSec) 秒"
    }

    // MARK: - 绑定

    private func bind() {
        runner.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in
                guard let self = self else { return }
                let running = (p == .running)
                self.startButton.isEnabled = !running
                self.cancelButton.isEnabled = running
                self.repStepper.isEnabled = !running
                self.tokenStepper.isEnabled = !running
                self.warmupSwitch.isEnabled = !running
                self.cooldownStepper.isEnabled = !running
                self.datasetButton.isEnabled = !running
            }
            .store(in: &cancellables)

        runner.$progressText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.progressLabel.text = t }
            .store(in: &cancellables)

        runner.$lastResult
            .receive(on: DispatchQueue.main)
            .sink { [weak self] r in
                guard let self = self, let r = r else { return }
                self.exportButton.isEnabled = true
                self.resultTextView.text = BenchmarkReport.text(r)
            }
            .store(in: &cancellables)

        runner.$failureMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] m in
                guard let self = self, let m = m else { return }
                self.resultTextView.text = "失败：\(m)"
            }
            .store(in: &cancellables)
    }

    // MARK: - 动作

    @objc private func repChanged() {
        repetitions = Int(repStepper.value)
        updateStepperLabels()
    }

    @objc private func tokenChanged() {
        decodeTokenLimit = Int(tokenStepper.value)
        updateStepperLabels()
    }

    @objc private func warmupChanged() {
        warmupEnabled = warmupSwitch.isOn
        updateStepperLabels()
    }

    @objc private func cooldownChanged() {
        cooldownSec = Int(cooldownStepper.value)
        updateStepperLabels()
    }

    /// 显示当前生效的采样温度。
    ///
    /// 温度现在由代码单点决定（`MTMDParams.temperature` 默认 0.0 = 贪心），
    /// 不再依赖任何启动参数，所以正常情况下这里恒为 0。
    /// 仍保留显示与告警：万一日后有人把默认值改回去，界面会立刻暴露，
    /// 而不是等到一批数据跑完才发现不可复现。
    private func refreshTempLabel() {
        let t = BenchmarkRunner.effectiveTemperature(example: wrapperExample)
        if t == 0 {
            tempLabel.text = "采样温度 0（贪心）✓ 结果可复现"
            tempLabel.textColor = .systemGreen
        } else {
            tempLabel.text =
                "采样温度 \(t) ⚠️ 已不是贪心，跑批数据不可复现。\n" +
                "请检查 MTMDParams.temperature 默认值（应为 0.0）后重新编译。"
            tempLabel.textColor = .systemOrange
        }
    }

    /// 在「导出内置数据集」与「移除自定义数据集」之间切换。
    @objc private func datasetButtonTapped() {
        do {
            if BenchmarkCaseStore.currentSource() == .documents {
                try BenchmarkSampleDataset.removeCustomDataset()
                progressLabel.text = "已移除自定义数据集，恢复使用 App 内置数据集"
            } else {
                let n = try BenchmarkSampleDataset.exportBuiltinToDocuments()
                progressLabel.text = "已导出 \(n) 个文件到 Documents/benchmark/，" +
                    "可在「文件」App 里改提示词或换图"
            }
            refreshDatasetButtonTitle()
        } catch {
            progressLabel.text = "操作失败：\(error.localizedDescription)"
        }
    }

    @objc private func startRun() {
        Task { [weak self] in
            guard let self = self else { return }
            let cases: [BenchmarkCase]
            do {
                cases = try BenchmarkCaseStore.load()
            } catch {
                self.progressLabel.text = "数据集读取失败：\(error.localizedDescription)"
                return
            }
            guard !cases.isEmpty else {
                self.progressLabel.text = "cases.jsonl 里没有有效 case"
                return
            }

            let config = BenchmarkRunConfig(repetitions: self.repetitions,
                                            decodeTokenLimit: self.decodeTokenLimit,
                                            warmupEnabled: self.warmupEnabled,
                                            cooldownSec: Double(self.cooldownSec))
            await self.runner.run(cases: cases,
                                  config: config,
                                  example: self.wrapperExample)
        }
    }

    @objc private func cancelRun() {
        runner.cancel()
    }

    @objc private func exportResult() {
        guard let r = runner.lastResult else { return }
        let resultURL = BenchmarkResultStore.resultFileURL(r.meta.uuid)
        let telemetryURL = BenchmarkResultStore.telemetryFileURL(r.meta.uuid)
        var items: [URL] = [resultURL]
        if FileManager.default.fileExists(atPath: telemetryURL.path) { items.append(telemetryURL) }

        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = exportButton
        present(vc, animated: true)
    }

    private func refreshDatasetButtonTitle() {
        let isCustom = BenchmarkCaseStore.currentSource() == .documents
        datasetButton.setTitle(isCustom ? "移除自定义数据集（改用内置）"
                                        : "导出内置数据集到 Documents",
                              for: .normal)
    }
}
