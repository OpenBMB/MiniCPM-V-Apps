//
//  L10n+en.swift
//  MiniCPM-V-demo
//
//  English (en) dictionary for the runtime i18n layer.
//
//  Translation conventions (loose Apple HIG):
//   - Title Case for navigation bar titles, button labels in chrome.
//   - Sentence case for body copy / alert messages / status.
//   - "OK" / "Cancel" / "Done" rather than localised phrasings.
//   - Keep ellipsis as "…" (U+2026) not "..." for status text.
//   - Format placeholders: %@ (NSString) — same as zh dictionary, since
//     the call sites use String(format:) and don't care about language.
//

import Foundation

extension LocalizationManager {

    static let enDict: [String: String] = [

        // MARK: Common

        L.Common.ok:     "OK",
        L.Common.cancel: "Cancel",
        L.Common.done:   "Done",
        L.Common.confirm: "Confirm",
        L.Common.gotIt:  "Got it",
        L.Common.error:  "Error",
        L.Common.tip:    "Note",
        L.Common.about:  "About",
        L.Common.save:   "Save",
        L.Common.delete: "Delete",
        L.Common.saved:  "Saved",
        L.Common.deleted: "Deleted",

        // MARK: Settings main page

        L.Settings.title:                "Settings",
        L.Settings.sectionMultimodal:    "Multimodal Models",
        L.Settings.sectionLanguageModel: "Language Models",
        L.Settings.sectionTts:           "TTS Model",
        L.Settings.sectionOcr:           "OCR Model",
        L.Settings.sectionFeature:       "Features",
        L.Settings.sectionOther:         "Other",

        L.Settings.rowLanguage:          "Language",
        L.Settings.rowLookaheadPrefetchDepth:         "Prefetch experts",
        L.Settings.rowDspark:            "DSpark speculative decoding",
        L.Settings.rowAbout:             "About",
        L.Settings.dsparkHint:           "The draft model proposes several tokens per round; the target model verifies the whole block. While on, the prefetch depth and the window are left **unchanged** (the four engine-side gates that used to block this are fixed, so both can run together; use the \"Prefetch experts\" row above to A/B it). Three things to note: (1) the draft model (Q8, 405 MB) is not part of the main model download -- turning this on will offer to fetch it; (2) on devices whose window only covers ~4 rows, launch with -moeTextOnly (no mmproj), or window + draft + mmproj will exceed the memory limit; (3) reload the model to apply.",
        L.Settings.dsparkDraftMissingTitle:   "Draft model needed",
        L.Settings.dsparkDraftMissingBody:    "The draft model is not covered by the main model's integrity check. If it is missing nothing errors out -- speculative decoding is silently disabled, which just looks like \"turned on but no speedup\".",
        L.Settings.dsparkDraftDownloadAction: "Download",
        L.Settings.lookaheadPrefetchDepthTitle:       "Look-ahead predict / prefetch experts",
        L.Settings.lookaheadPrefetchDepthMessage:     "Predict the next layer's experts from the current layer's hidden state and read them early. 0 = off (load only the experts that fire). Takes effect on the next generation; no model reload.",
        L.Settings.lookaheadPrefetchDepthOff:         "0 (off)",
        L.Settings.lookaheadPrefetchDepthHint:        "Range 0-16 (experts predicted per layer). Cold start default is 8.",
        L.Settings.rowCacheWindow:                    "Expert cache (slots/layer)",
        L.Settings.cacheWindowTitle:                  "Expert cache: slots per layer (c)",
        L.Settings.cacheWindowMessage:                "How many of the 256 MoE experts to cache per layer. Larger c means more hits, less SSD reading and faster generation -- but the window is allocated in one go at model load, so too large can get the app killed by the OS, or even stall the whole device in memory compression. c=0 turns the window off and reads experts from disk every time.\nReload the model to apply.",
        L.Settings.cacheWindowAuto:                   "Default",
        L.Settings.cacheWindowHint:                   "Range 0 or 8+ (step 8; 0 turns the window off). Default and cap depend on device memory: 16 GB -> 128 / 144, 12 GB -> 48 / 80, 8 GB -> 24 / 32. 168 was measured to stall the whole device.",
        L.Settings.cacheWindowRevertedTitle:          "Expert cache reverted",
        L.Settings.cacheWindowRevertedBody:           "The last launch with c=%@ did not finish loading, so it was reverted to Auto.\nTry a smaller value.",
        L.Settings.rowSlotBank:                       "Expert slots (bank size)",
        L.Settings.slotBankTitle:                     "Expert slots: bank size",
        L.Settings.slotBankMessage:                   "One shared table of expert slots used by every layer. Only `bank` experts stay resident; the rest are read from disk on demand. Larger bank means more hits and faster generation, but more resident memory.\nReload the model to apply.",
        L.Settings.slotBankHint:                      "Step %d. 256 slots is about 0.5 GiB, no more than the old 32-slots-per-layer scheme.",
        L.Settings.rowPrewarm:                        "Cache prewarm (experts/layer)",
        L.Settings.rowShowPerfSpeed:                  "Show P/D speed",
        L.Settings.showPerfSpeedHint:                 "Show this turn\'s prefill / decode token rate in the toolbar under each reply (same numbers as the perf log line). Turn on while debugging or tuning, off when recording a demo. Display only - it does not affect inference.",
        L.Settings.rowLiveTps:                        "Live speed",
        L.Settings.liveTpsHint:                       "On = show decode speed at the bottom of the answer while it is generating, and leave the final number there. Off = hide it. Applies on the next reply; no model reload.",
        L.Settings.rowOcrLiveTps:                     "OCR live speed",
        L.Settings.ocrLiveTpsHint:                    "On = the live-output title shows the decode rate while OCR is running. Off = the title stays plain. Applies on the next image; no model reload.",
        L.Settings.rowAppearance:                     "Dark mode",
        L.Settings.appearanceTitle:                   "Appearance",
        L.Settings.appearanceFollowSystem:            "Follow system",
        L.Settings.appearanceDark:                    "Always on",
        L.Settings.appearanceLight:                   "Always off",
        L.Settings.prewarmTitle:                      "Cache prewarm: experts per layer",
        L.Settings.prewarmMessage:                    "The expert cache starts empty each round. Prewarm reads the \"most-used-at-the-start\" experts into every layer's window before the first token (the table is measured offline and weighted toward a faster first token). The level is how many experts per layer -- larger means more hits, but more to read before the first token (~1.9 GiB at 48).\nCost: this read does not overlap compute, and it repeats every round. Reload the model to apply.",
        L.Settings.prewarmOff:                        "Off",
        L.Settings.rowStreamingMarkdown:              "Live Markdown rendering",
        L.Settings.streamingMarkdownHint:             "When on, Markdown styling is applied while the model is still generating. When off, the text stays plain until the whole answer is finished and is rendered once. Off is steadier (text won't shift as styles re-layout mid-stream).",

        L.Settings.statusInUse:          "In Use",

        L.Settings.alertNoWrapper:       "mtmdWrapperExample is not set; cannot initialise the download manager.",
        L.Settings.alertDeviceUnsupportedTitle: "Device Not Supported",
        L.Settings.alertDeviceUnsupportedMessageFormat: "%@ has a large parameter count; this device does not have enough RAM (requires 12 GB or more, current %@ GB).",
        L.Settings.statusInsufficientRAMFormat: "Insufficient RAM (needs 12 GB, current %@ GB)",
        L.Settings.alertDefaultModelTitle: "this model",
        L.Settings.alertModelFallback:   "this model",

        L.Settings.aboutVersionLabel:    "Version",

        // MARK: Language picker

        L.LanguagePicker.title:   "Choose Language",
        L.LanguagePicker.message: "Takes effect immediately, no app restart required.",

        // MARK: Model detail

        L.ModelDetail.mainButtonOneTapDownload:   "Download All",
        L.ModelDetail.mainButtonOneTapDownloadV46: "Download All (~1.6 GB)",
        L.ModelDetail.mainButtonOneTapDownloadV5:  "Download All (~656 MB)",
        L.ModelDetail.mainButtonOneTapDownloadV526: "Download All (~1.5 GB)",
        L.ModelDetail.mainButtonOneTapDownloadV47Moe: "Download All (~15.6 GB)",
        L.ModelDetail.mainButtonOneTapDownloadV471B:  "Download All (~1.8 GB)",
        L.ModelDetail.v47RowMainModel:   "Main model",
        L.ModelDetail.v47RowVisionTower: "Vision tower (mmproj)",
        L.ModelDetail.v47RowExperts:     "Expert shards (40)",
        L.ModelDetail.mainButtonDownloadingFormat: "Downloading %d%%",
        L.ModelDetail.mainButtonUseThis:          "Use This Model",

        L.ModelDetail.redownloadTitle:    "Re-download",
        L.ModelDetail.redownloadMessage:  "This will delete all downloaded model files and cached temporary files, and then download again. Continue?",
        L.ModelDetail.redownloadA11yLabel: "Re-download",
        L.ModelDetail.redownloadA11yHint:  "Delete all downloaded model files and download again",
        L.ModelDetail.redownloadHudCleaning: "Cleaning up files…",
        L.ModelDetail.redownloadHudCleaned:  "Cleanup complete, you can re-download now",

        L.ModelDetail.alertNoWrapper:     "mtmdWrapperExample is not set; cannot initialise the download manager.",
        L.ModelDetail.alertAlreadyDownloadedTitle: "Model Already Downloaded",
        L.ModelDetail.alertAlreadyDownloadedMessageFormat: "%@ has already been downloaded; no need to download again.",

        L.ModelDetail.toastDownloadSuccessFormat: "%@ downloaded successfully",
        L.ModelDetail.toastDownloadFailedFormat:  "%@ download failed",
        L.ModelDetail.toastSetAsCurrentFormat:    "Set %@ as the current model",

        // MARK: Download

        L.Download.statusDownloaded:     "Downloaded",
        L.Download.statusDownloading:    "Downloading…",
        L.Download.statusFailed:         "Download failed",
        L.Download.statusNotDownloaded:  "Not downloaded",
        L.Download.statusPaused:         "Paused",
        L.Download.verifying:            "Verifying…",
        L.Download.verifyFailed:         "Verification failed",

        L.Download.alertNoSpaceTitle:    "Insufficient Storage",
        L.Download.alertNoSpaceMessage:  "There is not enough free space on this device to download the model. Please free up space and try again.",
        L.Download.alertNetworkErrorTitle: "Network Error",
        L.Download.alertNetworkErrorMessage: "Download failed. Please check your network connection and try again.",

        L.Download.etaCalculating:       "Calculating…",
        L.Download.etaHoursMinutesFormat: "%dh %dm",
        L.Download.etaMinutesSecondsFormat: "%dm %ds",
        L.Download.etaSecondsFormat:     "%ds",
        L.Download.progressFailedSuffix: " download failed",

        // MARK: Home / Chat

        L.Home.title:                    "MiniCPM",
        L.Home.inputPlaceholder:         "Send a message",
        L.Home.liveDecodeSpeed:          "Decode speed: %.1f t/s",

        L.Home.toolbarSettings:          "Settings",
        L.Home.toolbarTutorial:          "Tutorial",
        L.Home.toolbarNewChat:           "New Chat",

        L.Home.welcomeTitle:             "Hi, I'm MiniCPM",
        L.Home.welcomeSubtitle:          "I can answer questions and understand images and videos.",
        L.Home.welcomeTipDownload:       "Go to Settings to download and select a model",
        L.Home.welcomeTipPickModel:      "Please choose a model first",

        L.Home.floatingPickPhoto:        "Pick Photo",
        L.Home.floatingTakePhoto:        "Take Photo",
        L.Home.floatingPickVideo:        "Pick Video",
        L.Home.floatingRecordVideo:      "Record Video",
        L.Home.floatingRealtime:         "Live Understanding",

        L.Home.sendButton:               "Send",
        L.Home.stopButton:               "Stop",
        L.Home.thinkToggle:              "Think",

        L.Home.statusLoading:            "Loading…",
        L.Home.statusGenerating:         "Generating…",
        L.Home.statusPrefilling:         "Processing…",

        L.Home.actionCopy:               "Copy",
        L.Home.actionSave:               "Save",
        L.Home.actionRegenerate:         "Regenerate",

        L.Home.alertModelNotLoadedTitle: "Model Not Loaded",
        L.Home.alertModelNotLoadedMessage: "Please go to Settings to choose and download a model first.",
        L.Home.alertOomTitle:            "Low Memory",
        L.Home.alertOomMessage:          "This device is running low on memory; generation has been stopped. Try switching to a smaller model or reducing the image slice count in Settings.",

        L.Home.toastCopied:              "Copied",
        L.Home.toastSaved:               "Saved to Photos",
        L.Home.toastSaveFailed:          "Save failed",

        L.Home.welcomeNoSystemPromptHint: "New chat started, no system prompt",

        L.Home.disclaimer:               "Replies are AI-generated; please verify them.",
        L.Home.navTitleWithModelFormat:  "%@ (current model: %@)",
        L.Home.navTitleNoModelFormat:    "%@ (please download a model first)",
        L.Home.hudLoadingModel:          "Loading model…\nFirst launch needs to parse the weights, please wait",
        L.Home.initFailedDownloadFirst:  "Init failed; please download a model first",
        L.Home.initDone:                 "Init complete",

        L.Home.tipEmptyInput:            "Please enter your question",
        L.Home.tipPleaseWait:            "Please wait",
        L.Home.tipModelNotReady:         "Model is still loading, please wait before sending.",
        L.Home.tipImageProcessing:       "Image preprocessing is in progress; please wait before sending.",
        L.Home.tipPreviousImageProcessing: "Previous image is still preprocessing, please wait",
        L.Home.tipPreviousVideoProcessing: "Previous video is still being parsed, please wait",
        L.Home.tipProcessingWait:        "Processing, please wait",

        L.Home.perfPrepFormat:           "\t\tPreprocess: %@s",
        L.Home.perfTimeoutFormat:        "\t\tPreprocess timeout (>%ds)",
        L.Home.perfFailedFormat:         "\t\tPreprocess failed: %@",
        L.Home.perfSkipped:              "\t\tPreprocess skipped",
        L.Home.perfModelNotReady:        "Model is still loading, please wait",
        L.Home.perfModelLoadedPrefix:    "\tPreprocess: ",
        L.Home.perfVideoFramesFormat:    "\t\tVideo: %d frames, preprocess %@s",

        L.Home.sliceChangedNowFormat:    "Image slice count switched to %@",
        L.Home.sliceSavedNextLoadFormat: "Slice count %@ saved; takes effect next time the model loads",

        L.Home.clearChatTitle:           "Clear Chat History?",
        L.Home.clearChatMessage:         "Once cleared, the chat history cannot be recovered. Are you sure?",

        L.Home.toastCancelled:           "Cancelled",
        L.Home.toastLiked:               "Liked",
        L.Home.toastDisliked:            "Disliked",

        L.Home.thinkProcessLabel:        "Thinking",
        L.Home.thinkInProgressLabel:     "Thinking...",

        // MARK: Welcome view (preset questions + subtitle)

        L.Welcome.presetDescribeImage:    "What's in this photo?",
        L.Welcome.presetDescribeTheImage: "Describe the image.",
        L.Welcome.presetBeijingIntro:     "Beijing intro",
        L.Welcome.presetSpringPoem:       "Write a poem on spring.",
        L.Welcome.presetCasePicker:       "Benchmark cases (5)",
        L.Welcome.presetCaseTitle:        "Pick a question to send",
        L.Welcome.presetCaseCancel:       "Cancel",
        L.Welcome.presetCasePolynomial:   "Polynomial evaluation",
        L.Welcome.presetMemProbe:         "Memory probe",
        L.Welcome.presetMemProbeTitle:    "Max usable memory",
        L.Welcome.presetMemProbeRunning:  "Measuring…",
        L.Welcome.presetMemProbeHint:     "Allocates in chunks and writes every page to find out how much memory this process can actually take, then frees it immediately. Used to split the budget between expert cache / weights / KV.\nNote: the probe temporarily holds several GiB, so the UI may stutter.",
        L.Welcome.presetMemProbeClose:    "Close",
        L.Welcome.presetMemProbeCancel:   "Cancel",
        L.Welcome.presetCaseInclusion:    "Inclusion–exclusion",
        L.Welcome.presetCaseParking:      "Parking-spot logic",
        L.Welcome.presetCaseThermo:       "Exo- vs endothermic",
        L.Welcome.presetCaseMajority:     "Majority element",
        L.Welcome.subtitleLanguageOnly:  "I can help you learn, get inspired, and work faster — ask me anything.",
        L.Welcome.subtitleMultimodal:    "I can help you learn, get inspired, and work faster — and I can also understand images for you.",

        // MARK: Floating action button

        L.Floating.stopGenerating:       "Stop",
        L.Floating.resumeGenerating:     "Resume",
        L.Floating.pauseGenerating:      "Pause",

        // MARK: Image slice alert

        L.ImageSlice.title:              "Image Slice Count",
        L.ImageSlice.message:            "More slices let the model see finer image details; image token count and response latency also rise.\n• 1: Single overview (fastest, no slicing)\n• 9: MiniCPM-V model maximum (default, most detailed)",
        L.ImageSlice.labelMin:           "1 Fastest",
        L.ImageSlice.labelMax:           "9 Sharpest",

        // MARK: Tutorial

        L.Tutorial.title:                "Tutorial",
        L.Tutorial.headerTitle:          "MiniCPM-V 4.6 Quick Start",
        L.Tutorial.headerSubtitle:       "Follow the steps below to run a multimodal large model fully offline on your phone — chat and recognise images without any network.",
        L.Tutorial.footerDisclaimer:     "Note: replies are generated by AI and do not represent the developers' views; please verify them yourself.",
        L.Tutorial.pageStart:            "Get Started",

        L.Tutorial.page1Title:           "Download the Model",
        L.Tutorial.page1Body:            "First-time use requires downloading the model files, ~2.5 GB in total. Wi-Fi is recommended.\n\nGo to Settings → Model Management → MiniCPM-V 4.6 and tap Download All. Three files (main model, vision encoder, ANE acceleration module) will download in parallel. When complete, the page will show \"Downloaded\".",
        L.Tutorial.page1Placeholder:     "Download model illustration",
        L.Tutorial.page2Title:           "Select and Load",
        L.Tutorial.page2Body:            "After downloading, return to the model management page and tap Use This Model on the MiniCPM-V 4.6 card.\n\nWait for it to load (first load takes a few to tens of seconds while weights are read into memory). Once loaded, you'll be returned to the main screen.",
        L.Tutorial.page2Placeholder:     "Model selection illustration",
        L.Tutorial.page3Title:           "Ask with Text / Image",
        L.Tutorial.page3Body:            "Type your question in the input field at the bottom and tap Send to chat.\n\nTo have the model recognise an image, tap the Image button to the left of the input field, pick a photo, then type your question (e.g. \"Please describe this image\"). The model understands both image and text together.",
        L.Tutorial.page3Placeholder:     "Chat & vision illustration",
        L.Tutorial.page4Title:           "Multi-Turn Chat & Clear",
        L.Tutorial.page4Body:            "Within the same session, the model remembers earlier turns and you can ask follow-up questions in context.\n\nTap the trash icon in the top right to clear the current conversation and start fresh (this also releases the context KV-cache).",
        L.Tutorial.page4Placeholder:     "Clear conversation illustration",

        L.Tutorial.stepLabelFormat:      "STEP %@",
        L.Tutorial.placeholderFormat:    "(%@\nscreenshot pending)",
        L.Tutorial.stepIndexFormat:      "%@/%@",
        L.Tutorial.next:                 "Next",
        L.Tutorial.prev:                 "Previous",
        L.Tutorial.skip:                 "Skip",

        // MARK: Camera / Live preview

        L.Camera.title:                  "Camera",
        L.Camera.permissionTitle:        "Camera Access Required",
        L.Camera.permissionMessage:      "Please enable Camera access in system Settings to use this feature.",
        L.Camera.permissionGoSettings:   "Open Settings",

        L.Camera.presetQuestionTitle:    "Try These Questions",
        L.Camera.presetQuestion1:        "What's happening right now?",
        L.Camera.presetQuestion2:        "Where is this video set?",
        L.Camera.presetQuestion3:        "What objects appear in this video?",
        L.Camera.presetQuestion4:        "Is the video indoors or outdoors?",

        L.Camera.recordHintHold:         "Hold to Record",
        L.Camera.recordHintRelease:      "Release to Stop",
        L.Camera.recordSwitchPhoto:      "Photo",
        L.Camera.recordSwitchVideo:      "Video",

        L.Camera.livePreviewStop:        "Stop",
        L.Camera.livePreviewStart:       "Start",

        L.Camera.videoTooLong:           "Video too long; please record under 30 seconds.",
        L.Camera.videoProcessing:        "Processing video…",

        L.Camera.modeSingleVideo:        "Single Video",
        L.Camera.modeRealtime:           "Live Understanding",

        L.Camera.recordUnavailableTitle:   "Note",
        L.Camera.recordUnavailableMessage: "Video recording is currently unavailable.",

        L.Camera.liveStreamRestartContext: "Context is getting too long; please restart the session.",
        L.Camera.liveStreamCtxTooLong:     "The session has been running too long and the context is exhausted. Please restart.",

        // MARK: Realtime

        L.Realtime.title:                "Live Understanding",
        L.Realtime.switchLabel:          "Enable Live Understanding",
        L.Realtime.descriptionBody:      "When enabled, the camera feed is sent to the model in real time for continuous responses.",

        L.Realtime.questionOptionLabel:  "Question Options",
        L.Realtime.actualPromptLabel:    "Actual Prompt",
        L.Realtime.questionIntervalLabel: "Question Interval (0–10000 ms)",
        L.Realtime.frameSamplingLabel:   "Frames Per Question",
        L.Realtime.deleteAllConfirmMessage: "Delete all entered content?",

        // MARK: Viewer

        L.Viewer.saveSuccess:            "Saved",
        L.Viewer.saveFailedNoPermission: "Save failed: no Photos access",
        L.Viewer.saveFailedGeneric:      "Save failed",

        // MARK: TTS

        L.Tts.title:              "VoxCPM2 TTS",
        L.Tts.navModelManager:    "Models",

        L.Tts.textPlaceholder:    "Enter text to synthesize…",
        L.Tts.defaultPrompt:       "Welcome to VoxCPM2 speech synthesis! This is a sample text. Tap Generate to hear the result.",

        L.Tts.labelRefAudio:      "Reference Audio (optional)",
        L.Tts.btnPresetFemale:    "Default Female",
        L.Tts.btnPresetMale:      "Default Male",
        L.Tts.btnRecord:          "Record",
        L.Tts.btnStopRecord:      "Stop",
        L.Tts.btnPlayRef:         "Preview",
        L.Tts.btnClearRef:        "Clear",
        L.Tts.statusRefRecorded:  "Recorded: %.1f s / %d KB",
        L.Tts.statusRecording:    "Recording…",
        L.Tts.statusPresetLoaded: "Preset loaded",
        L.Tts.statusNoRef:        "No reference audio",

        L.Tts.labelCfg:           "CFG Scale",
        L.Tts.labelTimesteps:     "Inference Steps",
        L.Tts.hintTimestepsHigh:  "Note: steps > 8 may be slow on mobile",

        L.Tts.btnGenerate:        "Generate",
        L.Tts.btnCancel:          "Cancel",
        L.Tts.statusLoadingModel: "Loading model…",
        L.Tts.statusGenerating:   "Generating speech…",
        L.Tts.statusCancelled:    "Cancelled",
        L.Tts.statusReady:        "Ready",

        L.Tts.toastGenerateDone:  "Speech generated",
        L.Tts.toastGenerateFailed: "Generation failed",
        L.Tts.toastPlayFailed:    "Playback failed: %@",
        L.Tts.toastCancelled:     "Generation cancelled",

        L.Tts.alertTextEmpty:     "Please enter text to synthesize",
        L.Tts.alertModelMissing:  "Model files missing. Please download VoxCPM2 first.",
        L.Tts.alertGoDownload:    "Go to download",
        L.Tts.alertRecordPermissionDenied: "Microphone access denied. Please enable in Settings.",
        L.Tts.presetFailed:       "Failed to load preset: %@",

        L.Tts.playbackTitle:      "Result",
        L.Tts.guide:              "Enter text to synthesize speech in 30 languages + 9 dialects.\nCFG controls quality; more steps = better but slower.",
        L.Tts.subtitle:           "Text-to-Speech · Voice Design & Cloning",

        // MARK: HUD

        L.Download.downloadAll:          "Download all",
        L.Common.reloading:              "Reloading…",

        L.HUD.loading:                   "Loading…",
        L.HUD.pleaseWait:                "Please wait…",
        L.HUD.copyFailed:                "Copy failed",

        // MARK: OCR

        L.Ocr.placeholder:               "Take a photo, select an image, or choose a PDF",
        L.Ocr.liveOutput:                "Live Output",
        L.Ocr.currentArea:               "Current Area",

        L.Ocr.statusInitializing:        "Initializing…",
        L.Ocr.statusLoadingModels:       "Loading models…",
        L.Ocr.statusModelsMissing:       "OCR models not downloaded. Download them in Settings.",
        L.Ocr.statusNotReady:            "OCR models not ready.",

        L.Ocr.statusPdfOpenFailed:       "Failed to open PDF.",
        L.Ocr.statusPdfNoPages:          "PDF has no pages.",
        L.Ocr.statusPdfRendering:        "Rendering %d page(s)…",
        L.Ocr.statusPdfRenderFailed:     "Failed to render PDF pages.",

        L.Ocr.statusDetectingLayout:     "Page %d/%d: detecting layout…",
        L.Ocr.statusComplete:            "OCR complete",
        L.Ocr.statusCompletePages:       "OCR complete (%d/%d pages)",
        L.Ocr.statusFailed:              "OCR failed: %@",
        L.Ocr.statusCancelled:           "OCR cancelled.",

        L.Ocr.clearTitle:                "Clear content",
        L.Ocr.clearMessage:              "This clears the current image and OCR result, then reloads the model. Continue?",
    ]
}
