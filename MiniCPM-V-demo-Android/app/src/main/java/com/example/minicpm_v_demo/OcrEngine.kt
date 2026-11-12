package com.example.minicpm_v_demo

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import kotlinx.coroutines.flow.collect
import java.io.ByteArrayOutputStream

/**
 * One page of MiniCPM-OCR: layout, optional upright, then one VLM call per crop.
 * Sampling and the ChatML image turn live in LlamaEngine / the JNI bridge.
 */
class OcrEngine(
    private val llama: LlamaEngine,
    context: Context,
) {
    private val appContext = context.applicationContext
    private var detector: LayoutDetector? = null

    @Volatile
    var cancelRequested: Boolean = false

    fun close() {
        detector?.close()
        detector = null
        // Releases ~880 MiB of NPU context. Cheap to bring back up (265 ms).
        QnnVit.shutdown()
    }

    suspend fun recognizePage(
        page: Bitmap,
        onStatus: suspend (String) -> Unit,
        onPreview: suspend (Bitmap) -> Unit,
        onToken: suspend (String) -> Unit,
    ): String {
        var image = page
        onStatus("layout")
        var boxes = detect(image)
        if (OcrLayout.shouldRetry(boxes)) {
            val upright = upright(image, boxes)
            if (upright != null) {
                if (image !== page) image.recycle()
                image = upright.first
                boxes = upright.second
            }
        }
        val crops = OcrLayout.crops(boxes, image)
        // Diagnostics: per-crop geometry plus the recognised text. Costs
        // nothing when DEBUG_DUMP is false; invaluable when a backend swap
        // changes output quality.
        if (DEBUG_DUMP) {
            Log.i(TAG, "page ${page.width}x${page.height} -> ${crops.size} crops")
        }
        val blocks = ArrayList<OcrMarkdown.Block>()
        for ((index, crop) in crops.withIndex()) {
            if (cancelRequested) break
            onPreview(crop.image)
            val spec = OcrPrompts.promptFor(crop.label)
            if (spec.skip || spec.prompt.isEmpty()) {
                blocks.add(OcrMarkdown.Block(crop.label, "", crop.order))
                continue
            }
            if (DEBUG_DUMP) {
                Log.i(TAG, "crop[$index] ${crop.label} ${crop.image.width}x${crop.image.height}"
                        + " aspect=${"%.2f".format(crop.image.width.toFloat() / crop.image.height)}")
                dumpCrop(crop.image, index, crop.label)
            }
            onStatus(crop.label)
            val raw = recognizeCrop(crop, spec.prompt, spec.maxTokens, onToken)
            if (cancelRequested) break
            // Streaming arrives block by block with nothing in between, so the
            // live preview would run one layout box straight into the next.
            // Two newlines keep the blocks visually separate while the page is
            // still being recognised; the final markdown is rebuilt from
            // `blocks` and does not depend on this.
            if (raw.isNotBlank()) onToken("\n\n")
            val cleaned = OcrMarkdown.classifyEngineText(raw)
            val content = OcrMarkdown.postprocess(cleaned, spec.outputFormat, crop.label)
            val mixed = crop.label == "inline_formula" && OcrMarkdown.hasMixedInlineFormula(content)
            if (DEBUG_DUMP) {
                Log.i(TAG, "crop[$index] result: ${content.replace('\n', ' ')}")
            }
            blocks.add(OcrMarkdown.Block(crop.label, content, crop.order, mixed))
        }
        if (image !== page) image.recycle()
        return OcrMarkdown.assemble(OcrMarkdown.normalize(blocks))
    }

    /** Writes a crop to app storage so it can be replayed offline. */
    private fun dumpCrop(bitmap: Bitmap, index: Int, label: String) {
        try {
            val dir = java.io.File(appContext.filesDir, "ocr_debug").apply { mkdirs() }
            java.io.FileOutputStream(java.io.File(dir, "crop_%02d_%s.png".format(index, label)))
                .use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        } catch (t: Throwable) {
            Log.w(TAG, "dumpCrop failed", t)
        }
    }

    private fun detect(image: Bitmap): List<LayoutBox> {
        val path = LlamaEngine.layoutPath(appContext) ?: return emptyList()
        val current = detector ?: LayoutDetector(path).also { detector = it }
        return current.detect(image)
    }

    /**
     * Probe 90/180/270 on a 900px copy. Keep a rotation only when its probe
     * score beats the original by 1.3x and a full-page re-detect still wins.
     */
    private fun upright(image: Bitmap, boxes: List<LayoutBox>): Pair<Bitmap, List<LayoutBox>>? {
        val base = OcrLayout.score(boxes)
        val probe = OcrLayout.downscale(image, 900)
        var bestAngle = 0
        var bestScore = 0.0
        for (angle in intArrayOf(90, 180, 270)) {
            val rotated = OcrLayout.rotate(probe, angle)
            val score = OcrLayout.score(detect(rotated))
            if (rotated !== probe) rotated.recycle()
            if (score > bestScore) {
                bestScore = score
                bestAngle = angle
            }
        }
        if (probe !== image) probe.recycle()
        if (bestAngle == 0 || bestScore <= base * 1.3) return null
        val full = OcrLayout.rotate(image, bestAngle)
        val fullBoxes = detect(full)
        if (OcrLayout.score(fullBoxes) <= base) {
            full.recycle()
            return null
        }
        return full to fullBoxes
    }

    private suspend fun recognizeCrop(
        crop: OcrCrop,
        prompt: String,
        maxTokens: Int,
        onToken: suspend (String) -> Unit,
    ): String {
        // The NPU tower runs the linear 1024-patch canvas, so a crop no longer
        // has to be squashed into a square: the patch grid travels as graph
        // inputs instead of being baked into the shape.
        //
        // The NPU replaces the *overview* chunk; mtmd's slices, if any, still go
        // through ggml. So the original crop is normally handed to mtmd
        // untouched and only the overview goes to the NPU. The exception is a
        // crop whose overview needs more than 1024 patches: there the bottom
        // patch rows are dropped, and mtmd has to be given that same cropped
        // bitmap or its grid would describe patches the NPU never saw.
        var image = crop.image
        if (QnnVit.ensureReady(appContext)) {
            val plan = OcrLayout.canvas(image.width, image.height)
            if (!plan.fitsCanvas) {
                Log.w(TAG, "overview ${plan.targetW}x${plan.targetH} needs " +
                        "${plan.patches} patches; using ggml")
            } else {
                val overview = OcrLayout.overview(image, plan)
                if (QnnVit.encode(overview, plan.posW, plan.posH)) {
                    Log.i(TAG, "NPU overview ${image.width}x${image.height} -> " +
                            "${plan.targetW}x${plan.targetH} (${plan.posW}x${plan.posH} " +
                            "patches, ${plan.tokens} tokens, src ${plan.srcW}x${plan.srcH})")
                    if (plan.cropped) {
                        // mtmd must see the region the NPU encoded, otherwise it
                        // derives a bigger overview and the chunks stop lining up.
                        image = overview
                    }
                } else {
                    Log.w(TAG, "NPU encode failed; falling back to the ggml vision tower")
                }
                if (overview !== image) overview.recycle()
            }
        }

        val png = ByteArrayOutputStream().use { out ->
            if (!image.compress(Bitmap.CompressFormat.PNG, 100, out)) {
                error("png encode failed")
            }
            out.toByteArray()
        }
        if (image !== crop.image) image.recycle()

        llama.clearKv()
        llama.prefillImage(png)
        val text = StringBuilder()
        llama.sendUserPrompt(prompt, maxTokens).collect { token ->
            text.append(token)
            onToken(token)
        }
        return text.toString()
    }

    companion object {
        private const val TAG = "OcrEngine"
        const val PAGE_BREAK = "\n\n<!-- page-break -->\n\n"

        /**
         * Dump every crop and its recognised text, for backend A/B work.
         * Flip to true (and pull `files/ocr_debug/`) when comparing encoders.
         */
        private const val DEBUG_DUMP = false
    }
}
