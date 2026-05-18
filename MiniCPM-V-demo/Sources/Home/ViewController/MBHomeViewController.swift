//
//  MBHomeViewController.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/6.
//

import UIKit
import SnapKit
import Combine
import AVKit
import PhotosUI
import llama

/// 首页 VC
@objc public class MBHomeViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
        
    // MARK: - properties

    /// 当前正在使用的模型：有语言模型和多模态模型
    var currentUsingModelType: CurrentUsingModelTypeV2 = .Unknown

    // llama mtmd 状态机
    var mtmdWrapperExample: MTMDWrapperExample?
    
    /// 新加的 1 秒响应 1 次的订阅者
    var cancellable: AnyCancellable?
    var cancellables = Set<AnyCancellable>()
    var lastMsg: String = ""
    
    /// subscriber for Combine
    public var dataSubscriber: AnyCancellable?

    /// subscriber for Combine
    public var perfLogSubscriber: AnyCancellable?

    /// 是否有过一轮图文对话，有的话，就可以直接对话，不用再发图了
    var hasImageAndTextConversation = false
    
    /// 是否在插入单张图片到模型中（直接点击「插入图片」按钮，插入一张图片）
    var uploadSingleImageToModel = false
    
    /// 是否在思考中？
    var thinking = false

    /// 顶部导航左侧标题 label（替换原来的 logo 图标，把标题从 navigationItem.title 移到左侧）
    var navTitleLabel: UILabel?
    
    /// 是否是全屏编辑器
    var fullscreenEditor = false
    
    /// 加载多模态模型时 loading 计时、记录加载时长 log 用的一个 timer
    public var logTimer: Timer?
    public var logTimeSecond = 0.0
    
    /// 多图理解时，相应多图模型只要 load 一次即可，不用重复 load
    public var imageLoaded = false
    
    /// 在富文本编辑器模式下，处理多张图片时，要把图片耗时记下来
    var cachedImageEmbeddingPerfLog = [String: String]()
    
    /// 缓存"用户从相册选过的视频"的本地路径，key 是 cell 上挂的 imageURL string，value
    /// 是我们自己 copy 出来的 .mov 路径。
    ///
    /// 早期用 HXPhotoPicker 时，这里存的是 `PhotoAsset`（picker 框架自己的类型，可以
    /// 直接喂给 `PhotoBrowser.show()`）。换到苹果原生 PHPicker 后我们不再持有
    /// PHAsset / PhotoAsset，picker 给的临时 URL 在 dismiss 后会失效，所以
    /// `handleChooseImage` 会把视频 copy 到 caches 目录再把那个路径塞进来。预览时
    /// 直接 `AVPlayerViewController(player: AVPlayer(url:))` 拉起。
    var cachedVideoURLs = [String: URL]()

    /// 如果选中的视频，则 embed 视频时，时长要按视频抽取的帧数来处理（在 +LogTimer.swift 中使用）
    var totalVideoFrameCount: Int = 0
    
    /// 这是实时录像时的帧，然后启动一个 while 循环来依次解析 embed 和 input 到模型里
    var capturedImageArray = [UIImage]()
    
    /// 是否正在实时录像
    var captureVideoFrameStatus = false
    
    /// 实时录像的 VC
    weak var liveStreamVC: SwiftyCameraMainViewController?
    var liveStreamVCShow = false
    
    // 用于显示 LLM 输出的 cell
    var lastLLMCell: MBTextTableViewCell?

    /// 首次模型加载是否已经触发。
    ///
    /// 模型加载放在 viewDidAppear 而不是 viewDidLoad，让 vc 的 view 先完成
    /// 第一帧渲染、被用户看到，再开始抢 CPU 做 mtmd init（mtmd_init_from_file
    /// 内部的 CLIP warmup + CoreML mlmodelc 编译可能用 9-15s）。这样体验上
    /// 是"点开 → 界面立即出现 → HUD 弹出 → 后台加载"，而不是"点开 → 卡
    /// 几秒 → 才出界面"。viewDidAppear 在 push/pop 时会被多次调用，用这个
    /// flag 保证模型加载只触发一次。
    private var didStartInitialModelLoad = false
    
    /// 这是一个列表
    lazy var tableView : UITableView = {
        let tv = UITableView(frame: self.view.bounds, style: .grouped)
        
        tv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 124 + 140, right: 0)

        // 设置一个预估值
        tv.estimatedRowHeight = 34

        tv.backgroundColor = .white
        
        tv.separatorStyle = .none
        
        // 设置数据源和委托对象
        tv.dataSource = self
        tv.delegate = self
        
        // 注册一个标准的 UITableViewCell
        tv.register(MBTextTableViewCell.classForCoder(), forCellReuseIdentifier: "MBTextTableViewCell")
        tv.register(MBImageTableViewCell.classForCoder(), forCellReuseIdentifier: "MBImageTableViewCell")

        // 注册 CustomHeaderView
        tv.register(MBHomeTableViewHeaderView.self, forHeaderFooterViewReuseIdentifier: "MBHomeTableViewHeaderView")
        
        return tv
    }()

    /// 列表对应的数组
    var dataArray = [MBChatModel]()
    
    /// 底部输入框总容器
    lazy var inputContainerView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.mb_color(with: "#F9FAFC")
        return v
    }()
    
    /// 输入框外边的那个蓝色的
    lazy var inputRoundCornerView: UIView = {
        let v = UIView()
        v.backgroundColor = .white
        v.clipsToBounds = true
        v.layer.cornerRadius = 16
        return v
    }()

    /// 免责声明
    lazy var bottomDisclaimerLabel: UILabel = {
        let lb = UILabel()
        lb.text = "提示：模型回答由 AI 生成，不代表开发者立场，请自行甄别。"
        if MBUtils.isDeviceIPad() {
            lb.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        } else {
            lb.font = UIFont.systemFont(ofSize: 11, weight: .regular)
        }
        lb.textColor = UIColor.mb_color(with: "#8A8A8E")
        lb.textAlignment = .center
        lb.lineBreakMode = .byWordWrapping
        
        return lb
    }()
    
    /// 输入框
    public lazy var textInputView: UITextView = {
        let tv = UITextView()
        tv.font = UIFont.systemFont(ofSize: 16)
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        tv.textColor = .black
        tv.backgroundColor = .white
        tv.returnKeyType = .send
        tv.delegate = self
        tv.autoresizingMask = .flexibleHeight
        return tv
    }()
    
    var placeholderLabel = UILabel()

    /// 发送按钮
    lazy var sendButton: UIButton = {
        let btn = UIButton()
        btn.setImage(UIImage(named: "send_icon"), for: .normal)
        btn.addTarget(self, action: #selector(handleSendText), for: .touchUpInside)
        btn.isEnabled = false
        return btn
    }()
    
    /// 选择图片
    lazy var chooseImageButton: UIButton = {
        let btn = UIButton()
        btn.setImage(UIImage(named: "image_picker_icon"), for: .normal)
        btn.addTarget(self, action: #selector(handleChooseImage), for: .touchUpInside)
        return btn
    }()

    /// 录像功能-按钮
    lazy var captureVideoButton: UIButton = {
        let btn = UIButton()
        btn.setImage(UIImage(named: "capture_video_icon"), for: .normal)
        btn.addTarget(self, action: #selector(handleCaptureVideo), for: .touchUpInside)
        return btn
    }()

    /// 临时显示输出用的 output 区域
    lazy var outputLabel: UILabel = {
        let lb = UILabel()
        lb.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        lb.backgroundColor = .white
        lb.textColor = .blue
        lb.textAlignment = .center
        lb.numberOfLines = 0
        lb.lineBreakMode = .byWordWrapping
        
        lb.isHidden = true
        
        return lb
    }()
    
    /// 临时显示输出用的 output image 区域
    lazy var outputImageView: UIImageView = {
        let oi = UIImageView()
        oi.contentMode = .scaleAspectFit
        oi.clipsToBounds = true
        oi.layer.cornerRadius = 4
        oi.isHidden = true
        return oi
    }()
    
    /// 最近一次选中的图片的 url
    var outputImageURL : URL?
    
    /// 选中的图片的大小（KB，MB）
    var outputImageFileSize: UInt64 = 0
    
    // 记录用户输入
    var latestUserInputText = ""
    
    /// 键盘的高度
    var keyboardHeight: CGFloat = 0

    /// 输出时暂停和继续的 popup view
    lazy var floatingActionView: MBFloatingActionView = {
        let v = MBFloatingActionView()
        return v
    }()

    /// 这是个蒙层，输入框进入全屏时，覆盖在顶导上用的
    public lazy var topNavGrayMaskView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.15)
        return v
    }()
    
    // MARK: - view life cycle
    
    public override func viewDidLoad() {
        super.viewDidLoad()

        self.view.backgroundColor = UIColor.mb_color(with: "#F9FAFC")

        // 教程截图后台预热：4 张手机截屏 PNG，UIImage(named:) 首次解码各几十 ms。
        // 在 home VC 一启动就 prewarm，等用户点导航上的"教程"按钮时 UIKit 内置
        // image cache 已经 warm，cell 的 UIImage(named:) 直接 hit (~µs)，转场动画
        // 不再被同步解码挤压。utility QoS 不抢占 init 路径上的 mtmd / Metal 编译。
        MBTutorialContent.prewarmScreenshotsInBackground()

        // 切片 alert + PHPicker 首次拉起的"按了之后停顿一下"延迟根因（详见
        // warmUpSystemPresentations 的 doc comment）：UIKit 系统组件 +
        // PhotoUI.framework + pickerd XPC service 的懒加载。home VC 显示完之后
        // 1.5s 异步触发一次"隐式 present 立刻 dismiss"，让这些子系统提前 warm。
        // 1.5s 延时是为了让位给模型 init 路径（mtmd_init + Metal kernel 编译），
        // 不抢同一时间窗的 main thread。
        warmUpSystemPresentations()

        // 不要把 mtmdWrapperExample 的创建 + sink 注册放在 `Task { ... }` 里。
        // 三个调用本身都是同步立刻返回的（checkMultiModelLoad… 内部用
        // Task.detached），外包一层 Task 反而会把它们推迟到 viewDidLoad 返回
        // 之后的下一个 main actor turn 才执行。此时 vc 还没完全 attach 到
        // window / nav stack，配合 Combine sink `[weak self]` 在 main queue
        // 排队的 initial-value 投递，会触发
        //   `objc[…]: Cannot form weak reference to instance of
        //    MBHomeViewController. It is possible that this object was
        //    over-released, or is in the process of deallocation.`
        // 并引起白屏（杀 app 重启时稳定复现）。改回同步路径，sink 注册时
        // vc 已经 alive 且未进入 dealloc。
        mtmdWrapperExample = MTMDWrapperExample()
        self.subscriberLlamaMessageLog()

        // create all sub views
        setupSubViews()

        // 添加观察者来监听键盘的显示和隐藏事件
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillShow(notification:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillHide(notification:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)

        // 实时录像完成的回调
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(registVideoProcessCompleteNotification(notification:)),
                                               name: NSNotification.Name("video.process.complete"), object: nil)

        // 模型选择变更：用户在设置页 V2.6 / V4 / V4.6 详情页点了"使用该模型"。
        // 这条路径需要强制 reset + reload，否则 didStartInitialModelLoad 一次性
        // 标志会让首次启动失败的"未加载"状态永远固化，用户选完图就出现
        // `[UI]addImage skip: model not loaded yet`。详见 mbModelSelectionChanged 注释。
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleModelSelectionChanged(_:)),
                                               name: .mbModelSelectionChanged, object: nil)

        // 不在这里调 checkMultiModelLoadStatusAndLoadIt —— 推迟到 viewDidAppear
        // 首次回调，让 vc 的 view 先 layout + 显示第一帧，再开始 mtmd init。
        // 见 didStartInitialModelLoad 的注释。
    }

    /// 用户在 V2.6 / V4 / V4.6 详情页点了"使用该模型"，把 wrapper reset 后再 load。
    ///
    /// 不能只判断 multiModelLoadingSuccess，因为切换路径里可能从一个加载好的
    /// 模型切到另一个，wrapper 当前 success 但下次 prefill 走的还是旧 ctx。
    /// 一律 reset + 重置 didStartInitialModelLoad + 立即触发 load。
    @objc private func handleModelSelectionChanged(_ notification: Notification) {
        debugLog("-->> 模型选择已变更，强制 reset + reload wrapper")
        Task { @MainActor in
            await self.mtmdWrapperExample?.reset()
            self.didStartInitialModelLoad = false
            self.checkMultiModelLoadStatusAndLoadIt()
            self.didStartInitialModelLoad = true
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // 更新导航栏标题，确保从设置页返回时能同步最新的模型选择
        updateNavTitle()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // 首次进入时才触发模型加载。push 进设置页再回来、关闭子页面回来
        // 都会再次回调 viewDidAppear，但模型加载只跑一次。
        if !didStartInitialModelLoad {
            didStartInitialModelLoad = true
            checkMultiModelLoadStatusAndLoadIt()
        }
    }

    /// support screen rotate
    #if DEBUG
        // 这个代码在 My Mac(Designed for iPad) 模式下不能正确运行
    
    #else
    
    public override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        // re-calc all cell
        for item in self.dataArray {
            if item.type == "TEXT" {
                item.cellHeight = MBTextTableViewCell.calcCellHeight(data: item, viewWidth: size.width)
            } else if item.type == "IMAGE" {
                item.cellHeight = MBImageTableViewCell.calcCellHeight(data: item, viewWidth: size.width)
            }
        }

        self.tableView.reloadData()
    }
    
    #endif

    /// 销毁时移除观察者
    deinit {

        stopLogTimer()

        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)

        debugLog("\(self) deinit.")
    }
    
    // MARK: - create sub views
    func setupSubViews() {
        
        updateNavTitle()
        
        // create nav bar views
        setupNavBarViews()
                
        // place holder
        setupPlaceholder()
        
        // create chat list view
        setupTableView()
        
        // create input view
        setupInputView();

        // create tmp output view
        setupOutputViews()
        
        // 创建
        setupFloatingActionView()
        
        #if DEBUG
        /*
        let log = MBLLMDB.sharedInstance().loadAllMessages()
        for item in log {
            if let role = item["role"] as? String,
               let content = item["content"] as? String,
               let create_at: String = item["create_at"] as? String,
               let created = Double(create_at) {

                // Create Date object from timestamp
                let date = Date(timeIntervalSince1970: created)
                
                // Create DateFormatter
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                dateFormatter.timeZone = TimeZone.current
                dateFormatter.locale = Locale.current
                
                // Convert Date to formatted string
                let dateString = dateFormatter.string(from: date)

                // 打印本地日志：
                debugLog("-->> 日志：\(role.count), \(content.count), \(dateString.count)")
            }
        }*/
        
        #endif
        
    }
    
    /// 更新顶导标题
    func updateNavTitle() {
        let newTitle: String
        if MBUtils.isDeviceIPad() {
            let lastSelectedModelString = UserDefaults.standard.value(forKey: "current_selected_model") as? String ?? ""
            var modelDisplayedName = ""

            if lastSelectedModelString == "V26MultiModel" {
                modelDisplayedName = MiniCPMModelConst.modelQ4_K_MDisplayedName
            } else if lastSelectedModelString == "V4MultiModel" {
                modelDisplayedName = MiniCPMModelConst.modelv4_Q4_K_M_DisplayedName
            } else if lastSelectedModelString == "V46MultiModel" {
                modelDisplayedName = MiniCPMModelConst.modelv46_DisplayedName
            }

            if !modelDisplayedName.isEmpty {
                newTitle = "MiniCPM-V（当前模型：\(modelDisplayedName)）"
            } else {
                newTitle = "MiniCPM-V（请先下载模型）"
            }
        } else {
            newTitle = "MiniCPM-V"
        }

        // 标题只走左侧 customView label；不设 self.title，否则系统会在中间再画一份导致重复
        self.title = ""
        if let label = navTitleLabel {
            label.text = newTitle
            label.sizeToFit()
        }
    }
    
    func setupNavBarViews() {

        let titleDict: [NSAttributedString.Key : Any] = [NSAttributedString.Key.foregroundColor: UIColor.black]
        self.navigationController?.navigationBar.titleTextAttributes = titleDict

        // 顶导左侧改为标题 label（去掉原来的 home_nav_icon）。
        // 之所以不用 navigationItem.title：右侧已有 3 个按钮，系统会把中间标题挤窄到几乎不可见。
        let titleLabel = UILabel()
        titleLabel.textColor = .black
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.text = self.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.sizeToFit()
        self.navTitleLabel = titleLabel
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(customView: titleLabel)
        
        // 创建一组 UIBarButtonItem
        let settingButton = UIBarButtonItem(image: UIImage(named: "setting_icon"),
                                            style: .plain,
                                            target: self,
                                            action: #selector(settingButtonTapped))
        settingButton.tintColor = .black

        // delete icon
        let deleteButton = UIBarButtonItem(image: UIImage(named: "delete_icon"),
                                           style: .plain,
                                           target: self,
                                           action: #selector(deleteButtonTapped))
        deleteButton.tintColor = UIColor.mb_color(with: "#FF3B30")

        // 教程按钮（使用 SF Symbol，避免新增图片资源）
        let tutorialImage = UIImage(systemName: "questionmark.circle")
        let tutorialButton = UIBarButtonItem(image: tutorialImage,
                                             style: .plain,
                                             target: self,
                                             action: #selector(tutorialButtonTapped))

        // 切图设置按钮（SF Symbol "slider.horizontal.3"，与齿轮区分）
        let sliceImage = UIImage(systemName: "slider.horizontal.3")
        let imageSliceButton = UIBarButtonItem(image: sliceImage,
                                               style: .plain,
                                               target: self,
                                               action: #selector(imageSliceButtonTapped))
        imageSliceButton.tintColor = .black
        tutorialButton.tintColor = .black

        // rightBarButtonItems 从右到左排列：
        //   tutorial(最右) → setting(齿轮) → image-slice(滑条) → delete
        // 把切图按钮放在齿轮和清空之间，对照 Android/HarmonyOS 三端布局保持一致。
        self.navigationItem.rightBarButtonItems = [tutorialButton, settingButton, imageSliceButton, deleteButton]

        // 白色顶导
        self.navigationController?.setNavigationBackgroundColor(UIColor.mb_color(with: "#F9FAFC") ?? .white)

        // 初次安装 nav 时也要把左侧 label 文本填好（viewWillAppear 还未触发）
        updateNavTitle()
    }
    
    func setupTableView() {
        // 添加 UITableView 到当前视图
        tableView.contentInsetAdjustmentBehavior = .never
        self.view.addSubview(tableView)
        tableView.backgroundColor = UIColor.mb_color(with: "#F9FAFC")
        tableView.snp.makeConstraints { make in
            make.top.equalTo(0)
            make.left.right.equalTo(self.view)
            make.bottom.equalTo(self.view.snp.bottom)
        }
    }
    
    func setupInputView() {
        
        var inputViewMargin: CGFloat = 120
        
        if MBUtils.isDeviceIPhone() {
            inputViewMargin = 24
        }

        let tapResignKeyboardGesture = UITapGestureRecognizer(target: self, action: #selector(handleResignKeyboard))
        self.inputContainerView.isUserInteractionEnabled = true
        self.inputContainerView.addGestureRecognizer(tapResignKeyboardGesture)
        self.view.addSubview(self.inputContainerView)
        self.inputContainerView.snp.makeConstraints { make in
            make.left.equalTo(0)
            make.right.equalTo(0)
            make.height.equalTo(130)
            make.bottom.equalTo(self.view.snp.bottom).offset(0)
        }
        
        // 那个蓝色圆角的线框
        self.inputContainerView.addSubview(self.inputRoundCornerView)
        self.inputRoundCornerView.snp.makeConstraints { make in
            make.top.equalTo(self.inputContainerView.snp.top).offset(2)
            make.bottom.equalTo(self.inputContainerView.snp.bottom).offset(-64)
            make.left.equalTo(inputViewMargin)
            make.right.equalTo(-inputViewMargin)
        }
        
        // add shadow
        self.inputRoundCornerView.layer.masksToBounds = false
        self.inputRoundCornerView.layer.shadowColor = UIColor.black.withAlphaComponent(0.05).cgColor
        self.inputRoundCornerView.layer.shadowOpacity = 1
        self.inputRoundCornerView.layer.shadowOffset = CGSize(width: 0, height: 4)
        self.inputRoundCornerView.layer.shadowRadius = 4
        let rc = CGRect(x: -2,
                        y: -2,
                        width: self.view.frame.size.width - inputViewMargin*2 + 4,
                        height: 64 + 4)
        self.inputRoundCornerView.layer.shadowPath = UIBezierPath(rect: rc).cgPath

        // textview 输入框
        self.inputRoundCornerView.addSubview(self.textInputView)
        self.textInputView.snp.makeConstraints { make in
            make.left.equalTo(12)
            make.top.equalTo(16)
            make.bottom.equalTo(-14)
            make.right.equalTo(-173)
        }

        // 发送按钮
        self.inputRoundCornerView.addSubview(self.sendButton)
        self.sendButton.snp.makeConstraints { make in
            make.bottom.equalTo(-14)
            make.width.height.equalTo(40)
            make.right.equalTo(-16)
        }

        // 选择图片 button
        self.inputRoundCornerView.addSubview(self.chooseImageButton)
        self.chooseImageButton.snp.makeConstraints { make in
            make.bottom.equalTo(-14)
            make.width.height.equalTo(40)
            make.right.equalTo(self.sendButton.snp.left).offset(-16)
        }

        // 实时捕获视频 button（实时理解功能暂未调通，暂时隐藏）
        // self.inputRoundCornerView.addSubview(self.captureVideoButton)
        // self.captureVideoButton.snp.makeConstraints { make in
        //     make.bottom.equalTo(-14)
        //     make.width.height.equalTo(40)
        //     make.right.equalTo(self.chooseImageButton.snp.left).offset(-16)
        // }

        /// 免责声明
        self.inputContainerView.addSubview(bottomDisclaimerLabel)
        bottomDisclaimerLabel.snp.makeConstraints { make in
            make.centerX.equalTo(self.inputContainerView)
            make.height.equalTo(14)
            make.top.equalTo(self.inputRoundCornerView.snp.bottom).offset(14)
            make.left.right.equalTo(self.inputContainerView)
        }
    }
        
    /// 创建 uitextview 内嵌的文本区 placeholder view
    func setupPlaceholder() {
        // 创建占位符 UILabel
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = "发消息"
        placeholderLabel.textColor = UIColor.mb_color(with: "#8A8A8E")
        placeholderLabel.font = textInputView.font
        textInputView.addSubview(placeholderLabel)
        placeholderLabel.snp.makeConstraints { make in
            make.left.equalTo(8)
            make.centerY.equalTo(textInputView)
        }
    }
    
    /// 创建输出窗口
    func setupOutputViews() {
        // 输出文本
        self.view.addSubview(self.outputLabel)
        self.outputLabel.snp.makeConstraints { make in
            make.center.equalTo(self.view)
            make.width.height.equalTo(400)
        }
        
        // 输出选中照片
        inputContainerView.addSubview(self.outputImageView)
        outputImageView.snp.makeConstraints { make in
            make.right.equalTo(self.inputRoundCornerView.snp.left).offset(-12)
            make.centerY.equalTo(self.inputRoundCornerView)
            make.width.equalTo(32)
            make.height.equalTo(48)
        }
    }
    
    /// 创建暂停、继续悬浮按钮
    func setupFloatingActionView() {
        view.addSubview(floatingActionView)
        floatingActionView.isHidden = true
        floatingActionView.snp.makeConstraints { make in
            make.centerX.equalTo(self.view)
            make.width.equalTo(140)
            make.height.equalTo(44)
            make.bottom.equalTo(self.inputContainerView.snp.top).offset(-10)
        }
        floatingActionView.onTap = { [weak self] value in
            // 通知状态机取消本次输出
            self?.mtmdWrapperExample?.stopGeneration()
        }
    }
    
    // MARK: - 列表代理及数据源
    
    /// UITableViewDataSource 方法 - 返回 cell 总数
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return dataArray.count
    }
    
    /// 生成指定的 cell
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        if indexPath.row >= dataArray.count {
            return UITableViewCell()
        }
    
        let model = dataArray[indexPath.row]
        
        if model.type == "TEXT" {
            
            if let cell = tableView.dequeueReusableCell(withIdentifier: "MBTextTableViewCell", for: indexPath) as? MBTextTableViewCell {
                cell.selectionStyle = .none
                cell.bindTextWith(data: model)
                // cell toolbar 点击事件
                cell.onTap = { [weak self] model, actionName in
                    self?.cellToolbarClickEvent(model, action: actionName)
                }
                return cell
            }
            
            return UITableViewCell()

        } else if model.type == "IMAGE" {
            
            if let cell = tableView.dequeueReusableCell(withIdentifier: "MBImageTableViewCell", for: indexPath) as? MBImageTableViewCell {
                cell.selectionStyle = .none
                cell.bindImageWith(data: model)
                // 查看大图，而预览视频时，需要的是 [PhotoAsset] 数组
                cell.onTapImageCover = { [weak self] img, imageURLString in
                    if let keyStr = imageURLString,
                        !keyStr.isEmpty,
                       let videoURL = self?.cachedVideoURLs[keyStr] {
                        // 视频用 AVKit 系统播放器预览（取代了之前 HXPhotoPicker.PhotoBrowser）
                        let player = AVPlayer(url: videoURL)
                        let playerVC = AVPlayerViewController()
                        playerVC.player = player
                        playerVC.modalPresentationStyle = .fullScreen
                        self?.present(playerVC, animated: true) {
                            player.play()
                        }
                    } else if imageURLString?.hasSuffix(".mov") == true {
                        if let s = imageURLString, let url = URL(string: s) {
                            // 如果是录像生成的视频，则用 SwiftyCamera 进行预览
                            let videoVC = SwiftyCameraPreviewVideoViewController(videoURL: url)
                            videoVC.modalPresentationStyle = .fullScreen
                            self?.present(videoVC, animated: true)
                        }
                    } else if let img = img {
                        // 创建图片预览器，预览图片
                        let imageVC = MBImageVideoViewController(image: img)
                        self?.present(imageVC, animated: true)
                    }
                }

                return cell
            }

            return UITableViewCell()

        }
        
        return UITableViewCell()
    }
    
    /// 返回 cell 高度
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        
        if indexPath.row < dataArray.count {
            let model = dataArray[indexPath.row]
            // 返回 cell 的高度
            return model.cellHeight
        }

        return 0
    }
    
    /// UITableViewDelegate 方法，点击了指定 cell
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        self.textInputView.resignFirstResponder()
        if indexPath.row < dataArray.count {
            let model = dataArray[indexPath.row]
            if model.type == "IMAGE" {
                // 图片自己有自己的点击事件
                return
            } else if model.type == "TEXT" {
                if model.role == "llm" {
                    // 注意，只有点击 LLM 输出的 文字 cell，则会显示 popup action button
                    if let curCell = tableView.cellForRow(at: indexPath) as? MBTextTableViewCell {
                        // 显示 popup area
                        curCell.showPopupActionWith(show: !model.hasFloatingActionButton)
                    }
                }
            }
        }
        
    }

    // 返回 section header 高度
    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 480
    }
    
    // 配置 section header
    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let headerView = tableView.dequeueReusableHeaderFooterView(withIdentifier: "MBHomeTableViewHeaderView") as! MBHomeTableViewHeaderView
        
        // 引导用的 4 个 tips 点击事件
        headerView.setupTapEvent { [weak self] str in
            self?.placeholderLabel.isHidden = true
            self?.textInputView.text = str
            if let b = self?.sendButton {
                self?.handleSendText(b)
            }
        }

        return headerView
    }

    // MAKR: - TextView 事件
    
    public func textViewDidBeginEditing(_ textView: UITextView) {
        if textView.text == "" {
            placeholderLabel.isHidden = false
            sendButton.isEnabled = false
        } else {
            placeholderLabel.isHidden = true
            sendButton.isEnabled = true
        }
    }
    
    public func textViewDidChange(_ textView: UITextView) {
        if textView.text == "" {
            placeholderLabel.isHidden = false
            sendButton.isEnabled = false
        } else {
            placeholderLabel.isHidden = true
            sendButton.isEnabled = true
        }
    }
    
    public func textViewDidEndEditing(_ textView: UITextView) {
        if textView.text == "" {
            placeholderLabel.isHidden = false
            sendButton.isEnabled = false
        } else {
            placeholderLabel.isHidden = true
            sendButton.isEnabled = true
        }
    }

    // MARK: - 与 llamaState 交互的逻辑
    
    /// 点击「发送」按钮的事件的处理逻辑
    @objc public func handleSendText(_ sender: UIButton) {

        // 收起键盘
        textInputView.resignFirstResponder()

        // 输入框上的文字
        let inputText = textInputView.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 输入框的非空逻辑检查
        if inputText.isEmpty {
            self.showErrorTips("请输入内容")
            return
        }
        
        if thinking {
            // 如果上一次输出不没结束，禁止重复点击
            self.showErrorTips("请稍等")
            return
        }

        // 用户手工点击图片选择器上传了图片，或者在富文本编辑器插入了图片也同时输入了文字
        Task {
            await processImageAndTextMixModeSendLogic()
        }
    }


    // MARK: - 更新 cell
    
    /// 添加一个 文本 cell 到 tableview 里
    func appendTextDataToCellWith(text: String?, role: String?) {
        let textModel = MBChatModel()
        textModel.type = "TEXT"
        textModel.contentText = text
        textModel.role = role
        textModel.msgId = NSUUID().uuidString
        textModel.createTime = NSDate().timeIntervalSince1970 * 1000
        textModel.cellHeight = MBTextTableViewCell.calcCellHeight(data: textModel, viewWidth: self.view.frame.width)
        dataArray.append(textModel)
    }
    
    /// 添加一个 图片 cell 到 tableview 里。若是视频，imageURL 写视频本地路径（同时挂在 cachedVideoURLs 里）。
    func appendImageDataToCellWith(image: UIImage?, imageURL: String? = nil) {
        let imgModel = MBChatModel()
        imgModel.type = "IMAGE"
        imgModel.role = "user"
        imgModel.contentImage = image
        imgModel.msgId = NSUUID().uuidString
        imgModel.createTime = NSDate().timeIntervalSince1970 * 1000
        imgModel.imageURLString = imageURL
        imgModel.cellHeight = MBImageTableViewCell.calcCellHeight(data: imgModel, viewWidth: self.view.frame.width)
        
        // 此处，如果是富文本编辑器模式上传的图片，预处理时间在 cached 中放着
        if let imageURL = imageURL,
            let perflogString = self.cachedImageEmbeddingPerfLog[imageURL],
           !perflogString.isEmpty {
            var perfLog = perflogString
            perfLog = perfLog.replacingOccurrences(of: "Loaded model ", with: "\t预处理耗时：")
            
            var size = "0 KB"
            let imageCount = image?.jpegData(compressionQuality: 1)?.count ?? 0
            if imageCount > 0 {
                if imageCount / 1000 < 1000 {
                    size = String(format: "%.0f KB", ceil(Double(imageCount) / 1000.0))
                } else {
                    size = String(format: "%.0f MB", ceil(Double(imageCount) / 1000.0 / 1000.0))
                }
            }

            imgModel.performLog = "\(Int(image?.size.width ?? 0))x\(Int(image?.size.height ?? 0)) (\(size)) \t\(perfLog)"
        } else {
            imgModel.performLog = nil
        }
        
        dataArray.append(imgModel)
    }
    
    /// 每次输入完，要把列表滚动到归底部
    func tableViewScrollToBottom() {
        // scroll to bottom
        if dataArray.count == 1 {
            tableView.reloadData()
            
            // 计算需要滚动到的位置，确保 footerview 也可见
            let lastRow = dataArray.count - 1
            let lastIndexPath = IndexPath(row: lastRow, section: 0)
            
            // 先滚动到最后一个 cell
            tableView.scrollToRow(at: lastIndexPath, at: .bottom, animated: true)
            
            // 然后额外滚动一些距离，确保 footerview 也可见
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                
                // 获取当前 content offset
                let currentOffset = self.tableView.contentOffset
                
                // 计算额外的滚动距离，确保 footerview 可见
                // 这里假设 footerview 高度约为 50-60 像素（包括间距）
                let extraOffset: CGFloat = 80
                
                // 设置新的 content offset
                let newOffset = CGPoint(x: currentOffset.x, y: currentOffset.y + extraOffset)
                self.tableView.setContentOffset(newOffset, animated: true)
            }
        } else if dataArray.count > 1 {
            tableView.reloadData()
            
            // 计算需要滚动到的位置，确保 footerview 也可见
            let lastRow = dataArray.count - 1
            let lastIndexPath = IndexPath(row: lastRow, section: 0)
            
            // 先滚动到最后一个 cell
            tableView.scrollToRow(at: lastIndexPath, at: .bottom, animated: true)
        }
    }
}

extension MBHomeViewController {
    
    /// 显示错误提示
    func showErrorTips(_ str: String?, delay: TimeInterval = 2) {
        DispatchQueue.main.async {
            let hud = MBHUD.showAdded(to: self.view, animated: true)
            hud.mode = .text
            hud.label.text = str
            hud.hide(animated: true, afterDelay: delay)
        }
    }
}

extension MBHomeViewController {

    /// 把之前已经显示的 cell 上的所有 toolbar 和 popup 都隐藏掉
    func hideAllCellToolbarAndPopup() {
        for item in dataArray {
            if item.role == "llm" {
                item.hasBottomToolbar = false
                item.hasFloatingActionButton = false
                // 重新计算 cell 的高度（因为要隐藏 toolbar）
                item.cellHeight = MBTextTableViewCell.calcCellHeight(data: item, viewWidth: self.view.frame.width)
            }
        }

        self.tableView.reloadData()
    }
    
}
