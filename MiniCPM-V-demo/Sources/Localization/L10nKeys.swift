//
//  L10nKeys.swift
//  MiniCPM-V-demo
//
//  Hierarchical dot-separated keys, namespaced by enum so callers get
//  IDE autocomplete and the compiler catches typos.
//
//  Convention:
//   - Lowercase, dot-separated path: "settings.section.multimodal".
//   - Top-level enum `L` (short, scans well at call sites).
//   - Sub-enum per module / screen: Settings, Home, Common, …
//   - Each constant's value IS the dictionary key; never duplicated.
//
//  When adding a new key:
//   1. Add a `static let` here in the right sub-enum.
//   2. Add the zh translation to L10n+zh.swift.
//   3. Add the en translation to L10n+en.swift.
//  Missing en falls back to zh (see LocalizationManager.string(forKey:)),
//  so a missed step won't crash, but QA should catch it.
//

import Foundation

public enum L {

    // MARK: - Common reusable strings

    public enum Common {
        public static let ok                 = "common.ok"
        public static let cancel             = "common.cancel"
        public static let done               = "common.done"
        public static let confirm            = "common.confirm"
        public static let gotIt              = "common.gotIt"
        public static let error              = "common.error"
        public static let tip                = "common.tip"
        public static let about              = "common.about"
        public static let save               = "common.save"
        public static let delete             = "common.delete"
        public static let saved              = "common.saved"
        public static let deleted            = "common.deleted"
        public static let reloading          = "common.reloading"
    }

    // MARK: - Settings (main page + sections)

    public enum Settings {
        public static let title              = "settings.title"

        public static let sectionMultimodal  = "settings.section.multimodal"
        public static let sectionLanguageModel = "settings.section.languageModel"
        public static let sectionTts         = "settings.section.tts"
        public static let sectionOcr         = "settings.section.ocr"
        public static let sectionFeature     = "settings.section.feature"
        public static let sectionOther       = "settings.section.other"

        public static let rowLanguage        = "settings.row.language"
        public static let rowLookaheadPrefetchDepth       = "settings.row.lookaheadPrefetchDepth"
        public static let rowDspark          = "settings.row.dspark"
        public static let rowAbout           = "settings.row.about"
        public static let dsparkHint         = "settings.dspark.hint"
        public static let dsparkDraftMissingTitle    = "settings.dspark.draftMissing.title"
        public static let dsparkDraftMissingBody     = "settings.dspark.draftMissing.body"
        public static let dsparkDraftDownloadAction  = "settings.dspark.draftMissing.download"
        public static let lookaheadPrefetchDepthTitle     = "settings.lookaheadPrefetchDepth.title"
        public static let lookaheadPrefetchDepthMessage   = "settings.lookaheadPrefetchDepth.message"
        public static let lookaheadPrefetchDepthOff       = "settings.lookaheadPrefetchDepth.off"
        public static let lookaheadPrefetchDepthHint      = "settings.lookaheadPrefetchDepth.hint"
        public static let rowCacheWindow                  = "settings.row.cacheWindow"
        public static let cacheWindowTitle                = "settings.cacheWindow.title"
        public static let cacheWindowMessage              = "settings.cacheWindow.message"
        public static let cacheWindowAuto                 = "settings.cacheWindow.auto"
        public static let cacheWindowHint                 = "settings.cacheWindow.hint"
        public static let cacheWindowRevertedTitle        = "settings.cacheWindow.reverted.title"
        public static let cacheWindowRevertedBody         = "settings.cacheWindow.reverted.body"
        public static let rowSlotBank                     = "settings.row.slotBank"
        public static let slotBankTitle                   = "settings.slotBank.title"
        public static let slotBankMessage                 = "settings.slotBank.message"
        public static let slotBankHint                    = "settings.slotBank.hint"
        public static let rowPrewarm                      = "settings.row.prewarm"
        public static let rowShowPerfSpeed                = "settings.row.showPerfSpeed"
        public static let showPerfSpeedHint               = "settings.showPerfSpeed.hint"
        public static let rowLiveTps                      = "settings.row.liveTps"
        public static let liveTpsHint                     = "settings.liveTps.hint"
        public static let rowOcrLiveTps                   = "settings.row.ocrLiveTps"
        public static let ocrLiveTpsHint                  = "settings.ocrLiveTps.hint"
        public static let rowAppearance                   = "settings.row.appearance"
        public static let appearanceTitle                 = "settings.appearance.title"
        public static let appearanceFollowSystem          = "settings.appearance.followSystem"
        public static let appearanceDark                  = "settings.appearance.dark"
        public static let appearanceLight                 = "settings.appearance.light"
        public static let prewarmTitle                    = "settings.prewarm.title"
        public static let prewarmMessage                  = "settings.prewarm.message"
        public static let prewarmOff                      = "settings.prewarm.off"
        public static let rowStreamingMarkdown            = "settings.row.streamingMarkdown"
        public static let streamingMarkdownHint           = "settings.streamingMarkdown.hint"

        public static let statusInUse        = "settings.status.inUse"

        // Alerts
        public static let alertNoWrapper     = "settings.alert.noWrapper"
        public static let alertDeviceUnsupportedTitle = "settings.alert.deviceUnsupported.title"
        // Format: "{model} parameter count is too large; current device …"
        // Use String(format:) at the call site.
        public static let alertDeviceUnsupportedMessageFormat = "settings.alert.deviceUnsupported.messageFormat"
        // Format: "device RAM insufficient (needs 12 GB, current {ramGB} GB)"
        public static let statusInsufficientRAMFormat = "settings.status.insufficientRAMFormat"
        public static let alertDefaultModelTitle = "settings.alert.defaultModelTitle"

        // Generic fallback when an alert needs to refer to "this model"
        // because no model title was provided.
        public static let alertModelFallback = "settings.alert.modelFallback"

        // About dialog
        public static let aboutVersionLabel  = "settings.about.versionLabel"
    }

    // MARK: - Language picker action sheet

    public enum LanguagePicker {
        public static let title              = "languagePicker.title"
        public static let message            = "languagePicker.message"
    }

    // MARK: - Model detail (V26 / V4 / V46 / V5 share the bulk of strings)

    public enum ModelDetail {
        // Bottom main button (3-state: needsDownload / downloading / ready)
        public static let mainButtonOneTapDownload = "modelDetail.mainButton.oneTap"
        // V4.6 / V5 surface an estimated total size in the button (~1.6 GB /
        // ~656 MB). Other model detail VCs use the plain
        // `mainButtonOneTapDownload` above.
        public static let mainButtonOneTapDownloadV46 = "modelDetail.mainButton.oneTap.v46"
        public static let mainButtonOneTapDownloadV5  = "modelDetail.mainButton.oneTap.v5"
        public static let mainButtonOneTapDownloadV526 = "modelDetail.mainButton.oneTap.v526"
        public static let mainButtonOneTapDownloadV47Moe = "modelDetail.mainButton.oneTap.v47moe"
        public static let mainButtonOneTapDownloadV471B  = "modelDetail.mainButton.oneTap.v471b"
        // V4.7 detail rows
        public static let v47RowMainModel   = "modelDetail.v47.row.mainModel"
        public static let v47RowVisionTower = "modelDetail.v47.row.visionTower"
        public static let v47RowExperts     = "modelDetail.v47.row.experts"
        // Format with %d for the percent value: "下载中 %d%%" / "Downloading %d%%"
        public static let mainButtonDownloadingFormat = "modelDetail.mainButton.downloadingFormat"
        public static let mainButtonUseThis  = "modelDetail.mainButton.useThis"

        // Top-right "redownload" toolbar item + confirmation alert
        public static let redownloadTitle    = "modelDetail.redownload.title"
        public static let redownloadMessage  = "modelDetail.redownload.message"
        public static let redownloadA11yLabel = "modelDetail.redownload.a11y.label"
        public static let redownloadA11yHint  = "modelDetail.redownload.a11y.hint"
        public static let redownloadHudCleaning = "modelDetail.redownload.hud.cleaning"
        public static let redownloadHudCleaned  = "modelDetail.redownload.hud.cleaned"

        // Alerts
        public static let alertNoWrapper     = "modelDetail.alert.noWrapper"
        public static let alertAlreadyDownloadedTitle = "modelDetail.alert.alreadyDownloaded.title"
        // Format: "%@ has already been downloaded; no need to download again"
        public static let alertAlreadyDownloadedMessageFormat = "modelDetail.alert.alreadyDownloaded.messageFormat"

        // Toasts (HUD text)
        // Format: "%@ downloaded successfully" / "%@ download failed"
        public static let toastDownloadSuccessFormat = "modelDetail.toast.downloadSuccessFormat"
        public static let toastDownloadFailedFormat  = "modelDetail.toast.downloadFailedFormat"
        // Format: "Set %@ as the current model"
        public static let toastSetAsCurrentFormat    = "modelDetail.toast.setAsCurrentFormat"
    }

    // MARK: - Model download manager (user-facing only)

    public enum Download {
        // Status strings shown in the cell's right-side label.
        // Convention here is "已下载/Downloaded" rather than the generic
        // download-manager "下载完成/Download complete" — same idea, but
        // closer to a state-of-affairs phrasing.
        public static let statusDownloaded   = "download.status.downloaded"
        public static let statusDownloading  = "download.status.downloading"
        public static let statusFailed       = "download.status.failed"
        public static let statusNotDownloaded = "download.status.notDownloaded"
        public static let statusPaused       = "download.status.paused"

        public static let verifying          = "download.verifying"
        public static let verifyFailed       = "download.verifyFailed"

        // Disk space alerts
        public static let alertNoSpaceTitle  = "download.alert.noSpace.title"
        public static let alertNoSpaceMessage = "download.alert.noSpace.message"
        public static let alertNetworkErrorTitle = "download.alert.networkError.title"
        public static let alertNetworkErrorMessage = "download.alert.networkError.message"

        // Time-remaining ETA display
        public static let etaCalculating     = "download.eta.calculating"
        public static let etaHoursMinutesFormat = "download.eta.hoursMinutesFormat"  // %d, %d
        public static let etaMinutesSecondsFormat = "download.eta.minutesSecondsFormat"  // %d, %d
        public static let etaSecondsFormat   = "download.eta.secondsFormat"  // %d

        // Progress callback suffix appended to a model display name to form
        // e.g. "MiniCPM-V 4.6 主模型下载失败" / "… download failed"
        public static let progressFailedSuffix = "download.progress.failedSuffix"

        /// Button that starts every pending file of a multi-file model at once.
        public static let downloadAll        = "download.all"
    }

    // MARK: - Home / Chat main page

    public enum Home {
        public static let title              = "home.title"
        public static let inputPlaceholder   = "home.input.placeholder"
        public static let liveDecodeSpeed    = "home.liveDecodeSpeed"

        // Top-right toolbar
        public static let toolbarSettings    = "home.toolbar.settings"
        public static let toolbarTutorial    = "home.toolbar.tutorial"
        public static let toolbarNewChat     = "home.toolbar.newChat"

        // Welcome
        public static let welcomeTitle       = "home.welcome.title"
        public static let welcomeSubtitle    = "home.welcome.subtitle"
        public static let welcomeTipDownload = "home.welcome.tip.download"
        public static let welcomeTipPickModel = "home.welcome.tip.pickModel"

        // Floating actions
        public static let floatingPickPhoto  = "home.floating.pickPhoto"
        public static let floatingTakePhoto  = "home.floating.takePhoto"
        public static let floatingPickVideo  = "home.floating.pickVideo"
        public static let floatingRecordVideo = "home.floating.recordVideo"
        public static let floatingRealtime   = "home.floating.realtime"

        // Inline send / stop
        public static let sendButton         = "home.button.send"
        public static let stopButton         = "home.button.stop"
        public static let thinkToggle        = "home.button.think"

        // Status pills above the input
        public static let statusLoading      = "home.status.loading"
        public static let statusGenerating   = "home.status.generating"
        public static let statusPrefilling   = "home.status.prefilling"

        // Long-press save / copy
        public static let actionCopy         = "home.action.copy"
        public static let actionSave         = "home.action.save"
        public static let actionRegenerate   = "home.action.regenerate"

        // Generic chat-side errors surfaced to the user
        public static let alertModelNotLoadedTitle = "home.alert.modelNotLoaded.title"
        public static let alertModelNotLoadedMessage = "home.alert.modelNotLoaded.message"
        public static let alertOomTitle      = "home.alert.oom.title"
        public static let alertOomMessage    = "home.alert.oom.message"

        // HUD / toast
        public static let toastCopied        = "home.toast.copied"
        public static let toastSaved         = "home.toast.saved"
        public static let toastSaveFailed    = "home.toast.saveFailed"

        // System prompt section header on welcome (shows the hint that
        // the chat will use a fresh context with no system prompt)
        public static let welcomeNoSystemPromptHint = "home.welcome.noSystemPromptHint"

        // Disclaimer banner above the input box
        public static let disclaimer         = "home.disclaimer"

        // Top-of-screen brand-name title with model.
        // Format with %@ for brand name and %@ for model display name.
        public static let navTitleWithModelFormat = "home.navTitle.withModelFormat"
        // Format with %@ for brand name (model not yet downloaded)
        public static let navTitleNoModelFormat   = "home.navTitle.noModelFormat"

        // Loading-model HUD on cold start
        public static let hudLoadingModel    = "home.hud.loadingModel"

        // Init failed (model files missing on disk)
        public static let initFailedDownloadFirst = "home.init.failedDownloadFirst"
        public static let initDone           = "home.init.done"

        // Send-button gating tips
        public static let tipEmptyInput      = "home.tip.emptyInput"
        public static let tipPleaseWait      = "home.tip.pleaseWait"
        public static let tipModelNotReady   = "home.tip.modelNotReady"
        public static let tipImageProcessing = "home.tip.imageProcessing"
        public static let tipPreviousImageProcessing = "home.tip.previousImageProcessing"
        public static let tipPreviousVideoProcessing = "home.tip.previousVideoProcessing"
        public static let tipProcessingWait  = "home.tip.processingWait"

        // Per-image perf log strings rendered as a tail on each cell
        public static let perfPrepFormat     = "home.perf.prepFormat"        // %@ → time
        public static let perfTimeoutFormat  = "home.perf.timeoutFormat"     // %d → seconds
        public static let perfFailedFormat   = "home.perf.failedFormat"      // %@ → reason
        public static let perfSkipped        = "home.perf.skipped"
        public static let perfModelNotReady  = "home.perf.modelNotReady"
        public static let perfModelLoadedPrefix = "home.perf.modelLoadedPrefix"
        public static let perfVideoFramesFormat = "home.perf.videoFramesFormat" // %d frames, %@ time

        // Slice setting toasts
        public static let sliceChangedNowFormat   = "home.slice.changedNowFormat"   // %@ → number
        public static let sliceSavedNextLoadFormat = "home.slice.savedNextLoadFormat" // %@ → number

        // Clear chat confirmation alert
        public static let clearChatTitle     = "home.clearChat.title"
        public static let clearChatMessage   = "home.clearChat.message"

        // Cell toolbar feedback
        public static let toastCancelled     = "home.toast.cancelled"
        public static let toastLiked         = "home.toast.liked"
        public static let toastDisliked      = "home.toast.disliked"

        // <think>...</think> chain-of-thought rendering
        public static let thinkProcessLabel  = "home.think.processLabel"   // 思考过程
        public static let thinkInProgressLabel = "home.think.inProgressLabel" // 思考中...
    }

    // MARK: - Home welcome view (preset questions + subtitle)

    public enum Welcome {
        public static let presetDescribeImage    = "welcome.preset.describeImage"
        // 原版的英文描述图片气泡：点按发送标题本身（不挂长文）。
        public static let presetDescribeTheImage = "welcome.preset.describeTheImage"
        public static let presetBeijingIntro     = "welcome.preset.beijingIntro"
        public static let presetSpringPoem       = "welcome.preset.springPoem"

        // DSpark 基准测试用例选择器（见 MBDSparkBenchPrompt）：气泡上显示本地化短名，
        // 真正发送的是固定英文原文（必须与 Mac 端用例逐字节一致，否则两端速度不可比）。
        public static let presetCasePicker      = "welcome.preset.casePicker"
        public static let presetCaseTitle       = "welcome.preset.case.title"
        public static let presetCaseCancel      = "welcome.preset.case.cancel"
        public static let presetCasePolynomial  = "welcome.preset.case.polynomial"
        // 内存探测按钮（与基准用例同一行，当前隐藏）
        public static let presetMemProbe        = "welcome.preset.memProbe"
        public static let presetMemProbeTitle   = "welcome.preset.memProbe.title"
        public static let presetMemProbeRunning = "welcome.preset.memProbe.running"
        public static let presetMemProbeHint    = "welcome.preset.memProbe.hint"
        public static let presetMemProbeClose   = "welcome.preset.memProbe.close"
        public static let presetMemProbeCancel  = "welcome.preset.memProbe.cancel"
        public static let presetCaseInclusion   = "welcome.preset.case.inclusion"
        public static let presetCaseParking     = "welcome.preset.case.parking"
        public static let presetCaseThermo      = "welcome.preset.case.thermo"
        public static let presetCaseMajority    = "welcome.preset.case.majority"

        // Subtitle on the welcome view, two variants: language-only or
        // multimodal model. We keep them as separate keys (rather than one
        // key with format placeholders) because the wording differs in
        // both Chinese and English.
        public static let subtitleLanguageOnly = "welcome.subtitle.languageOnly"
        public static let subtitleMultimodal   = "welcome.subtitle.multimodal"
    }

    // MARK: - Floating action button (stop / resume / pause generation)

    public enum Floating {
        public static let stopGenerating     = "floating.stopGenerating"
        public static let resumeGenerating   = "floating.resumeGenerating"
        public static let pauseGenerating    = "floating.pauseGenerating"
    }

    // MARK: - Image slice setting alert

    public enum ImageSlice {
        public static let title              = "imageSlice.title"
        public static let message            = "imageSlice.message"
        public static let labelMin           = "imageSlice.label.min"
        public static let labelMax           = "imageSlice.label.max"
    }

    // MARK: - Tutorial

    public enum Tutorial {
        public static let title              = "tutorial.title"
        public static let headerTitle        = "tutorial.header.title"
        public static let headerSubtitle     = "tutorial.header.subtitle"
        public static let footerDisclaimer   = "tutorial.footer.disclaimer"
        public static let pageStart          = "tutorial.page.start"

        // Pages 1..N — keep abstract names so reordering stays sane
        public static let page1Title         = "tutorial.page1.title"
        public static let page1Body          = "tutorial.page1.body"
        public static let page1Placeholder   = "tutorial.page1.placeholder"
        public static let page2Title         = "tutorial.page2.title"
        public static let page2Body          = "tutorial.page2.body"
        public static let page2Placeholder   = "tutorial.page2.placeholder"
        public static let page3Title         = "tutorial.page3.title"
        public static let page3Body          = "tutorial.page3.body"
        public static let page3Placeholder   = "tutorial.page3.placeholder"
        public static let page4Title         = "tutorial.page4.title"
        public static let page4Body          = "tutorial.page4.body"
        public static let page4Placeholder   = "tutorial.page4.placeholder"

        // Page indicator + nav labels
        public static let stepIndexFormat    = "tutorial.stepIndexFormat"  // %@/%@
        public static let stepLabelFormat    = "tutorial.stepLabelFormat"  // %@ (e.g. "STEP 1")
        public static let placeholderFormat  = "tutorial.placeholderFormat" // %@ (e.g. "(下载模型示意图\n截图待补充)")
        public static let next               = "tutorial.next"
        public static let prev               = "tutorial.prev"
        public static let skip               = "tutorial.skip"
    }

    // MARK: - Camera / Live preview

    public enum Camera {
        public static let title              = "camera.title"
        public static let permissionTitle    = "camera.permission.title"
        public static let permissionMessage  = "camera.permission.message"
        public static let permissionGoSettings = "camera.permission.goSettings"

        public static let presetQuestionTitle = "camera.presetQuestion.title"
        public static let presetQuestion1    = "camera.presetQuestion.q1"
        public static let presetQuestion2    = "camera.presetQuestion.q2"
        public static let presetQuestion3    = "camera.presetQuestion.q3"
        public static let presetQuestion4    = "camera.presetQuestion.q4"

        public static let recordHintHold     = "camera.record.hint.hold"
        public static let recordHintRelease  = "camera.record.hint.release"
        public static let recordSwitchPhoto  = "camera.record.switch.photo"
        public static let recordSwitchVideo  = "camera.record.switch.video"

        public static let livePreviewStop    = "camera.live.stop"
        public static let livePreviewStart   = "camera.live.start"

        public static let videoTooLong       = "camera.video.tooLong"
        public static let videoProcessing    = "camera.video.processing"

        // Mode segments at the top of the camera screen
        public static let modeSingleVideo    = "camera.mode.singleVideo"
        public static let modeRealtime       = "camera.mode.realtime"

        // Capture-record alert: "video recording temporarily unavailable"
        public static let recordUnavailableTitle   = "camera.record.unavailable.title"
        public static let recordUnavailableMessage = "camera.record.unavailable.message"

        // Live stream tips
        public static let liveStreamRestartContext = "camera.live.restartContext"
        public static let liveStreamCtxTooLong     = "camera.live.ctxTooLong"
    }

    // MARK: - Realtime understanding

    public enum Realtime {
        public static let title              = "realtime.title"
        public static let switchLabel        = "realtime.switch.label"
        public static let descriptionBody    = "realtime.description.body"

        public static let questionOptionLabel = "realtime.label.questionOption"
        public static let actualPromptLabel  = "realtime.label.actualPrompt"
        public static let questionIntervalLabel = "realtime.label.questionInterval"
        public static let frameSamplingLabel = "realtime.label.frameSampling"

        public static let deleteAllConfirmMessage = "realtime.deleteAll.confirmMessage"
    }

    // MARK: - Image / video viewer + save flows

    public enum Viewer {
        public static let saveSuccess        = "viewer.save.success"
        public static let saveFailedNoPermission = "viewer.save.failedNoPermission"
        public static let saveFailedGeneric  = "viewer.save.failedGeneric"
    }

    // MARK: - TTS (Text-to-Speech / VoxCPM2)

    public enum Tts {
        public static let title              = "tts.title"
        public static let navModelManager    = "tts.nav.modelManager"
        // Input
        public static let textPlaceholder    = "tts.text.placeholder"
        public static let defaultPrompt       = "tts.text.defaultPrompt"

        // Reference audio
        public static let labelRefAudio      = "tts.label.refAudio"
        public static let btnPresetFemale    = "tts.btn.presetFemale"
        public static let btnPresetMale      = "tts.btn.presetMale"
        public static let btnRecord          = "tts.btn.record"
        public static let btnStopRecord      = "tts.btn.stopRecord"
        public static let btnPlayRef         = "tts.btn.playRef"
        public static let btnClearRef        = "tts.btn.clearRef"
        public static let statusRefRecorded  = "tts.status.refRecorded"
        public static let statusRecording    = "tts.status.recording"
        public static let statusPresetLoaded = "tts.status.presetLoaded"
        public static let statusNoRef        = "tts.status.noRef"

        // Parameters
        public static let labelCfg           = "tts.label.cfg"
        public static let labelTimesteps     = "tts.label.timesteps"
        public static let hintTimestepsHigh  = "tts.hint.timestepsHigh"

        // Generation
        public static let btnGenerate        = "tts.btn.generate"
        public static let btnCancel          = "tts.btn.cancel"
        public static let statusLoadingModel = "tts.status.loadingModel"
        public static let statusGenerating   = "tts.status.generating"
        public static let statusCancelled    = "tts.status.cancelled"
        public static let statusReady        = "tts.status.ready"

        // Results
        public static let toastGenerateDone  = "tts.toast.generateDone"
        public static let toastGenerateFailed = "tts.toast.generateFailed"
        public static let toastPlayFailed    = "tts.toast.playFailed"
        public static let toastCancelled     = "tts.toast.cancelled"

        // Errors / alerts
        public static let alertTextEmpty     = "tts.alert.textEmpty"
        public static let alertModelMissing  = "tts.alert.modelMissing"
        public static let alertGoDownload    = "tts.alert.goDownload"
        public static let alertRecordPermissionDenied = "tts.alert.recordPermissionDenied"
        public static let presetFailed       = "tts.alert.presetFailed"

        // Playback
        public static let playbackTitle      = "tts.playback.title"
        public static let guide              = "tts.guide"
        public static let subtitle           = "tts.subtitle"
    }

    // MARK: - Misc HUD / utility messages

    public enum HUD {
        public static let loading            = "hud.loading"
        public static let pleaseWait         = "hud.pleaseWait"
        public static let copyFailed         = "hud.copyFailed"
    }

    // MARK: - OCR page

    public enum Ocr {
        public static let placeholder        = "ocr.placeholder"
        public static let liveOutput         = "ocr.liveOutput"
        public static let currentArea        = "ocr.currentArea"

        public static let statusInitializing = "ocr.status.initializing"
        public static let statusLoadingModels = "ocr.status.loadingModels"
        public static let statusModelsMissing = "ocr.status.modelsMissing"
        public static let statusNotReady     = "ocr.status.notReady"

        public static let statusPdfOpenFailed = "ocr.status.pdfOpenFailed"
        public static let statusPdfNoPages   = "ocr.status.pdfNoPages"
        public static let statusPdfRendering = "ocr.status.pdfRendering"
        public static let statusPdfRenderFailed = "ocr.status.pdfRenderFailed"

        public static let statusDetectingLayout = "ocr.status.detectingLayout"
        public static let statusComplete      = "ocr.status.complete"
        public static let statusCompletePages = "ocr.status.completePages"
        public static let statusFailed        = "ocr.status.failed"
        public static let statusCancelled     = "ocr.status.cancelled"

        public static let clearTitle         = "ocr.clear.title"
        public static let clearMessage       = "ocr.clear.message"
    }
}
