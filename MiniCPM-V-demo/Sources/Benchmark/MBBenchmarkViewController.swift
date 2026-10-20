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

    private var repetitions: Int = 1
    /// 输出 token **上限**（撞 EOG 会提前停，不是固定步数）
    private var decodeTokenLimit: Int = 512
    // 短预热已关闭（UI 也不再显示）：它会把一条「你好」写进结果里，
    // 且实测对跑批数字没有稳定收益，反而多一次 prefill 的读盘。
    // 逻辑仍保留，需要时用 `-benchWarmup 1` 打开。
    private var warmupEnabled: Bool = false
    private var cooldownSec: Int = 0
    /// 每条 track 本次跑多少条（滑条，0 = 不跑），写回 UserDefaults。
    private var plan: [String: Int] = BenchmarkCaseStore.selectedPlan()
    private var trackCaseCount: Int = 0

    // MARK: - 视图

    private let repStepper = UIStepper()
    private let repLabel = UILabel()
    private let tokenStepper = UIStepper()
    private let tokenLabel = UILabel()
    private let cooldownStepper = UIStepper()
    private let cooldownLabel = UILabel()
    /// 「数据集」折叠头（点击展开/收起）
    private let trackHeader = UIButton(type: .system)
    /// 展开后的卡片：每条 track 一行（标题 + 滑条 + 说明）
    private let trackCard = UIStackView()
    private var trackSliders: [String: UISlider] = [:]
    private var trackValueLabels: [String: UILabel] = [:]
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

        tokenStepper.minimumValue = 16
        tokenStepper.maximumValue = 2048
        tokenStepper.stepValue = 64
        tokenStepper.value = Double(decodeTokenLimit)
        tokenStepper.addTarget(self, action: #selector(tokenChanged), for: .valueChanged)
        tokenLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)

        // 折叠头：灰底圆角 + 尾部 chevron（系统原生观感，iOS 18~26 通用）
        var headCfg = UIButton.Configuration.gray()
        headCfg.title = "数据集"
        headCfg.image = UIImage(systemName: "chevron.down")
        headCfg.imagePlacement = .trailing
        headCfg.imagePadding = 10
        headCfg.cornerStyle = .medium
        headCfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        trackHeader.configuration = headCfg
        trackHeader.addTarget(self, action: #selector(toggleTrackList), for: .touchUpInside)

        // 展开卡片：圆角容器（insetGrouped 观感）
        trackCard.axis = .vertical
        trackCard.spacing = 18
        trackCard.isLayoutMarginsRelativeArrangement = true
        trackCard.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16,
                                                                     bottom: 16, trailing: 16)
        trackCard.backgroundColor = .secondarySystemGroupedBackground
        trackCard.layer.cornerRadius = 12
        trackCard.layer.cornerCurve = .continuous
        trackCard.isHidden = true

        for (i, t) in BenchmarkCaseStore.bundledTracks.enumerated() {
            let total = BenchmarkCaseStore.trackTotal(t)

            let name = UILabel()
            name.text = t
            name.font = .systemFont(ofSize: 15, weight: .semibold)

            let value = UILabel()
            value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
            value.textColor = .secondaryLabel
            value.textAlignment = .right
            value.setContentHuggingPriority(.required, for: .horizontal)
            trackValueLabels[t] = value

            let top = UIStackView(arrangedSubviews: [name, value])
            top.axis = .horizontal
            top.alignment = .firstBaseline

            let slider = UISlider()
            slider.minimumValue = 0
            slider.maximumValue = Float(max(1, total))
            slider.value = Float(min(plan[t] ?? 0, total))
            slider.isContinuous = true
            slider.tag = i
            slider.isEnabled = total > 0
            slider.addTarget(self, action: #selector(trackSliderChanged(_:)), for: .valueChanged)
            trackSliders[t] = slider

            let desc = UILabel()
            desc.text = trackSummary(t)
            desc.font = .systemFont(ofSize: 12)
            desc.textColor = .secondaryLabel
            desc.numberOfLines = 0

            let row = UIStackView(arrangedSubviews: [top, slider, desc])
            row.axis = .vertical
            row.spacing = 4
            trackCard.addArrangedSubview(row)
        }

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
            trackHeader,
            trackCard,
            makeHint("拖动滑条决定每条数据集本次跑多少条（0 = 不跑）。"
                + "数据集随 App 分发、启动自动铺好，无需手动传输。"),
            makeSectionTitle("重复轮数"),
            hstack(repLabel, repStepper),
            makeHint("跨 case 的方差通常远大于同 case 重复间的方差，所以「多 case × 少重复」" +
                "比「少 case × 多重复」信息量大。轮数主要用来估可复现性和压低标准误。"),
            makeSectionTitle("输出 token 上限"),
            hstack(tokenLabel, tokenStepper),
            makeHint("只限上限，撞 EOG 会提前停（不同 case 输出长度可以不同）。"
                + "设大一些能让需要长回答的 case 跑完。"),
            tempLabel,
            // 「重铺数据集」按钮暂不展示：低频运维操作，且文案容易让人以为是必做步骤。
            // 逻辑（datasetButtonTapped / reinstallActiveTrack）保留，需要时可放回这里。
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
        refreshTrackControls()
        repLabel.text = "\(repetitions) 轮"
        tokenLabel.text = "≤ \(decodeTokenLimit) token"
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
                self.trackHeader.isEnabled = !running
                for sl in self.trackSliders.values { sl.isEnabled = !running }
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

    /// 展开 / 收起数据集卡片。
    @objc private func toggleTrackList() {
        trackCard.isHidden.toggle()
        refreshTrackControls()
    }

    /// 拖动滑条：取整、写回 plan、刷新标题。
    @objc private func trackSliderChanged(_ sender: UISlider) {
        let tracks = BenchmarkCaseStore.bundledTracks
        guard sender.tag >= 0, sender.tag < tracks.count else { return }
        let t = tracks[sender.tag]
        let v = Int(sender.value.rounded())
        sender.value = Float(v)
        plan[t] = v
        BenchmarkCaseStore.setPlan(plan)
        refreshTrackControls()
    }

    /// 刷新折叠头（共 N 条）与每行的 "已选 / 总数"。
    private func refreshTrackControls() {
        var total = 0
        for t in BenchmarkCaseStore.bundledTracks {
            let n = plan[t] ?? 0
            total += n
            trackValueLabels[t]?.text = "\(n) / \(BenchmarkCaseStore.trackTotal(t))"
        }
        trackCaseCount = total

        var cfg = trackHeader.configuration ?? UIButton.Configuration.gray()
        cfg.title = total > 0 ? "数据集 · 共 \(total) 条" : "数据集 · 未选择"
        cfg.image = UIImage(systemName: trackCard.isHidden ? "chevron.down" : "chevron.up")
        trackHeader.configuration = cfg
    }

    /// 给每条 track 一句人话描述（加 track 时一并加）。
    private func trackSummary(_ track: String) -> String {
        switch track {
        case "vision_mix_50":
            return "1B/35B/4.6 已审核 25 条 + 识图/描述/简单题 25 条"
        case "mlperf_llm":
            return "MLPerf Mobile v6.0（Tiny-MMLU 100 + Tiny-IFEval 33），纯文本"
        default:
            return "未知 track"
        }
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

    /// 把 bundle 里的数据集重新铺到 Documents（覆盖手工改动）。
    ///
    /// 数据集现在随 App 一起分发、启动时自动铺好，所以这里不再是"导出/移除"，
    /// 而是"重置"：改坏了图或提示词时点一下恢复出厂。
    @objc private func datasetButtonTapped() {
        do {
            let summary = try BenchmarkSampleDataset.reinstallActiveTrack()
            progressLabel.text = "已重铺数据集（track=\(BenchmarkCaseStore.activeTrack())）：\(summary)\n"
                + "可在「文件」App 的 Documents/benchmark/ 下改图或改提示词"
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
                self.progressLabel.text = "当前数据集选择为空：拖一下滑条，让至少一条数据集 > 0"
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
        let track = BenchmarkCaseStore.activeTrack()
        let n = (try? BenchmarkCaseStore.load().count) ?? 0
        datasetButton.setTitle("重铺数据集到 Documents（\(track) · \(n) 条）", for: .normal)
    }
}
