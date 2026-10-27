//
//  OcrEngine.swift
//  MiniCPM-V-demo
//
//  OCR engine — state-machine driven wrapper over LayoutBridge + OcrBridge.
//  Singleton, @MainActor, ObservableObject.
//

import Foundation
import Combine
import UIKit

/// OCR engine state machine
public enum OcrState: Equatable {
    case uninitialized
    case loadingLayoutModel
    case loadingOcrModel
    case ready
    case processing(String)       // current block description
    case error(String)

    public static func == (lhs: OcrState, rhs: OcrState) -> Bool {
        switch (lhs, rhs) {
        case (.uninitialized, .uninitialized),
             (.loadingLayoutModel, .loadingLayoutModel),
             (.loadingOcrModel, .loadingOcrModel),
             (.ready, .ready):
            return true
        case (.processing(let a), .processing(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// A detected layout block ready for OCR
public struct LayoutBlock: Sendable {
    public let label: String
    public let x1, y1, x2, y2: Float
    public let score: Float
    public let order: Int
    public let cropImage: UIImage?
}

/// OCR engine singleton
@MainActor
public class OcrEngine: ObservableObject {

    // MARK: - Singleton

    @MainActor public static let shared = OcrEngine()
    private init() {}

    // MARK: - Published state

    @Published public var state: OcrState = .uninitialized

    /// Current crop image being OCR'd — drives live preview UI.
    /// nonisolated(unsafe): written from serialQueue (background), read via Combine on main.
    @Published nonisolated(unsafe) public var liveCropImage: UIImage? = nil
    /// Streaming token output for the current crop — drives live preview UI.
    /// nonisolated(unsafe): read-modify-write (+=) from serialQueue, which would race
    /// under @MainActor isolation and cause lost accumulation.
    @Published nonisolated(unsafe) public var liveCropStream: String = ""
    /// Decode t/s text for the crop currently generating. Empty when the switch is off.
    @Published nonisolated(unsafe) public var liveDecodeSpeed: String = ""
    /// Crop files behind each `![image]()` in the assembled markdown, in order.
    /// The markdown string stays `![image]()`; the result view uses this to draw the crop.
    public var imagePreviewSlots: [(index: Int, label: String)] = []

    /// Monotonically increasing generation counter — async flush blocks capture
    /// the value at dispatch time and drop stale writes when a new image is started.
    nonisolated(unsafe) private var liveGeneration: Int = 0

    // MARK: - Cancellation

    /// Set to true when the user presses the trash button to abort ongoing OCR.
    /// Checked between crops and between tokens in the generation loop.
    /// Non-isolated so serialQueue can read it without actor hopping.
    nonisolated(unsafe) private var isCancelled = false

    // MARK: - Private

    private let serialQueue = DispatchQueue(label: "com.minicpm.ocr.engine", qos: .userInitiated)

    private var layoutCtx:  OpaquePointer?
    private var ocrCtx:     OpaquePointer?
    private var isLayoutLoaded = false
    private var isOcrLoaded    = false

    // MARK: - Model paths

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var llmPath: String {
        documentsDirectory().appendingPathComponent(MiniCPMModelConst.ocr_LLMFileName).path
    }

    private var mmprojPath: String {
        documentsDirectory().appendingPathComponent(MiniCPMModelConst.ocr_MMProjFileName).path
    }

    private var layoutOnnxPath: String {
        documentsDirectory().appendingPathComponent(MiniCPMModelConst.ocr_LayoutFileName).path
    }

    /// Check if all required model files exist on disk.
    public func modelsExist() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: llmPath) &&
               fm.fileExists(atPath: mmprojPath) &&
               fm.fileExists(atPath: layoutOnnxPath)
    }

    /// Load layout model AND OCR model (blocking serial).
    public func loadModels() async {
        guard state != .loadingLayoutModel, state != .loadingOcrModel else { return }
        guard modelsExist() else {
            state = .error("OCR model files missing. Please download in Settings.")
            return
        }

        state = .loadingLayoutModel
        let layoutLoaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            serialQueue.async { [weak self] in
                guard let self = self else { continuation.resume(returning: false); return }
                if self.isLayoutLoaded { continuation.resume(returning: true); return }
                let ptr = layout_init(self.layoutOnnxPath)
                if let ptr = ptr {
                    self.layoutCtx = OpaquePointer(ptr)
                    self.isLayoutLoaded = true
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }

        guard layoutLoaded else {
            state = .error("Failed to load PP-DocLayout3 layout model.")
            return
        }

        state = .loadingOcrModel
        let ocrLoaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            serialQueue.async { [weak self] in
                guard let self = self else { continuation.resume(returning: false); return }
                if self.isOcrLoaded { continuation.resume(returning: true); return }

                var params = ocr_params_t()
                // Overview + 9 slices at 4x is 2560 image tokens; table stops at 8192.
                params.n_ctx      = 12288
                params.n_threads  = 4
                params.n_ubatch   = 512
                params.temperature = 0.01
                params.use_gpu    = true
                params.warmup     = true
                params.max_slice_nums = 9

                let ptr = ocr_init(self.llmPath, self.mmprojPath, &params)
                if let ptr = ptr {
                    self.ocrCtx = OpaquePointer(ptr)
                    self.isOcrLoaded = true
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }

        if ocrLoaded {
            state = .ready
        } else {
            state = .error("Failed to load OCR model.")
        }
    }

    // MARK: - Layout detection

    /// Run PP-DocLayout3 layout detection on an image.
    /// Returns detected layout blocks sorted by position.
    public func detectLayout(image: UIImage) async throws -> [LayoutBlock] {
        guard isLayoutLoaded, let ctx = layoutCtx else {
            state = .error("Layout model not loaded")
            throw OcrError.layoutNotLoaded
        }

        // Convert UIImage to RGB888 bytes. Must bake EXIF orientation first:
        // phone photos keep a landscape pixel buffer + `.right` flag; drawing
        // `cgImage` would feed layout/crops a 90°-rotated page. PDF pages are
        // already `.up` so this is a no-op there.
        let oriented = image.mb_orientedUp()
        guard let cgImage = oriented.cgImage else { throw OcrError.invalidImage }
        let width  = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixelData,
                                      width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw OcrError.invalidImage
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Strip alpha → interleaved RGB
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3]     = pixelData[i * 4]
            rgb[i * 3 + 1] = pixelData[i * 4 + 1]
            rgb[i * 3 + 2] = pixelData[i * 4 + 2]
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[LayoutBlock], Error>) in
            serialQueue.async { [weak self] in
                guard let self = self, let c = self.layoutCtx else {
                    continuation.resume(throwing: OcrError.layoutNotLoaded); return
                }
                var dets: UnsafeMutablePointer<layout_detection_t>? = nil
                var count: Int32 = 0

                let ret = rgb.withUnsafeBufferPointer { buf in
                    layout_detect(UnsafeMutableRawPointer(c), buf.baseAddress, Int32(width), Int32(height), 0.3, &dets, &count)
                }

                guard ret == 0, let d = dets, count > 0 else {
                    continuation.resume(returning: [])
                    return
                }

                var raw: [OcrLayoutCrop.RawBox] = []
                let detArray = UnsafeBufferPointer(start: d, count: Int(count))
                for det in detArray {
                    let labelName = OcrDefaultPrompts.labelIdToName[Int(det.label_id)] ?? "text"
                    raw.append(OcrLayoutCrop.RawBox(
                        label: labelName, classId: Int(det.label_id), score: det.score,
                        x1: Double(det.x1), y1: Double(det.y1),
                        x2: Double(det.x2), y2: Double(det.y2)))
                }
                free(d)
                // Filter, rectangle crop, then merge. Order is the index in the
                // merged list, including blocks whose image was folded away.
                let blocks = OcrLayoutCrop.layoutBlocks(from: raw, image: cgImage)
                continuation.resume(returning: blocks)
            }
        }
    }

    // MARK: - Crop recognition

    /// Recognize a single crop image with the given prompt.
    /// Uses ocr_prefill_image + ocr_prefill_text + ocr_loop so that cancellation
    /// is checked between tokens, allowing the user to abort mid-generation.
    public func recognizeCrop(cropImage: UIImage, prompt: String, maxTokens: Int = 4096,
                               onToken: ((String) -> Void)? = nil) async throws -> String {
        guard isOcrLoaded, let ctx = ocrCtx else {
            throw OcrError.ocrNotLoaded
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempPath = tempDir.appendingPathComponent("ocr_crop_\(UUID().uuidString).png").path
        guard let data = cropImage.pngData() else {
            throw OcrError.invalidImage
        }
        try data.write(to: URL(fileURLWithPath: tempPath))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        // Use async dispatch so the main actor is not blocked during generation.
        // This lets Combine deliver .processing("OCR x/y") state updates to the UI.
        return try await withCheckedThrowingContinuation { continuation in
            serialQueue.async { [weak self] in
                guard let self = self, let c = self.ocrCtx else {
                    continuation.resume(throwing: OcrError.ocrNotLoaded); return
                }
                ocr_clean_kv_cache(UnsafeMutableRawPointer(c))

                if ocr_prefill_image(UnsafeMutableRawPointer(c), tempPath) != 0 {
                    continuation.resume(throwing: OcrError.recognitionFailed); return
                }
                if ocr_prefill_text(UnsafeMutableRawPointer(c), prompt, "user") != 0 {
                    continuation.resume(throwing: OcrError.recognitionFailed); return
                }

                var result = ""
                var speedSamples: [(tokens: Int32, ms: Double)] = []
                var lastSpeedFlush = Date.distantPast
                var speedVisible = false
                let generation = self.liveGeneration
                let publishSpeed: (String) -> Void = { text in
                    DispatchQueue.main.async {
                        guard self.liveGeneration == generation else { return }
                        self.liveDecodeSpeed = text
                    }
                }
                for _ in 0..<maxTokens {
                    if self.isCancelled {
                        continuation.resume(throwing: OcrError.cancelled)
                        return
                    }
                    var tok = ocr_loop(UnsafeMutableRawPointer(c))
                    if tok.text != nil {
                        let tokenStr = String(cString: tok.text!)
                        result += tokenStr
                        onToken?(tokenStr)
                        ocr_string_free(tok.text!)
                    }
                    if MiniCPMV47Const.ocrLiveTpsEnabled() {
                        let perf = ocr_decode_perf_peek(UnsafeMutableRawPointer(c))
                        if speedSamples.last?.tokens != perf.decode_tokens, perf.decode_tokens > 0 {
                            speedSamples.append((perf.decode_tokens, perf.decode_ms))
                            while speedSamples.count > 13 {
                                speedSamples.removeFirst()
                            }
                        }
                        let now = Date()
                        if now.timeIntervalSince(lastSpeedFlush) >= 0.05 || tok.is_complete != 0 {
                            lastSpeedFlush = now
                            if let oldest = speedSamples.first, speedSamples.count > 1,
                               let newest = speedSamples.last {
                                let dTokens = Double(newest.tokens - oldest.tokens)
                                let dMs = newest.ms - oldest.ms
                                if dTokens > 0, dMs > 0 {
                                    let rate = dTokens / (dMs / 1000.0)
                                    speedVisible = true
                                    publishSpeed(String(format: "%.1f t/s", rate))
                                }
                            }
                        }
                    } else if speedVisible {
                        speedSamples.removeAll()
                        speedVisible = false
                        publishSpeed("")
                    }
                    if tok.is_complete != 0 { break }
                    if tok.error_code != 0 {
                        continuation.resume(throwing: OcrError.recognitionFailed)
                        return
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Directory holding per-crop PNGs used by the live preview.
    /// Caches rather than Documents: these are throwaway render artifacts.
    static var cropPreviewDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ocr_preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches
    }

    /// Full recognition pipeline

    public func recognize(fullImage: UIImage) async throws -> String {
        guard isLayoutLoaded, isOcrLoaded else {
            throw OcrError.notReady
        }

        isCancelled = true  // signal any in-flight generation to exit
        // Barrier on serialQueue so old generation loop has a chance to see the cancel
        // and exit before we reset for the new image.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            serialQueue.async { continuation.resume() }
        }
        isCancelled = false
        liveGeneration += 1
        let generation = liveGeneration
        liveCropStream = ""
        liveCropImage = nil
        liveDecodeSpeed = ""
        imagePreviewSlots = []
        state = .processing("Detecting layout...")

        var pageImage = fullImage
        var blocks: [LayoutBlock]
        do {
            blocks = try await detectLayout(image: pageImage)
        } catch OcrError.noLayoutDetected {
            blocks = []
        }

        // 页面可能是横向拍的，或者整页转了 90 度。版面框竖长就说明文字在竖着排。
        // 只在这种可疑情况下才试其他方向，正向页面不付额外代价。
        if OcrUpright.shouldRetry(blocks),
           let fixed = await OcrUpright.best(pageImage, current: blocks) {
            pageImage = fixed.0
            blocks = fixed.1
        }

        guard !blocks.isEmpty else {
            state = .ready
            throw OcrError.noLayoutDetected
        }

        var ocrBlocks: [OcrMarkdownUtils.OcrBlock] = []
        let totalBlocks = blocks.count

        for (idx, block) in blocks.enumerated() {
            // Check cancellation before each crop
            if isCancelled {
                self.liveCropImage = nil
                self.liveCropStream = ""
                self.liveDecodeSpeed = ""
                state = .error("Cancelled")
                throw OcrError.cancelled
            }

            let elem = OcrDefaultPrompts.promptFor(label: block.label)
            if elem.skip {
                // VLM skipped. Keep the merge-list order. assembleMarkdown emits
                // ![image]() for image, and for an empty chart or seal.
                // Preview loads this PNG by index and label.
                let cropName = "ocr_crop_\(idx)_\(block.label).png"
                if let cropImg = block.cropImage,
                   let cropData = cropImg.pngData() {
                    let cropPath = OcrEngine.cropPreviewDirectory.appendingPathComponent(cropName)
                    try? cropData.write(to: cropPath)
                }
                if block.label == "image" || block.label == "header_image"
                    || block.label == "footer_image"
                    || block.label == "chart" || block.label == "seal" {
                    imagePreviewSlots.append((index: idx, label: block.label))
                }
                ocrBlocks.append(OcrMarkdownUtils.OcrBlock(
                    label: block.label,
                    content: "",
                    order: block.order,
                    x1: block.x1, y1: block.y1,
                    x2: block.x2, y2: block.y2,
                    score: block.score
                ))
                continue
            }
            guard let cropImg = block.cropImage else { continue }

            state = .processing("OCR \(idx + 1)/\(totalBlocks): \(block.label)")
            let cropName = "ocr_crop_\(idx)_\(block.label).png"
            if let cropData = block.cropImage?.pngData() {
                let cropPath = OcrEngine.cropPreviewDirectory.appendingPathComponent(cropName)
                try? cropData.write(to: cropPath)
            }

            // Set live preview state — dispatch each token batch directly
            self.liveCropImage = cropImg
            if idx > 0 {
                let g = generation
                DispatchQueue.main.async {
                    guard self.liveGeneration == g else { return }
                    self.liveCropStream += "\n\n"
                }
            }

            let rawContent = try await recognizeCrop(cropImage: cropImg,
                                                      prompt: elem.prompt,
                                                      maxTokens: elem.maxTokens,
                                                      onToken: { token in
                let t = token
                let g = generation
                DispatchQueue.main.async {
                    guard self.liveGeneration == g else { return }
                    self.liveCropStream += t
                }
            })

            // classify on the raw string, then postprocess. Mixed-formula is
            // judged on that raw string, before postprocess rewrites it.
            let recognized = OcrMarkdownUtils.classifyEngineText(rawContent)
            let mixed = block.label == "inline_formula"
                && OcrMarkdownUtils.hasMixedInlineFormulaContent(recognized)
            let cleaned = OcrMarkdownUtils.postprocessContent(recognized,
                                                               outputFormat: elem.outputFormat,
                                                               label: block.label)

            ocrBlocks.append(OcrMarkdownUtils.OcrBlock(
                label: block.label,
                content: cleaned,
                order: block.order,
                x1: block.x1, y1: block.y1,
                x2: block.x2, y2: block.y2,
                score: block.score,
                inlineFormulaMixed: mixed
            ))
        }

        // Clear live preview state after all crops are processed
        self.liveCropImage = nil
        self.liveCropStream = ""
        self.liveDecodeSpeed = ""

        // normalize, split, dedupe, then assemble. Order keeps merge-list gaps.
        let normalized = OcrMarkdownUtils.normalizeAndDedupe(ocrBlocks)
        let markdown = OcrMarkdownUtils.assembleMarkdown(blocks: normalized)
        state = .ready
        return markdown
    }

    // MARK: - Destroy

    public func destroy() {
        isCancelled = true
        // Queue cleanup behind any in-flight generation loop.
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            if let c = self.ocrCtx {
                ocr_free(UnsafeMutableRawPointer(c))
                self.ocrCtx = nil
            }
        }
        isOcrLoaded = false
        if let c = layoutCtx {
            layout_free(UnsafeMutableRawPointer(c))
            layoutCtx = nil
            isLayoutLoaded = false
        }
        state = .uninitialized
    }
}

// MARK: - Crop / merge
//
// Rectangle crop, then overlap filter and merge. A block folded into a
// neighbour keeps its slot but has no image, and is not returned.

enum OcrLayoutCrop {
    struct RawBox {
        var label: String
        var classId: Int
        var score: Float
        var x1, y1, x2, y2: Double
    }

    private struct Block {
        var label: String
        var classId: Int
        var score: Float
        var box: [Double]
        var image: UIImage?
    }

    private static let nonMerge: Set<String> = [
        "image", "header_image", "footer_image", "chart", "seal", "table"
    ]

    static func layoutBlocks(from raw: [RawBox], image: CGImage) -> [LayoutBlock] {
        let filtered = filterOverlap(raw)
        let cropped = crop(filtered, image: image)
        let merged = merge(cropped)
        var out: [LayoutBlock] = []
        for (order, block) in merged.enumerated() {
            guard let cropImage = block.image else { continue }
            out.append(LayoutBlock(
                label: block.label,
                x1: Float(block.box[0]), y1: Float(block.box[1]),
                x2: Float(block.box[2]), y2: Float(block.box[3]),
                score: block.score, order: order, cropImage: cropImage))
        }
        return out
    }

    private static func filterOverlap(_ raw: [RawBox]) -> [RawBox] {
        let boxes = raw.filter { $0.label != "reference" }
        if boxes.isEmpty { return [] }
        var dropped = Set<Int>()
        for i in boxes.indices {
            let w = boxes[i].x2 - boxes[i].x1
            let h = boxes[i].y2 - boxes[i].y1
            if w < 6 || h < 6 {
                dropped.insert(i)
                continue
            }
            for j in (i + 1)..<boxes.count {
                if dropped.contains(i) || dropped.contains(j) { continue }
                let ov = smallOverlap(boxes[i], boxes[j])
                let li = boxes[i].label
                let lj = boxes[j].label
                if li == "inline_formula" || lj == "inline_formula" {
                    if ov.ratio > 0.5 {
                        if li == "inline_formula" { dropped.insert(i) }
                        if lj == "inline_formula" { dropped.insert(j) }
                        continue
                    }
                }
                if ov.ratio > 0.7 {
                    if ov.areaI >= ov.areaJ { dropped.insert(j) }
                    else { dropped.insert(i) }
                }
            }
        }
        return boxes.enumerated().compactMap { dropped.contains($0.offset) ? nil : $0.element }
    }

    private static func smallOverlap(_ a: RawBox, _ b: RawBox) -> (ratio: Double, areaI: Double, areaJ: Double) {
        let iw = max(0, min(a.x2, b.x2) - max(a.x1, b.x1))
        let ih = max(0, min(a.y2, b.y2) - max(a.y1, b.y1))
        let ia = iw * ih
        let areaI = abs((a.x2 - a.x1) * (a.y2 - a.y1))
        let areaJ = abs((b.x2 - b.x1) * (b.y2 - b.y1))
        let smaller = min(areaI, areaJ)
        return (smaller > 0 ? ia / smaller : 0, areaI, areaJ)
    }

    private static func crop(_ boxes: [RawBox], image: CGImage) -> [Block] {
        return boxes.map { box in
            let xmin = Int(box.x1)
            let ymin = Int(box.y1)
            let xmax = Int(box.x2)
            let ymax = Int(box.y2)
            let rect = CGRect(x: xmin, y: ymin, width: max(0, xmax - xmin), height: max(0, ymax - ymin))
            let crop = image.cropping(to: rect).map { UIImage(cgImage: $0, scale: 1, orientation: .up) }
            return Block(label: box.label, classId: box.classId, score: box.score,
                         box: [box.x1, box.y1, box.x2, box.y2], image: crop)
        }
    }

    private static func unionOverlap(_ a: [Double], _ b: [Double]) -> Double {
        let iw = max(0, min(a[2], b[2]) - max(a[0], b[0]))
        let ih = max(0, min(a[3], b[3]) - max(a[1], b[1]))
        let ia = iw * ih
        let a1 = max(0, (a[2] - a[0]) * (a[3] - a[1]))
        let a2 = max(0, (b[2] - b[0]) * (b[3] - b[1]))
        let ref = a1 + a2 - ia
        return ref > 0 ? ia / ref : 0
    }

    private static func projectionOverlapX(_ a: [Double], _ b: [Double]) -> Double {
        let overlap = min(a[2], b[2]) - max(a[0], b[0])
        if overlap <= 0 { return 0 }
        let ref = max(a[2], b[2]) - min(a[0], b[0])
        return ref > 0 ? overlap / ref : 0
    }

    private static func pixelSize(_ image: UIImage) -> (Int, Int) {
        if let cg = image.cgImage { return (cg.width, cg.height) }
        return (Int(image.size.width * image.scale), Int(image.size.height * image.scale))
    }

    private static func mergeImages(_ images: [UIImage], aligns: [String]) -> UIImage {
        if images.count <= 1 { return images[0] }
        var offsets = [Int](repeating: 0, count: images.count)
        var mergedW = pixelSize(images[0]).0
        for i in 1..<images.count {
            let img2W = pixelSize(images[i]).0
            let stepW = max(mergedW, img2W)
            let align = aligns[i - 1]
            let shift: Int
            let place: Int
            if align == "center" {
                shift = (stepW - mergedW) / 2
                place = (stepW - img2W) / 2
            } else if align == "right" {
                shift = stepW - mergedW
                place = stepW - img2W
            } else {
                shift = 0
                place = 0
            }
            for k in 0..<i { offsets[k] += shift }
            offsets[i] = place
            mergedW = stepW
        }
        let totalH = images.reduce(0) { $0 + pixelSize($1).1 }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: mergedW, height: totalH), format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: mergedW, height: totalH))
            var y = 0
            for (i, image) in images.enumerated() {
                let (w, h) = pixelSize(image)
                image.draw(in: CGRect(x: offsets[i], y: y, width: w, height: h))
                y += h
            }
        }
    }

    private static func merge(_ blocks: [Block]) -> [Block] {
        if blocks.isEmpty { return [] }
        var toMerge: [(Int, Block)] = []
        var fixed: [Int: Block] = [:]
        for (idx, block) in blocks.enumerated() {
            if nonMerge.contains(block.label) { fixed[idx] = block }
            else { toMerge.append((idx, block)) }
        }

        func aligned(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 5 }
        func alignment(_ bbox: [Double], _ prev: [Double]) -> String {
            if aligned(bbox[0], prev[0]) { return "left" }
            if aligned(bbox[2], prev[2]) { return "right" }
            return "center"
        }
        func overlapsFixed(bi: Int, pi: Int) -> Bool {
            let pb = blocks[pi].box
            let bb = blocks[bi].box
            let span = [min(pb[0], bb[0]), min(pb[1], bb[1]), max(pb[2], bb[2]), max(pb[3], bb[3])]
            for (oi, ob) in blocks.enumerated() {
                if oi == bi || oi == pi || !nonMerge.contains(ob.label) { continue }
                if unionOverlap(span, ob.box) > 0 { return true }
            }
            return false
        }

        var groups: [([Int], [String])] = []
        var curIdx: [Int] = []
        var curAlign: [String] = []
        for (i, item) in toMerge.enumerated() {
            if curIdx.isEmpty {
                curIdx = [item.0]
                curAlign = []
                continue
            }
            let prev = toMerge[i - 1]
            let prevBox = prev.1.box
            let box = item.1.box
            let iouH = projectionOverlapX(box, prevBox)
            let isCross = iouH == 0
                && item.1.label == "text" && item.1.label == prev.1.label
                && box[0] > prevBox[2] && box[1] < prevBox[3]
                && (box[0] - prevBox[2]) < max(prevBox[2] - prevBox[0], box[2] - box[0]) * 0.3
            let isUp = iouH > 0
                && (item.1.label == "text" || item.1.label == "vertical_text")
                && item.1.label == prev.1.label
                && box[3] >= prevBox[1]
                && abs(box[1] - prevBox[3]) < max(prevBox[3] - prevBox[1], box[3] - box[1]) * 0.5
                && (aligned(box[0], prevBox[0]) != aligned(box[2], prevBox[2]))
                && overlapsFixed(bi: item.0, pi: prev.0)
            if isCross || isUp {
                curIdx.append(item.0)
                curAlign.append(isCross ? "center" : alignment(box, prevBox))
            } else {
                groups.append((curIdx, curAlign))
                curIdx = [item.0]
                curAlign = []
            }
        }
        if !curIdx.isEmpty { groups.append((curIdx, curAlign)) }

        let ranges: [(start: Int, end: Int, gidx: [Int], aligns: [String])] = groups.map {
            ($0.0.min() ?? 0, $0.0.max() ?? 0, $0.0, $0.1)
        }
        var result: [Block] = []
        var used = Set<Int>()
        var idx = 0
        while idx < blocks.count {
            var found = false
            for range in ranges {
                guard idx == range.start, range.gidx.allSatisfy({ !used.contains($0) }) else { continue }
                found = true
                let imgs = range.gidx.compactMap { blocks[$0].image }
                let w = imgs.map { pixelSize($0).0 }.max() ?? 0
                let h = imgs.reduce(0) { $0 + pixelSize($1).1 }
                let tooTall = w == 0 || imgs.count != range.gidx.count || Double(h) / Double(w) >= 3
                if tooTall {
                    for bi in range.gidx {
                        result.append(blocks[bi])
                        used.insert(bi)
                    }
                } else {
                    let stitched = mergeImages(imgs, aligns: range.aligns)
                    for (j, bi) in range.gidx.enumerated() {
                        var b = blocks[bi]
                        b.image = j == 0 ? stitched : nil
                        result.append(b)
                        used.insert(bi)
                    }
                }
                if range.end > range.start {
                    for ni in (range.start + 1)..<range.end {
                        if let extra = fixed[ni] {
                            result.append(extra)
                            used.insert(ni)
                        }
                    }
                }
                idx = range.end + 1
                break
            }
            if found { continue }
            if let extra = fixed[idx] {
                result.append(extra)
                used.insert(idx)
            }
            idx += 1
        }
        return result
    }
}

// MARK: - Error types

public enum OcrError: Error, LocalizedError {
    case notReady
    case layoutNotLoaded
    case ocrNotLoaded
    case invalidImage
    case recognitionFailed
    case noLayoutDetected
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notReady:          return "OCR engine is not ready. Please load models first."
        case .layoutNotLoaded:   return "Layout model is not loaded."
        case .ocrNotLoaded:      return "OCR model is not loaded."
        case .invalidImage:      return "Invalid or unsupported image."
        case .recognitionFailed: return "OCR recognition failed."
        case .noLayoutDetected:  return "No layout blocks detected in the image."
        case .cancelled:         return "OCR cancelled."
        }
    }
}

// MARK: - Upright

/// Decides whether a page needs to be rotated before layout, and finds the angle.
///
/// Text that runs vertically (boxes taller than wide) or a layout pass that
/// found nothing means the page is probably lying on its side. Upright pages
/// skip this entirely, so the common case costs nothing.
@MainActor
enum OcrUpright {

    /// Labels that carry body text. Rotation is judged by these only; figure
    /// and seal boxes are close to square and vote either way.
    private static let textLabels: Set<String> = [
        "text", "content", "abstract", "reference", "reference_content",
        "vertical_text", "algorithm", "doc_title", "paragraph_title",
        "table", "figure_title", "footer", "header", "footnote", "aside_text",
    ]

    private static let angles: [CGFloat] = [90, 180, 270]

    /// Probe images are downscaled; only their score matters.
    private static let probeMaxSide: CGFloat = 900

    private static var enabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("-ocrNoUpright")
    }

    static func shouldRetry(_ blocks: [LayoutBlock]) -> Bool {
        guard enabled else { return false }
        if blocks.isEmpty { return true }
        let text = blocks.filter { textLabels.contains($0.label) }
        guard text.count >= 3 else { return false }
        let tall = text.filter { ($0.y2 - $0.y1) > 2 * ($0.x2 - $0.x1) }.count
        return Double(tall) / Double(text.count) >= 0.6
    }

    /// Returns the rotated full-size page and its blocks, or nil when no
    /// rotation beats the original by a clear margin.
    static func best(_ image: UIImage, current blocks: [LayoutBlock])
        async -> (UIImage, [LayoutBlock])? {
        let base = score(blocks)
        let probe = downscaled(image, maxSide: probeMaxSide)

        var bestAngle: CGFloat = 0
        var bestScore = 0.0
        for angle in angles {
            guard let rotated = probe.rotated(byDegrees: angle) else { continue }
            let probeBlocks = (try? await OcrEngine.shared.detectLayout(image: rotated)) ?? []
            let s = score(probeBlocks)
            if s > bestScore {
                bestScore = s
                bestAngle = angle
            }
        }

        // 1.3x 是为了避开噪声：正向页面也可能略低于某个错误方向。
        guard bestAngle != 0, bestScore > base * 1.3 else { return nil }
        guard let full = image.rotated(byDegrees: bestAngle) else { return nil }
        let fullBlocks = (try? await OcrEngine.shared.detectLayout(image: full)) ?? []
        guard score(fullBlocks) > base else { return nil }
        return (full, fullBlocks)
    }

    /// Area times confidence over text boxes: a page read the right way up
    /// yields large, confident text regions.
    private static func score(_ blocks: [LayoutBlock]) -> Double {
        var total = 0.0
        for b in blocks where textLabels.contains(b.label) {
            let w = Double(max(0, b.x2 - b.x1))
            let h = Double(max(0, b.y2 - b.y1))
            total += w * h * Double(b.score)
        }
        return total
    }

    private static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let long = max(image.size.width, image.size.height)
        guard long > maxSide else { return image }
        let scale = maxSide / long
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
