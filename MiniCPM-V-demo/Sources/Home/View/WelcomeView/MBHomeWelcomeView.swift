//
//  MBHomeWelcomeView.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/8.
//

import Foundation
import UIKit
import SnapKit

/// DSpark 基准测试用例（高加速比 case）。
/// payload 固定为英文原文、不走本地化，必须与基准脚本里的 case 文本逐字节一致
/// （Swift 多行字面量会吃掉闭合前的换行，故显式补 `\n`）；只有菜单短名本地化。
enum MBDSparkBenchPrompt: CaseIterable {
    case inclusionExclusion
    case parking
    case thermo
    case majority
    // 多项式求值在菜单里排最后：手机展示效果不好。
    case polynomial

    /// 选择菜单里的显示名（本地化）。
    var displayName: String {
        switch self {
        case .polynomial:         return L.Welcome.presetCasePolynomial.loc
        case .inclusionExclusion: return L.Welcome.presetCaseInclusion.loc
        case .parking:            return L.Welcome.presetCaseParking.loc
        case .thermo:             return L.Welcome.presetCaseThermo.loc
        case .majority:           return L.Welcome.presetCaseMajority.loc
        }
    }

    /// 实际发给模型的文本（固定英文，与 Mac 端用例逐字节一致）。
    var payload: String {
        switch self {
        case .polynomial:
            return """
            Given that f(x) = 4x^3 - 9x - 14, find the value of f(2).
            """ + "\n"

        case .inclusionExclusion:
            return """
            In a survey conducted at a local high school, preferences for a new school color were measured: 58% of students liked the color blue, 45% preferred green, and 22% liked both colors. If we randomly pick a student from the school, what's the probability that they would like neither blue nor green?
            """ + "\n"

        case .parking:
            return """
            Read the below passage carefully and answer the questions with an explanation:
            At a small company, parking spaces are reserved for the top executives: CEO, president, vice president, secretary, and treasurer with the spaces lined up in that order. The parking lot guard can tell at a glance if the cars are parked correctly by looking at the color of the cars. The cars are yellow, green, purple, red, and blue, and the executives' names are Alice, Bert, Cheryl, David, and Enid.
            * The car in the first space is red.
            * A blue car is parked between the red car and the green car.
            * The car in the last space is purple.
            * The secretary drives a yellow car.
            * Alice's car is parked next to David's.
            * Enid drives a green car.
            * Bert's car is parked between Cheryl's and Enid's.
            * David's car is parked in the last space.
            Question: What is the name of the secretary?
            """ + "\n"

        case .thermo:
            return """
            Please explain the differences between exothermic and endothermic reactions, and include the criteria you used to distinguish between them. Additionally, please provide a real-world example to illustrate your explanation.
            """ + "\n"

        case .majority:
            return """
            Write a function to find the majority element in a given integer array using the Boyer-Moore Voting Algorithm.
            """ + "\n"
        }
    }
}

/// 首页欢迎 view
class MBHomeWelcomeView: UIView {
    /// 点击事件
    public var onTap: ((String?) -> Void)?

    /// 当前是否处于纯文本模型态。`updateForModelType(isTextOnly:)` 调用时缓存，
    /// 切语言时 `refreshTexts()` 据此决定文案；首次 setupView 时按多模态展示。
    private var isTextOnlyState: Bool = false

    lazy var titleLabel: UILabel = {
        let lb = UILabel()
        lb.text = "Welcome to MiniCPM-V"
        lb.font = UIFont.systemFont(ofSize: 26, weight: .semibold)
        lb.textColor = UIColor.mb_color(with: "#333333")
        lb.textAlignment = .center
        return lb
    }()
    
    lazy var descLabel: UILabel = {
        let lb = UILabel()
        lb.font = UIFont.systemFont(ofSize: 10, weight: .regular)
        lb.textColor = UIColor.mb_color(with: "#8A8A8E")
        lb.textAlignment = .center
        lb.lineBreakMode = .byWordWrapping
        lb.numberOfLines = 2
        return lb
    }()
    
    /// tip1
    lazy var tips01ContainerView: MBHomeWelcomeTipsView = {
        let v = MBHomeWelcomeTipsView()
        v.bindWith(icon: UIImage(named: "header_tips1_icon"), title: L.Welcome.presetDescribeImage.loc)
        return v
    }()

    /// tip2：回到原版的英文描述图片（点按即把标题本身发给模型）
    lazy var tips02ContainerView: MBHomeWelcomeTipsView = {
        let v = MBHomeWelcomeTipsView()
        v.bindWith(
            icon: UIImage(named: "header_tips2_icon"),
            title: L.Welcome.presetDescribeTheImage.loc)
        return v
    }()

    /// tip3：DSpark 基准用例选择器。点按弹菜单列出 5 个 case，选中的英文原文交给 `onTap`。
    lazy var tips03ContainerView: MBHomeWelcomeTipsView = {
        let v = MBHomeWelcomeTipsView()
        v.bindWith(icon: UIImage(named: "header_tips4_icon"), title: L.Welcome.presetCasePicker.loc)
        v.onTapAction = { [weak self] in
            self?.presentCasePicker()
        }
        return v
    }()

    /// tip4：内存探测。当前与 tip3 一同隐藏（见 setupView）。
    lazy var tips04ContainerView: MBHomeWelcomeTipsView = {
        let v = MBHomeWelcomeTipsView()
        v.bindWith(icon: UIImage(named: "header_tips1_icon"), title: L.Welcome.presetMemProbe.loc)
        v.onTapAction = { [weak self] in
            self?.presentMemProbe()
        }
        return v
    }()

    /// 弹出基准用例选择菜单。从 keyWindow 往上找最顶层 VC 来 present。
    private func presentCasePicker() {
        guard let root = MBUtils.keyWindow()?.rootViewController else { return }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }

        let sheet = UIAlertController(
            title: L.Welcome.presetCaseTitle.loc,
            message: nil,
            preferredStyle: .actionSheet)

        for benchCase in MBDSparkBenchPrompt.allCases {
            sheet.addAction(UIAlertAction(title: benchCase.displayName, style: .default) { [weak self] _ in
                // 走和 tip1 / tip2 同一条回调：父 VC 会填入输入框并立即发送。
                self?.onTap?(benchCase.payload)
            })
        }
        sheet.addAction(UIAlertAction(title: L.Welcome.presetCaseCancel.loc, style: .cancel))

        // iPad 上 actionSheet 必须给 popover 锚点，否则 present 直接抛异常。
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = tips03ContainerView
            pop.sourceRect = tips03ContainerView.bounds
            pop.permittedArrowDirections = .any
        }

        top.present(sheet, animated: true)
    }

    /// 内存探测：确认 → 后台实测 → 弹窗展示结果。
    private func presentMemProbe() {
        guard let root = MBUtils.keyWindow()?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }

        let confirm = UIAlertController(
            title: L.Welcome.presetMemProbeTitle.loc,
            message: Self.memProbeConfirmMessage(),
            preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: L.Welcome.presetMemProbe.loc, style: .default) { [weak self] _ in
            self?.runMemProbe(from: top)
        })
        confirm.addAction(UIAlertAction(title: L.Welcome.presetMemProbeCancel.loc, style: .cancel))
        top.present(confirm, animated: true)
    }

    /// 探测会分配数 GiB 并逐页写入，必须在后台线程跑。
    private func runMemProbe(from host: UIViewController) {
        let running = UIAlertController(
            title: L.Welcome.presetMemProbeTitle.loc,
            message: L.Welcome.presetMemProbeRunning.loc,
            preferredStyle: .alert)
        host.present(running, animated: true) {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = MBDeviceMemoryProbe.measureMaxUsable()
                DispatchQueue.main.async {
                    running.message = result.report
                    running.addAction(UIAlertAction(title: L.Welcome.presetMemProbeClose.loc, style: .default))
                }
            }
        }
    }

    /// 若上次探测被系统杀掉，本次会把上限夹在上次位置之下，需在确认框里说明。
    private static func memProbeConfirmMessage() -> String {
        var msg = L.Welcome.presetMemProbeHint.loc
        let last = MBDeviceMemoryProbe.lastMemProbeState()
        if last.bytes > 0 && !last.clean {
            let gb = String(format: "%.2f", Double(last.bytes) / 1_073_741_824.0)
            msg += "\n\n上次探测在 \(gb) GiB 处被系统杀掉（未跑完），本次会停在该位置之下。"
        }
        return msg
    }
    
    
    // 初始化方法，通过代码创建视图实例时会调用此方法
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    // 初始化方法，通过 Interface Builder 创建视图实例时会调用此方法
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupView()
    }
    
    // 设置视图和其子视图的布局和样式
    private func setupView() {

        // 原版尺寸：iPad 280 / iPhone 180，两个气泡左右分开。
        var bubbleWidth: CGFloat = 280
        if MBUtils.isDeviceIPhone() {
            bubbleWidth = 180
        }
        let viewMargin: CGFloat = 14

        addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.centerX.equalTo(self)
            make.height.equalTo(28)
        }
        
        let para = NSMutableParagraphStyle()
        para.maximumLineHeight = 20
        para.minimumLineHeight = 20
        para.lineSpacing = 1
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.mb_color(with: "#8A8A8E") ?? .gray,
            .font: UIFont.systemFont(ofSize: 14),
            .paragraphStyle: para
        ]
        let text = L.Welcome.subtitleMultimodal.loc
        descLabel.attributedText = NSAttributedString(string: text, attributes: attributes)
        addSubview(descLabel)
        self.descLabel.snp.makeConstraints { make in
            make.centerX.equalTo(self)
            make.top.equalTo(titleLabel.snp.bottom).offset(6)
            if MBUtils.isDeviceIPad() {
                make.left.equalTo(160)
                make.right.equalTo(-160)
            } else {
                make.left.equalTo(24)
                make.right.equalTo(-24)
            }
            make.height.equalTo(44)
        }

        addSubview(tips01ContainerView)
        addSubview(tips02ContainerView)
        // tips03 / tips04 当前隐藏：不加入层级（只 addSubview 不给约束会让图标在零尺寸
        // 视图下溢出）。恢复时把下面两行 addSubview 与 setupView 末尾的约束一起放回。
        //   addSubview(tips03ContainerView)
        //   addSubview(tips04ContainerView)

        tips01ContainerView.snp.makeConstraints { make in
            if MBUtils.isDeviceIPad() {
                make.right.equalTo(self.snp.centerX).offset(-viewMargin)
            } else {
                make.left.equalTo(12)
            }
            make.top.equalTo(self.descLabel.snp.bottom).offset(25)
            make.height.equalTo(56)
            make.width.equalTo(bubbleWidth)
        }

        tips02ContainerView.snp.makeConstraints { make in
            if MBUtils.isDeviceIPad() {
                make.left.equalTo(tips01ContainerView.snp.right).offset(viewMargin * 2)
            } else {
                make.right.equalTo(-12)
            }
            make.top.equalTo(self.descLabel.snp.bottom).offset(25)
            make.height.equalTo(56)
            make.width.equalTo(bubbleWidth)
        }

        // 与上面两个按钮一同隐藏（视图高 240pt，放不下第四行）。
        //   let halfGap: CGFloat = 12
        //   tips03ContainerView.snp.makeConstraints { make in
        //       make.left.equalTo(halfGap)
        //       make.right.equalTo(self.snp.centerX).offset(-halfGap / 2)
        //       make.top.equalTo(tips01ContainerView.snp.bottom).offset(12)
        //       make.height.equalTo(56)
        //   }
        //   tips04ContainerView.snp.makeConstraints { make in
        //       make.left.equalTo(self.snp.centerX).offset(halfGap / 2)
        //       make.right.equalTo(-halfGap)
        //       make.top.equalTo(tips03ContainerView)
        //       make.height.equalTo(56)
        //   }
    }
    
    public func setupTapEvent(_ tapImp : ((String?) -> Void)? ) {
        self.onTap = tapImp
        
        tips01ContainerView.onTap = self.onTap
        tips02ContainerView.onTap = self.onTap
    }

    /// 根据模型类型切换欢迎卡片内容
    public func updateForModelType(isTextOnly: Bool) {
        self.isTextOnlyState = isTextOnly
        applyTexts()
    }

    /// 切语言后由父 VC 调用刷新文案。
    public func refreshTexts() {
        applyTexts()
    }

    private func applyTexts() {
        if isTextOnlyState {
            titleLabel.text = "Welcome to MiniCPM"
            tips01ContainerView.bindWith(
                icon: UIImage(named: "header_tips1_icon"),
                title: L.Welcome.presetSpringPoem.loc)
            tips02ContainerView.bindWith(
                icon: UIImage(named: "header_tips3_icon"),
                title: "Explain AI in brief.")
        } else {
            titleLabel.text = "Welcome to MiniCPM-V"
            tips01ContainerView.bindWith(
                icon: UIImage(named: "header_tips1_icon"),
                title: L.Welcome.presetDescribeImage.loc)
            tips02ContainerView.bindWith(
                icon: UIImage(named: "header_tips2_icon"),
                title: L.Welcome.presetDescribeTheImage.loc)
        }

        let para = NSMutableParagraphStyle()
        para.maximumLineHeight = 20
        para.minimumLineHeight = 20
        para.lineSpacing = 1
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.mb_color(with: "#8A8A8E") ?? .gray,
            .font: UIFont.systemFont(ofSize: 14),
            .paragraphStyle: para
        ]
        let desc = isTextOnlyState
            ? L.Welcome.subtitleLanguageOnly.loc
            : L.Welcome.subtitleMultimodal.loc
        descLabel.attributedText = NSAttributedString(string: desc, attributes: attributes)

        // 第三行气泡的标题跟着切语言（菜单里那 5 个短名每次弹出时现取）。
        tips03ContainerView.bindWith(
            icon: UIImage(named: "header_tips4_icon"),
            title: L.Welcome.presetCasePicker.loc)
        // 同一行右半边：内存探测。纯文本/多模态两态都显示 —— 它是诊断入口，与模型无关。
        tips04ContainerView.bindWith(
            icon: UIImage(named: "header_tips1_icon"),
            title: L.Welcome.presetMemProbe.loc)
    }
}
