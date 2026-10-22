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
    /// 输出 token 上限只给几档，避免 16/64 这种步进带来的无意义细调。
    private static let tokenChoices = [128, 256, 512, 1024, 2048]
    private let tokenPicker = UISegmentedControl(items: tokenChoices.map(String.init))
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let progressCountLabel = UILabel()
    private let cooldownStepper = UIStepper()
    private let cooldownLabel = UILabel()
    /// 「数据集」折叠头（点击展开/收起）
    private let trackHeader = UIButton(type: .system)
    /// 展开后的卡片：默认数据集里**每条 case 一行 + 开关**
    private let trackCard = UIStackView()
    /// 「其它数据集」折叠头 + 卡片（vision_mix_50 / mlperf_llm 收在这里，默认收起）
    private let otherTracksHeader = UIButton(type: .system)
    private let otherTracksCard = UIStackView()
    private var caseSwitches: [Int: UISwitch] = [:]
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
    /// 语言切换（EN / 中文）。只影响本页与它产出的日志。
    private let languagePicker = UISegmentedControl(items: BenchmarkLocale.allCases.map(\.displayName))

    // MARK: - 生命周期

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = BML.t("Batch Benchmark", "批量基准测试")
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
        // 这个方法会被「切换语言」重复调用，所以先把上次建的东西全部拆掉；
        // 否则每次重建都会再追加一遍行与视图，表现就是列表越来越长、文字互相叠住。
        contentView.subviews.forEach { $0.removeFromSuperview() }
        contentView.removeFromSuperview()
        trackCard.arrangedSubviews.forEach { $0.removeFromSuperview() }
        otherTracksCard.arrangedSubviews.forEach { $0.removeFromSuperview() }

        languagePicker.selectedSegmentIndex =
            BenchmarkLocale.allCases.firstIndex(of: BML.language) ?? 0
        languagePicker.addTarget(self, action: #selector(languageChanged), for: .valueChanged)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: languagePicker)

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

        tokenPicker.selectedSegmentIndex =
            Self.tokenChoices.firstIndex(of: decodeTokenLimit) ?? Self.tokenChoices.count / 2
        tokenPicker.addTarget(self, action: #selector(tokenChanged), for: .valueChanged)

        // 折叠头：灰底圆角 + 尾部 chevron（系统原生观感，iOS 18~26 通用）
        var headCfg = UIButton.Configuration.gray()
        headCfg.title = BML.t("Dataset", "数据集")
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
        // 默认展开：单条开关是主操作，收起来就等于看不见。

        // 默认数据集：每条 case 一行 + 开关（默认全开）。
        for c in (try? BenchmarkCaseStore.load(track: BenchmarkCaseStore.defaultTrack)) ?? [] {
            let sw = UISwitch()
            sw.isOn = BenchmarkCaseStore.isCaseEnabled(c.key)
            sw.tag = c.key
            sw.addTarget(self, action: #selector(caseSwitchChanged(_:)), for: .valueChanged)
            caseSwitches[c.key] = sw

            let title = UILabel()
            title.text = "\(c.key) · \(c.displayKind)"
            title.font = .systemFont(ofSize: 15, weight: .semibold)

            let top = UIStackView(arrangedSubviews: [title, sw])
            top.axis = .horizontal
            top.alignment = .center

            // 副标题取第一条 user 消息，system 那行对识别没帮助。
            let prompt = (c.turns.first { $0.role == .user }?.text ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            let desc = UILabel()
            desc.text = prompt.count > 40 ? String(prompt.prefix(40)) + "…" : prompt
            desc.font = .systemFont(ofSize: 12)
            desc.textColor = .secondaryLabel
            desc.numberOfLines = 1

            let row = UIStackView(arrangedSubviews: [top, desc])
            row.axis = .vertical
            row.spacing = 2
            trackCard.addArrangedSubview(row)
        }

        // 其它数据集：折叠 + 滑条，默认收起、默认 0 条。
        var otherCfg = UIButton.Configuration.gray()
        otherCfg.title = BML.t("Other datasets", "其它数据集")
        otherCfg.image = UIImage(systemName: "chevron.down")
        otherCfg.imagePlacement = .trailing
        otherCfg.imagePadding = 10
        otherCfg.cornerStyle = .medium
        otherCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        otherTracksHeader.configuration = otherCfg
        otherTracksHeader.addTarget(self, action: #selector(toggleOtherTracks), for: .touchUpInside)

        otherTracksCard.axis = .vertical
        otherTracksCard.spacing = 18
        otherTracksCard.isLayoutMarginsRelativeArrangement = true
        otherTracksCard.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16,
                                                                           bottom: 16, trailing: 16)
        otherTracksCard.backgroundColor = .secondarySystemGroupedBackground
        otherTracksCard.layer.cornerRadius = 12
        otherTracksCard.layer.cornerCurve = .continuous
        otherTracksCard.isHidden = true

        for t in BenchmarkCaseStore.bundledTracks where t != BenchmarkCaseStore.defaultTrack {
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
            slider.tag = BenchmarkCaseStore.bundledTracks.firstIndex(of: t) ?? 0
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
            otherTracksCard.addArrangedSubview(row)
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

        startButton.setTitle(BML.t("Run Batch", "执行批量测试"), for: .normal)
        startButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        startButton.addTarget(self, action: #selector(startRun), for: .touchUpInside)

        cancelButton.setTitle(BML.t("Cancel", "取消"), for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelRun), for: .touchUpInside)
        cancelButton.isEnabled = false

        exportButton.setTitle(BML.t("Export Last Result", "导出最近一次结果"), for: .normal)
        exportButton.addTarget(self, action: #selector(exportResult), for: .touchUpInside)
        exportButton.isEnabled = false

        progressView.progress = 0
        progressCountLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        progressCountLabel.textColor = .secondaryLabel
        progressCountLabel.text = BML.t("Idle", "未开始")

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        progressLabel.numberOfLines = 0
        progressLabel.text = BML.t("Idle", "未开始")

        resultTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        resultTextView.isEditable = false
        resultTextView.layer.borderWidth = 0.5
        resultTextView.layer.borderColor = UIColor.separator.cgColor
        resultTextView.layer.cornerRadius = 6
        resultTextView.heightAnchor.constraint(equalToConstant: 420).isActive = true

        let stack = UIStackView(arrangedSubviews: [
            trackHeader,
            trackCard,
            otherTracksHeader,
            otherTracksCard,
            makeHint(BML.t("Default dataset: toggle each case; other datasets use a count slider.",
                "默认数据集按「单条 case」勾选；其它数据集按条数滑条选择。")
                + BML.t(" Datasets ship with the app and are installed on launch.",
                    "数据集随 App 分发、启动自动铺好，无需手动传输。")),
            makeSectionTitle(BML.t("Repetitions", "重复轮数")),
            hstack(repLabel, repStepper),
            makeHint(BML.t("Variance across cases is usually far larger than between repeats, so \"many cases × few repeats\"",
                "跨 case 的方差通常远大于同 case 重复间的方差，所以「多 case × 少重复」") +
                BML.t(" carries more information than \"few cases × many repeats\". Repeats mostly estimate reproducibility.",
                    "比「少 case × 多重复」信息量大。轮数主要用来估可复现性和压低标准误。")),
            makeSectionTitle(BML.t("Output token limit", "输出 token 上限")),
            tokenPicker,
            makeHint(BML.t("Upper bound only; generation stops early on EOG (output length may differ per case).",
                "只限上限，撞 EOG 会提前停（不同 case 输出长度可以不同）。")
                + BML.t(" Raise it so long answers are not cut off.",
                    "设大一些能让需要长回答的 case 跑完。")),
            tempLabel,
            // 「重铺数据集」按钮暂不展示：低频运维操作，且文案容易让人以为是必做步骤。
            // 逻辑（datasetButtonTapped / reinstallActiveTrack）保留，需要时可放回这里。
            hstack(startButton, cancelButton),
            exportButton,
            makeSectionTitle(BML.t("Progress", "进度")),
            progressView,
            progressCountLabel,
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

        // 同步一次计划：默认数据集按「开着的条数」跑，避免历史保存的 plan 里没有它而跑空。
        plan[BenchmarkCaseStore.defaultTrack] = enabledCaseCount()
        BenchmarkCaseStore.setPlan(plan)

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
        repLabel.text = "\(repetitions) " + BML.t("rep(s)", "轮")
        cooldownLabel.text = cooldownSec == 0 ? BML.t("off", "不冷却") : "\(cooldownSec) " + BML.t("s", "秒")
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
                self.tokenPicker.isEnabled = !running
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

        // 进度 = 已跑样本 / (case 数 × 轮数)。runner 里 doneCount 按样本累加，
        // totalCount 由 config.totalSamples(caseCount:) 算，含预热样本之外的计量轮。
        Publishers.CombineLatest(runner.$doneCount, runner.$totalCount)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] done, total in
                guard let self = self else { return }
                self.progressView.progress = total > 0 ? Float(done) / Float(total) : 0
                self.progressCountLabel.text = total > 0 ? "\(done) / \(total)" : BML.t("Idle", "未开始")
            }
            .store(in: &cancellables)

        runner.$lastResult
            .receive(on: DispatchQueue.main)
            .sink { [weak self] r in
                guard let self = self, r != nil else { return }
                self.exportButton.isEnabled = true
            }
            .store(in: &cancellables)

        // 输出框改成实时状态：图片预处理 / prefill / decode + 实时速度。
        // 统计报告不再显示在这里，而是落盘成 report_<uuid>.txt。
        runner.$liveLog
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in
                guard let self = self else { return }
                self.resultTextView.text = lines.joined(separator: "\n")
                if !lines.isEmpty {
                    let end = NSRange(location: self.resultTextView.text.count, length: 0)
                    self.resultTextView.scrollRangeToVisible(end)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 动作

    @objc private func repChanged() {
        repetitions = Int(repStepper.value)
        updateStepperLabels()
    }

    @objc private func tokenChanged() {
        let i = max(0, tokenPicker.selectedSegmentIndex)
        decodeTokenLimit = Self.tokenChoices[min(i, Self.tokenChoices.count - 1)]
        updateStepperLabels()
    }

    /// 切语言：写进偏好后整体重建页面（比逐个刷新文案可靠）。
    @objc private func languageChanged() {
        let lang = BenchmarkLocale.allCases[max(0, languagePicker.selectedSegmentIndex)]
        guard lang != BML.language else { return }
        BML.language = lang
        rebuildUI()
    }

    private func rebuildUI() {
        scrollView.removeFromSuperview()
        // 重建前必须清掉旧 target，否则同一个动作会被触发两次。
        for c in [trackHeader, otherTracksHeader, startButton, cancelButton, exportButton,
                  datasetButton, repStepper, cooldownStepper, tokenPicker] {
            c.removeTarget(nil, action: nil, for: .allEvents)
        }
        for sl in trackSliders.values { sl.removeTarget(nil, action: nil, for: .allEvents) }
        for sw in caseSwitches.values { sw.removeTarget(nil, action: nil, for: .allEvents) }
        trackSliders.removeAll()
        trackValueLabels.removeAll()
        caseSwitches.removeAll()

        setupUI()
        refreshDatasetButtonTitle()
        refreshTempLabel()
        updateStepperLabels()
    }

    /// 展开 / 收起数据集卡片。
    @objc private func toggleTrackList() {
        trackCard.isHidden.toggle()
        refreshTrackControls()
    }

    /// 展开 / 收起「其它数据集」。
    @objc private func toggleOtherTracks() {
        otherTracksCard.isHidden.toggle()
        var cfg = otherTracksHeader.configuration ?? UIButton.Configuration.gray()
        cfg.image = UIImage(systemName: otherTracksCard.isHidden ? "chevron.down" : "chevron.up")
        otherTracksHeader.configuration = cfg
    }

    /// 单条 case 的开关。写回后把默认数据集的「本次跑几条」同步成启用条数。
    @objc private func caseSwitchChanged(_ sender: UISwitch) {
        BenchmarkCaseStore.setCaseEnabled(sender.tag, sender.isOn)
        plan[BenchmarkCaseStore.defaultTrack] = enabledCaseCount()
        BenchmarkCaseStore.setPlan(plan)
        refreshTrackControls()
    }

    /// 默认数据集里当前开着几条。
    private func enabledCaseCount() -> Int {
        caseSwitches.values.filter { $0.isOn }.count
    }

    /// 「其它数据集」当前选中的总条数。
    private func otherTrackCount() -> Int {
        BenchmarkCaseStore.bundledTracks
            .filter { $0 != BenchmarkCaseStore.defaultTrack }
            .reduce(0) { $0 + (plan[$1] ?? 0) }
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
        var total = enabledCaseCount()
        for t in BenchmarkCaseStore.bundledTracks where t != BenchmarkCaseStore.defaultTrack {
            let n = plan[t] ?? 0
            total += n
            trackValueLabels[t]?.text = "\(n) / \(BenchmarkCaseStore.trackTotal(t))"
        }
        trackCaseCount = total

        var cfg = trackHeader.configuration ?? UIButton.Configuration.gray()
        cfg.title = total > 0 ? BML.t("Dataset · \(total) case(s)", "数据集 · 共 \(total) 条") : BML.t("Dataset · none", "数据集 · 未选择")
        cfg.image = UIImage(systemName: trackCard.isHidden ? "chevron.down" : "chevron.up")
        trackHeader.configuration = cfg
    }

    /// 给每条 track 一句人话描述（加 track 时一并加）。
    private func trackSummary(_ track: String) -> String {
        switch track {
        case "vision_mix_50":
            return BML.t("25 reviewed + 25 recognition/description/short-answer cases",
                "1B/35B/4.6 已审核 25 条 + 识图/描述/简单题 25 条")
        case "mlperf_llm":
            return BML.t("MLPerf Mobile v6.0 (Tiny-MMLU 100 + Tiny-IFEval 33), text only",
                "MLPerf Mobile v6.0（Tiny-MMLU 100 + Tiny-IFEval 33），纯文本")
        default:
            return BML.t("unknown track", "未知 track")
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
            tempLabel.text = BML.t("Temperature 0 (greedy) ✓ reproducible", "采样温度 0（贪心）✓ 结果可复现")
            tempLabel.textColor = .systemGreen
        } else {
            tempLabel.text =
                BML.t("Temperature \(t) ⚠️ not greedy; benchmark results are not reproducible.\n",
                    "采样温度 \(t) ⚠️ 已不是贪心，跑批数据不可复现。\n") +
                BML.t("Check MTMDParams.temperature default (should be 0.0) and rebuild.",
                    "请检查 MTMDParams.temperature 默认值（应为 0.0）后重新编译。")
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
            progressLabel.text = BML.t("Dataset reinstalled (track=\(BenchmarkCaseStore.activeTrack())): \(summary)\n",
                                     "已重铺数据集（track=\(BenchmarkCaseStore.activeTrack())）：\(summary)\n")
                + BML.t("Edit images or prompts under Documents/benchmark/ in the Files app",
                  "可在「文件」App 的 Documents/benchmark/ 下改图或改提示词")
            refreshDatasetButtonTitle()
        } catch {
            progressLabel.text = "操作失败：\(error.localizedDescription)"
        }
    }

    @objc private func startRun() {
        // 全关时 selectedPlan() 会回落到「默认 track 跑满」，那样等于没生效，先挡掉。
        guard enabledCaseCount() + otherTrackCount() > 0 else {
            progressLabel.text = "没有选择任何 case：默认数据集至少开一条，或在「其它数据集」里把条数调大"
            return
        }
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
