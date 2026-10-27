//
//  L10n+zh.swift
//  MiniCPM-V-demo
//
//  Simplified Chinese (zh-Hans) dictionary for the runtime i18n layer.
//
//  This is the *authoritative* table — when adding a new key, add the
//  zh translation here first, then mirror it in L10n+en.swift. Missing
//  en keys fall back to zh at runtime (see LocalizationManager.string),
//  but the converse is not true: missing zh = missing for everyone.
//

import Foundation

extension LocalizationManager {

    static let zhDict: [String: String] = [

        // MARK: Common

        L.Common.ok:     "确定",
        L.Common.cancel: "取消",
        L.Common.done:   "完成",
        L.Common.confirm: "确认",
        L.Common.gotIt:  "我知道了",
        L.Common.error:  "错误",
        L.Common.tip:    "提示",
        L.Common.about:  "关于",
        L.Common.save:   "保存",
        L.Common.delete: "删除",
        L.Common.saved:  "已保存",
        L.Common.deleted: "已删除",

        // MARK: Settings main page

        L.Settings.title:                "设置",
        L.Settings.sectionMultimodal:    "多模态模型管理",
        L.Settings.sectionLanguageModel: "语言模型管理",
        L.Settings.sectionTts:           "语音合成模型",
        L.Settings.sectionOcr:           "OCR 模型",
        L.Settings.sectionFeature:       "功能设置",
        L.Settings.sectionOther:         "其他设置",

        L.Settings.rowLanguage:          "语言",
        L.Settings.rowLookaheadPrefetchDepth:         "预读专家数",
        L.Settings.rowDspark:            "DSpark 投机解码",
        L.Settings.rowAbout:             "关于我们",
        L.Settings.dsparkHint:           "草稿模型一次起草多个 token、由目标模型整批裁定。开启后预读专家数与窗口**保持不变**（引擎侧四处闸门已修，两者可同时开；可用下面那行「预读专家数」做对照）。注意三点：① 草稿模型（Q8，405 MB）不随主模型下载，打开本开关后会提示下载；② 窗口只覆盖 4 行左右的小内存设备上，需配合 -moeTextOnly 启动（不加载 mmproj），否则「窗口 + 草稿 + mmproj」会超出内存限额被杀；③ 改完要重载模型才生效。",
        L.Settings.dsparkDraftMissingTitle:   "需要下载草稿模型",
        L.Settings.dsparkDraftMissingBody:    "草稿模型不在主模型的完整性检查范围内，缺了不会报错，只会让投机解码静默失效 —— 表现就是「开关打开了但速度没变」。",
        L.Settings.dsparkDraftDownloadAction: "下载",
        L.Settings.lookaheadPrefetchDepthTitle:       "跳层预测 / 预读专家数",
        L.Settings.lookaheadPrefetchDepthMessage:     "用当前层的 hidden 预测下一层会用到哪些专家，提前从盘读入。0 = 关闭（只装载真正用到的专家）。改完下一轮生成生效，不用重载模型。",
        L.Settings.lookaheadPrefetchDepthOff:         "0（关）",
        L.Settings.lookaheadPrefetchDepthHint:        "范围 0–16（每层预测的专家数）。冷启动默认 8。",
        L.Settings.rowCacheWindow:                    "专家缓存（每层槽数 c）",
        L.Settings.cacheWindowTitle:                  "专家缓存：每层槽数 c",
        L.Settings.cacheWindowMessage:                "每层给 MoE 专家缓存的槽位数。一层总共 256 个专家，c 就是缓存其中多少个 —— c 越大命中率越高、读盘越少、生成越快；但窗口是在加载模型时一次性分配的，c 太大可能被系统杀掉，甚至把整机拖进内存压缩而卡死。c=0 关闭整扇窗口，专家每次从盘读。\n改完要重载模型才生效。",
        L.Settings.cacheWindowAuto:                   "默认",
        L.Settings.cacheWindowHint:                   "范围 0 或 8 起（步进 8；0 为关闭窗口）。默认值与上限都按设备分档：16 GB → 默认 128 / 上限 144，12 GB → 48 / 80，8 GB → 24 / 32。实测 168 会把整机卡死。",
        L.Settings.cacheWindowRevertedTitle:          "专家缓存已回退",
        L.Settings.cacheWindowRevertedBody:           "上次把每层槽数设成 c=%@ 后 App 没能完成加载，已自动退回「自动」档。\n换一个更小的值再试。",
        L.Settings.rowSlotBank:                       "专家槽位（slot bank）",
        L.Settings.slotBankTitle:                     "专家槽位：slot bank",
        L.Settings.slotBankMessage:                   "所有层共用的一份 expert 槽位表。一次只驻留 bank 个专家，其余从盘按需读。bank 越大命中越多、生成越快，但常驻内存也越大。\n改完要重载模型才生效。",
        L.Settings.slotBankHint:                      "步进 %d。256 格约 0.5 GiB，不超过旧的每层 32 格方案。",
        L.Settings.rowPrewarm:                        "缓存预热（每层专家数）",
        L.Settings.rowShowPerfSpeed:                  "显示 P/D 速度",
        L.Settings.showPerfSpeedHint:                 "在每条回复底部的工具条上显示本轮 prefill / decode 的 token 速度（与日志里 perf 行同一份数据）。调试和调参时打开，录制演示时关掉。只影响显示，不影响推理。",
        L.Settings.rowLiveTps:                        "实时速度",
        L.Settings.liveTpsHint:                       "开 = 生成过程中在输出框底部实时显示 decode 速度，结束后停在同一位置。关 = 不显示。下一轮生成即生效，不用重载模型。",
        L.Settings.rowOcrLiveTps:                     "OCR实时速度",
        L.Settings.ocrLiveTpsHint:                    "开 = OCR 推理过程中把「Live Output」显示成「Live Output: x.x t/s」。关 = 只显示「Live Output」。下一张图即生效，不用重载模型。",
        L.Settings.rowAppearance:                     "夜间模式",
        L.Settings.appearanceTitle:                   "外观",
        L.Settings.appearanceFollowSystem:            "跟随系统",
        L.Settings.appearanceDark:                    "始终开启",
        L.Settings.appearanceLight:                   "始终关闭",
        L.Settings.prewarmTitle:                      "缓存预热：每层预读专家数",
        L.Settings.prewarmMessage:                    "每轮生成开始时专家缓存是空的。预热会在第一个 token 之前，先把「开头最常用的专家」一次性读进各层缓存（表是离线统计的，偏向更快的首响）。档位 = 每层预读多少个专家，越大命中越好、但首 token 之前要读的也越多（48 档约 1.9 GiB）。\n代价：这笔读盘不与计算重叠，且每轮都会重来一次。改完要重载模型才生效。",
        L.Settings.prewarmOff:                        "关",
        L.Settings.rowStreamingMarkdown:              "实时渲染 Markdown",
        L.Settings.streamingMarkdownHint:             "开启后，模型边生成边套用 Markdown 样式；关闭时保持整段输出完成后再渲染。关闭更稳（生成过程中文字不会因样式重排而抖动）。",

        L.Settings.statusInUse:          "正在使用",

        L.Settings.alertNoWrapper:       "未传入 mtmdWrapperExample，无法初始化下载管理器。",
        L.Settings.alertDeviceUnsupportedTitle: "设备不支持",
        L.Settings.alertDeviceUnsupportedMessageFormat: "%@参数量较大，当前设备内存不足（需 12 GB 以上，当前 %@ GB）。",
        L.Settings.statusInsufficientRAMFormat: "设备内存不足（需 12 GB，当前 %@ GB）",
        L.Settings.alertDefaultModelTitle: "该模型",
        L.Settings.alertModelFallback:   "该模型",

        L.Settings.aboutVersionLabel:    "版本",

        // MARK: Language picker

        L.LanguagePicker.title:   "选择语言",
        L.LanguagePicker.message: "切换后将立即生效，无需重启 app。",

        // MARK: Model detail

        L.ModelDetail.mainButtonOneTapDownload:   "一键下载",
        L.ModelDetail.mainButtonOneTapDownloadV46: "一键下载（约 1.6 GB）",
        L.ModelDetail.mainButtonOneTapDownloadV5:  "一键下载（约 656 MB）",
        L.ModelDetail.mainButtonOneTapDownloadV526: "一键下载（约 1.5 GB）",
        L.ModelDetail.mainButtonOneTapDownloadV47Moe: "一键下载（约 15.6 GB）",
        L.ModelDetail.mainButtonOneTapDownloadV471B:  "一键下载（约 1.8 GB）",
        L.ModelDetail.v47RowMainModel:   "主模型",
        L.ModelDetail.v47RowVisionTower: "视觉塔（mmproj）",
        L.ModelDetail.v47RowExperts:     "专家分片（40 个）",
        L.ModelDetail.mainButtonDownloadingFormat: "下载中 %d%%",
        L.ModelDetail.mainButtonUseThis:          "使用该模型",

        L.ModelDetail.redownloadTitle:    "重新下载",
        L.ModelDetail.redownloadMessage:  "这将删除所有已下载的模型文件和缓存中的临时文件，然后重新下载。确定要继续吗？",
        L.ModelDetail.redownloadA11yLabel: "重新下载",
        L.ModelDetail.redownloadA11yHint:  "删除所有已下载的模型文件并重新下载",
        L.ModelDetail.redownloadHudCleaning: "正在清理文件…",
        L.ModelDetail.redownloadHudCleaned:  "清理完成，可以重新下载",

        L.ModelDetail.alertNoWrapper:     "未传入 mtmdWrapperExample，无法初始化下载管理器。",
        L.ModelDetail.alertAlreadyDownloadedTitle: "模型已下载",
        L.ModelDetail.alertAlreadyDownloadedMessageFormat: "%@ 已经下载完成，无需重复下载",

        L.ModelDetail.toastDownloadSuccessFormat: "%@ 下载成功",
        L.ModelDetail.toastDownloadFailedFormat:  "%@ 下载失败",
        L.ModelDetail.toastSetAsCurrentFormat:    "已设置 %@ 为当前模型",

        // MARK: Download

        L.Download.statusDownloaded:     "已下载",
        L.Download.statusDownloading:    "下载中…",
        L.Download.statusFailed:         "下载失败",
        L.Download.statusNotDownloaded:  "未下载",
        L.Download.statusPaused:         "已暂停",
        L.Download.verifying:            "校验中…",
        L.Download.verifyFailed:         "校验失败",

        L.Download.alertNoSpaceTitle:    "存储空间不足",
        L.Download.alertNoSpaceMessage:  "设备剩余空间不足以下载该模型，请清理后重试。",
        L.Download.alertNetworkErrorTitle: "网络错误",
        L.Download.alertNetworkErrorMessage: "下载失败，请检查网络连接后重试。",

        L.Download.etaCalculating:       "计算中...",
        L.Download.etaHoursMinutesFormat: "%d小时%d分钟",
        L.Download.etaMinutesSecondsFormat: "%d分钟%d秒",
        L.Download.etaSecondsFormat:     "%d秒",
        L.Download.progressFailedSuffix: "下载失败",

        // MARK: Home / Chat

        L.Home.title:                    "MiniCPM",
        L.Home.inputPlaceholder:         "发消息",
        L.Home.liveDecodeSpeed:          "实时解码速度：%.1f t/s",

        L.Home.toolbarSettings:          "设置",
        L.Home.toolbarTutorial:          "教程",
        L.Home.toolbarNewChat:           "新对话",

        L.Home.welcomeTitle:             "你好，我是 MiniCPM",
        L.Home.welcomeSubtitle:          "可以为你解答各类问题，也可以理解图片和视频。",
        L.Home.welcomeTipDownload:       "前往「设置」下载并选择模型",
        L.Home.welcomeTipPickModel:      "请先选择一个模型",

        L.Home.floatingPickPhoto:        "从相册选图",
        L.Home.floatingTakePhoto:        "拍照",
        L.Home.floatingPickVideo:        "从相册选视频",
        L.Home.floatingRecordVideo:      "录像",
        L.Home.floatingRealtime:         "实时理解",

        L.Home.sendButton:               "发送",
        L.Home.stopButton:               "停止",
        L.Home.thinkToggle:              "思考",

        L.Home.statusLoading:            "加载中…",
        L.Home.statusGenerating:         "生成中…",
        L.Home.statusPrefilling:         "处理中…",

        L.Home.actionCopy:               "复制",
        L.Home.actionSave:               "保存",
        L.Home.actionRegenerate:         "重新生成",

        L.Home.alertModelNotLoadedTitle: "模型未加载",
        L.Home.alertModelNotLoadedMessage: "请先到设置页选择并下载一个模型。",
        L.Home.alertOomTitle:            "内存不足",
        L.Home.alertOomMessage:          "当前设备内存吃紧，已自动停止生成。可尝试在设置中切换更小的模型或减少图片切片数。",

        L.Home.toastCopied:              "已复制",
        L.Home.toastSaved:               "已保存到相册",
        L.Home.toastSaveFailed:          "保存失败",

        L.Home.welcomeNoSystemPromptHint: "新对话已开始，无系统提示词",

        L.Home.disclaimer:               "提示：模型回答由 AI 生成，不代表开发者立场，请自行甄别。",
        L.Home.navTitleWithModelFormat:  "%@（当前模型：%@）",
        L.Home.navTitleNoModelFormat:    "%@（请先下载模型）",
        L.Home.hudLoadingModel:          "正在加载模型…\n首次启动需要解析权重，请稍候",
        L.Home.initFailedDownloadFirst:  "初始化失败，请先下载模型",
        L.Home.initDone:                 "初始化完成",

        L.Home.tipEmptyInput:            "请输入内容",
        L.Home.tipPleaseWait:            "请稍等",
        L.Home.tipModelNotReady:         "模型尚未加载完成，请稍候再发送。",
        L.Home.tipImageProcessing:       "图片预处理中，请稍等再点击发送。",
        L.Home.tipPreviousImageProcessing: "上一张图片预处理中，请稍等",
        L.Home.tipPreviousVideoProcessing: "上一个视频还在解析中，请稍等",
        L.Home.tipProcessingWait:        "处理中，请稍等",

        L.Home.perfPrepFormat:           "\t\t预处理耗时：%@s",
        L.Home.perfTimeoutFormat:        "\t\t预处理超时（>%ds）",
        L.Home.perfFailedFormat:         "\t\t预处理失败：%@",
        L.Home.perfSkipped:              "\t\t预处理已跳过",
        L.Home.perfModelNotReady:        "模型尚未加载完成，请稍候",
        L.Home.perfModelLoadedPrefix:    "\t预处理耗时：",
        L.Home.perfVideoFramesFormat:    "\t\t视频抽帧 %d 帧，预处理耗时：%@s",

        L.Home.sliceChangedNowFormat:    "图片切片数已切换为 %@",
        L.Home.sliceSavedNextLoadFormat: "已保存切片数 %@，下次加载模型时生效",

        L.Home.clearChatTitle:           "是否清除对话记录",
        L.Home.clearChatMessage:         "清除后对话记录无法恢复，是否确认清除对话记录？",

        L.Home.toastCancelled:           "已取消",
        L.Home.toastLiked:               "已赞同",
        L.Home.toastDisliked:            "已反对",

        L.Home.thinkProcessLabel:        "思考过程",
        L.Home.thinkInProgressLabel:     "思考中...",

        // MARK: Welcome view (preset questions + subtitle)

        L.Welcome.presetDescribeImage:    "请描述图片中的内容。",
        L.Welcome.presetDescribeTheImage: "Describe the image.",
        L.Welcome.presetBeijingIntro:     "介绍北京",
        L.Welcome.presetSpringPoem:       "帮我写一首关于春天的诗",
        L.Welcome.presetCasePicker:       "基准测试用例（5 题）",
        L.Welcome.presetCaseTitle:        "选择要发送的问题",
        L.Welcome.presetCaseCancel:       "取消",
        L.Welcome.presetCasePolynomial:   "多项式求值",
        L.Welcome.presetMemProbe:         "内存探测",
        L.Welcome.presetMemProbeTitle:    "最大可用内存实测",
        L.Welcome.presetMemProbeRunning:  "测量中…",
        L.Welcome.presetMemProbeHint:     "分块分配并逐页写入，量出本进程实际能吃下多少内存，然后立刻释放。用于给「专家缓存 / 权重 / KV」分预算。\n注意：这个探测会临时占用数 GiB 内存，期间界面可能卡顿，属正常现象。",
        L.Welcome.presetMemProbeClose:    "关闭",
        L.Welcome.presetMemProbeCancel:   "取消",
        L.Welcome.presetCaseInclusion:    "概率容斥",
        L.Welcome.presetCaseParking:      "停车位推理",
        L.Welcome.presetCaseThermo:       "吸放热反应解释",
        L.Welcome.presetCaseMajority:     "多数元素查找",
        L.Welcome.subtitleLanguageOnly:  "让我协助你了解知识、获得灵感、提升效率，我可以进行多轮对话互动，回答你的各种问题。",
        L.Welcome.subtitleMultimodal:    "让我协助你了解知识、获得灵感、提升效率，我可以进行多轮对话与互动、根据图片给出信息并进一步解读。",

        // MARK: Floating action button

        L.Floating.stopGenerating:       "终止生成",
        L.Floating.resumeGenerating:     "继续生成",
        L.Floating.pauseGenerating:      "暂停生成",

        // MARK: Image slice alert

        L.ImageSlice.title:              "图片切片数",
        L.ImageSlice.message:            "切片越多，模型能识别的图片细节越清晰；同时图像 token 更多，回答耗时也越长。\n• 1：单张概览（最快，无切图）\n• 9：MiniCPM-V 模型上限（默认，最清晰）",
        L.ImageSlice.labelMin:           "1 极速",
        L.ImageSlice.labelMax:           "9 最清晰",

        // MARK: Tutorial

        L.Tutorial.title:                "使用教程",
        L.Tutorial.headerTitle:          "MiniCPM-V 4.6 快速入门",
        L.Tutorial.headerSubtitle:       "按下面的步骤即可在手机上离线运行多模态大模型，无需联网即可对话和识图。",
        L.Tutorial.footerDisclaimer:     "提示：模型回答由 AI 生成，不代表开发者立场，请自行甄别。",
        L.Tutorial.pageStart:            "立即体验",

        L.Tutorial.page1Title:           "下载模型",
        L.Tutorial.page1Body:            "首次使用需要下载模型文件，整体约 2.5 GB，建议在 Wi-Fi 环境下进行。\n\n进入「设置 → 模型管理 → MiniCPM-V 4.6」，点击「一键下载」按钮，三个文件会并行下载（主模型、视觉编码器、ANE 加速模块）。下载完成后可在该页面看到「已下载」状态。",
        L.Tutorial.page1Placeholder:     "下载模型示意图",
        L.Tutorial.page2Title:           "选择并加载模型",
        L.Tutorial.page2Body:            "下载完成后，回到模型管理页，点击 MiniCPM-V 4.6 卡片底部的「使用此模型」。\n\n等待加载完成（首次加载需几秒到十几秒，会把模型读入内存），加载成功后会自动返回主界面。",
        L.Tutorial.page2Placeholder:     "选择模型示意图",
        L.Tutorial.page3Title:           "文字 / 图片提问",
        L.Tutorial.page3Body:            "在底部输入框中输入问题后点击发送按钮即可对话。\n\n如需让模型识图，先点击输入框左侧的「图片」按钮选择一张图片，再输入提问内容（例如「请描述这张图片」）。模型会同时理解图像与文字。",
        L.Tutorial.page3Placeholder:     "对话与识图示意图",
        L.Tutorial.page4Title:           "多轮对话与清空",
        L.Tutorial.page4Body:            "同一个会话内，模型会记住前几轮的内容，可以基于上下文继续追问。\n\n点击右上角的垃圾桶图标可以清空当前对话，回到全新的会话状态（也会释放上下文显存）。",
        L.Tutorial.page4Placeholder:     "清空对话示意图",

        L.Tutorial.stepLabelFormat:      "第 %@ 步",
        L.Tutorial.placeholderFormat:    "（%@\n截图待补充）",
        L.Tutorial.stepIndexFormat:      "%@/%@",
        L.Tutorial.next:                 "下一步",
        L.Tutorial.prev:                 "上一步",
        L.Tutorial.skip:                 "跳过",

        // MARK: Camera / Live preview

        L.Camera.title:                  "拍摄",
        L.Camera.permissionTitle:        "需要相机权限",
        L.Camera.permissionMessage:      "请在系统设置中开启相机权限以使用此功能。",
        L.Camera.permissionGoSettings:   "去设置",

        L.Camera.presetQuestionTitle:    "试试这些问题",
        L.Camera.presetQuestion1:        "此刻发生了什么？",
        L.Camera.presetQuestion2:        "视频的背景环境在哪里？",
        L.Camera.presetQuestion3:        "视频中有哪些物体？",
        L.Camera.presetQuestion4:        "视频是在室内还是室外？",

        L.Camera.recordHintHold:         "按住录像",
        L.Camera.recordHintRelease:      "松开结束",
        L.Camera.recordSwitchPhoto:      "拍照",
        L.Camera.recordSwitchVideo:      "录像",

        L.Camera.livePreviewStop:        "停止",
        L.Camera.livePreviewStart:       "开始",

        L.Camera.videoTooLong:           "视频过长，请录制 30 秒以内的视频。",
        L.Camera.videoProcessing:        "视频处理中…",

        L.Camera.modeSingleVideo:        "单视频拍摄",
        L.Camera.modeRealtime:           "实时理解",

        L.Camera.recordUnavailableTitle:   "提示",
        L.Camera.recordUnavailableMessage: "暂时无法拍摄录像",

        L.Camera.liveStreamRestartContext: "为避免上下文超长，请重启会话",
        L.Camera.liveStreamCtxTooLong:     "运行时间过久，超出上下文，请重启进入。",

        // MARK: Realtime

        L.Realtime.title:                "实时理解设置",
        L.Realtime.switchLabel:          "启用实时理解",
        L.Realtime.descriptionBody:      "开启后，相机视频流将实时输入模型并连续回答。",

        L.Realtime.questionOptionLabel:  "问题选项",
        L.Realtime.actualPromptLabel:    "实际 Prompt",
        L.Realtime.questionIntervalLabel: "提问间隔(0-10000ms)",
        L.Realtime.frameSamplingLabel:   "提问抽帧数",
        L.Realtime.deleteAllConfirmMessage: "删除所有已经输入的内容？",

        // MARK: Viewer

        L.Viewer.saveSuccess:            "已保存",
        L.Viewer.saveFailedNoPermission: "保存失败：无相册访问权限",
        L.Viewer.saveFailedGeneric:      "保存失败",

        // MARK: TTS

        L.Tts.title:              "VoxCPM2 语音合成",
        L.Tts.navModelManager:    "模型管理",

        L.Tts.textPlaceholder:    "请输入要合成的文本…",
        L.Tts.defaultPrompt:       "欢迎使用 VoxCPM2 语音合成！这是一段示例文本，点击「生成」按钮即可试听合成效果。",

        L.Tts.labelRefAudio:      "参考音频（可选）",
        L.Tts.btnPresetFemale:    "默认女声",
        L.Tts.btnPresetMale:      "默认男声",
        L.Tts.btnRecord:          "录音",
        L.Tts.btnStopRecord:      "停止录音",
        L.Tts.btnPlayRef:         "试听",
        L.Tts.btnClearRef:        "清除",
        L.Tts.statusRefRecorded:  "录制完成：%.1f 秒 / %d KB",
        L.Tts.statusRecording:    "正在录音…",
        L.Tts.statusPresetLoaded: "已加载预设声音",
        L.Tts.statusNoRef:        "未选择参考音频",

        L.Tts.labelCfg:           "CFG 引导强度",
        L.Tts.labelTimesteps:     "推理步数",
        L.Tts.hintTimestepsHigh:  "注意：步数 > 8 时，手机端生成可能较慢",

        L.Tts.btnGenerate:        "生成",
        L.Tts.btnCancel:          "取消生成",
        L.Tts.statusLoadingModel: "模型加载中…",
        L.Tts.statusGenerating:   "正在生成语音…",
        L.Tts.statusCancelled:    "已取消",
        L.Tts.statusReady:        "就绪",

        L.Tts.toastGenerateDone:  "语音生成完成",
        L.Tts.toastGenerateFailed: "语音生成失败",
        L.Tts.toastPlayFailed:    "播放失败: %@",
        L.Tts.toastCancelled:     "生成已取消",

        L.Tts.alertTextEmpty:     "请输入要合成的文本",
        L.Tts.alertModelMissing:  "缺少模型文件，请先下载 VoxCPM2 模型",
        L.Tts.alertGoDownload:    "前往下载",
        L.Tts.alertRecordPermissionDenied: "无麦克风权限，请在系统设置中开启",
        L.Tts.presetFailed:       "加载预设失败: %@",

        L.Tts.playbackTitle:      "生成结果",
        L.Tts.guide:              "输入文本即可合成语音，支持 30 种语言 + 9 种方言。\nCFG 控制生成质量，推理步数越大音质越佳但速度更慢。",
        L.Tts.subtitle:           "文本转语音 · 语音设计与克隆",

        // MARK: HUD

        L.Download.downloadAll:          "一键下载",
        L.Common.reloading:              "重新加载中…",

        L.HUD.loading:                   "加载中…",
        L.HUD.pleaseWait:                "请稍候…",
        L.HUD.copyFailed:                "复制失败",

        // MARK: OCR

        L.Ocr.placeholder:               "拍照、选图或选择 PDF",
        L.Ocr.liveOutput:                "Live Output",
        L.Ocr.currentArea:               "Current Area",

        L.Ocr.statusInitializing:        "初始化中…",
        L.Ocr.statusLoadingModels:       "加载模型中…",
        L.Ocr.statusModelsMissing:       "OCR 模型未下载，请到设置页下载。",
        L.Ocr.statusNotReady:            "OCR 模型未就绪。",

        L.Ocr.statusPdfOpenFailed:       "无法打开 PDF。",
        L.Ocr.statusPdfNoPages:          "PDF 没有页面。",
        L.Ocr.statusPdfRendering:        "正在渲染第 %d 页…",
        L.Ocr.statusPdfRenderFailed:     "PDF 页面渲染失败。",

        L.Ocr.statusDetectingLayout:     "第 %d/%d 页：正在检测版面…",
        L.Ocr.statusComplete:            "OCR 完成",
        L.Ocr.statusCompletePages:       "OCR 完成（%d/%d 页）",
        L.Ocr.statusFailed:              "OCR 失败：%@",
        L.Ocr.statusCancelled:           "OCR 已取消。",

        L.Ocr.clearTitle:                "清空内容",
        L.Ocr.clearMessage:              "将清除当前图片和 OCR 结果，并重新加载模型，是否继续？",
    ]
}
