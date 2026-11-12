package com.example.minicpm_v_demo

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.graphics.Bitmap
import java.nio.FloatBuffer
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** One layout box in original-image pixels, already in reading order. */
data class LayoutBox(
    val labelId: Int,
    val label: String,
    val score: Float,
    val x1: Float,
    val y1: Float,
    val x2: Float,
    val y2: Float,
)

/**
 * PP-DocLayoutV3. Post-processing matches iOS LayoutBridge.mm, including the
 * +1px NMS IoU and the separate 90% containment test.
 */
class LayoutDetector(onnxPath: String) : AutoCloseable {
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val session: OrtSession = env.createSession(onnxPath)

    fun detect(bitmap: Bitmap, threshold: Float = 0.3f): List<LayoutBox> {
        val width = bitmap.width
        val height = bitmap.height
        if (width <= 0 || height <= 0) return emptyList()
        val rgb = bitmapToRgb(bitmap)
        val pixels = preprocess(rgb, width, height)
        val mask = FloatArray(INPUT * INPUT) { 1f }

        val pixelTensor = OnnxTensor.createTensor(
            env, FloatBuffer.wrap(pixels), longArrayOf(1, 3, INPUT.toLong(), INPUT.toLong())
        )
        val maskTensor = OnnxTensor.createTensor(
            env, FloatBuffer.wrap(mask), longArrayOf(1, INPUT.toLong(), INPUT.toLong())
        )
        pixelTensor.use {
            maskTensor.use {
                session.run(mapOf("pixel_values" to pixelTensor, "pixel_mask" to maskTensor)).use { result ->
                    val logits = floatArrayOf(result, "logits")
                    val boxes = floatArrayOf(result, "pred_boxes")
                    val orderLogits = floatArrayOf(result, "order_logits")
                    return decode(logits, boxes, orderLogits, width, height, threshold)
                }
            }
        }
    }

    override fun close() {
        session.close()
    }

    private fun floatArrayOf(result: OrtSession.Result, name: String): FloatArray {
        val value = result.get(name).orElseThrow { IllegalStateException("missing output $name") }
        val tensor = value as OnnxTensor
        val buf = tensor.floatBuffer
        val out = FloatArray(buf.remaining())
        buf.get(out)
        return out
    }

    private fun decode(
        logits: FloatArray,
        boxes: FloatArray,
        orderLogits: FloatArray,
        width: Int,
        height: Int,
        threshold: Float,
    ): List<LayoutBox> {
        val nFlat = QUERIES * CLASSES
        val scores = FloatArray(nFlat) { sigmoidClip(logits[it]) }
        val rank = scores.indices.sortedWith(compareByDescending<Int> { scores[it] }.thenBy { it })
        val orderSeq = orderSeqs(orderLogits, QUERIES)

        val raw = ArrayList<Det>(QUERIES)
        for (k in 0 until QUERIES) {
            val flat = rank[k]
            val label = flat % CLASSES
            val q = flat / CLASSES
            val cx = boxes[q * 4]
            val cy = boxes[q * 4 + 1]
            val bw = boxes[q * 4 + 2]
            val bh = boxes[q * 4 + 3]
            raw.add(
                Det(
                    label = label,
                    score = scores[flat],
                    x1 = java.lang.Math.rint(((cx - 0.5f * bw) * width).toDouble()).toFloat(),
                    y1 = java.lang.Math.rint(((cy - 0.5f * bh) * height).toDouble()).toFloat(),
                    x2 = java.lang.Math.rint(((cx + 0.5f * bw) * width).toDouble()).toFloat(),
                    y2 = java.lang.Math.rint(((cy + 0.5f * bh) * height).toDouble()).toFloat(),
                    order = orderSeq[q].toFloat(),
                )
            )
        }

        var kept = raw.filter { it.score > threshold && it.label > -1 }
        if (kept.isEmpty()) return emptyList()
        kept = nms(kept)
        if (kept.isEmpty()) return emptyList()

        if (kept.size > 1) {
            val imgArea = width.toFloat() * height
            val areaThres = if (width > height) 0.82f else 0.93f
            val filtered = kept.filter { b ->
                if (b.label != 14) return@filter true
                val x1 = max(0f, b.x1).toInt()
                val y1 = max(0f, b.y1).toInt()
                val x2 = min(width.toFloat(), b.x2).toInt()
                val y2 = min(height.toFloat(), b.y2).toInt()
                val ba = (x2 - x1).toFloat() * (y2 - y1)
                ba <= areaThres * imgArea
            }
            if (filtered.isNotEmpty()) kept = filtered
        }
        if (kept.isEmpty()) return emptyList()

        if (kept.size >= 2) {
            val cats = intArrayOf(3, 5, 6, 15, 17)
            val keepMask = BooleanArray(kept.size) { true }
            for (cat in cats) {
                val contained = BooleanArray(kept.size)
                for (i in kept.indices) {
                    for (j in kept.indices) {
                        if (i != j && kept[j].label == cat && contained90(kept[i], kept[j])) {
                            contained[i] = true
                        }
                    }
                }
                for (i in kept.indices) if (contained[i]) keepMask[i] = false
            }
            kept = kept.filterIndexed { i, _ -> keepMask[i] }
        }
        if (kept.isEmpty()) return emptyList()

        return kept.sortedWith(compareBy { it.order }).mapNotNull { b ->
            val x1 = max(0f, b.x1).toInt()
            val y1 = max(0f, b.y1).toInt()
            val x2 = min(width.toFloat(), b.x2).toInt()
            val y2 = min(height.toFloat(), b.y2).toInt()
            if (x2 <= x1 || y2 <= y1) return@mapNotNull null
            val name = OcrPrompts.labelIdToName[b.label] ?: "text"
            LayoutBox(b.label, name, b.score, x1.toFloat(), y1.toFloat(), x2.toFloat(), y2.toFloat())
        }
    }

    private data class Det(
        val label: Int,
        val score: Float,
        val x1: Float,
        val y1: Float,
        val x2: Float,
        val y2: Float,
        val order: Float,
    )

    private fun nms(boxes: List<Det>): List<Det> {
        val order = boxes.indices.sortedWith(compareByDescending<Int> { boxes[it].score }.thenBy { it })
        val dead = BooleanArray(boxes.size)
        val kept = ArrayList<Det>()
        for (n in order.indices) {
            val c = order[n]
            if (dead[c]) continue
            kept.add(boxes[c])
            for (m in n + 1 until order.size) {
                val r = order[m]
                if (dead[r]) continue
                val thr = if (boxes[c].label != boxes[r].label) 0.98f else 0.6f
                if (iouPlus1(boxes[c], boxes[r]) >= thr) dead[r] = true
            }
        }
        return kept
    }

    private fun iouPlus1(a: Det, b: Det): Float {
        val iw = min(a.x2, b.x2) - max(a.x1, b.x1) + 1f
        val ih = min(a.y2, b.y2) - max(a.y1, b.y1) + 1f
        if (iw <= 0f || ih <= 0f) return 0f
        val ia = iw * ih
        val a1 = (a.x2 - a.x1 + 1f) * (a.y2 - a.y1 + 1f)
        val a2 = (b.x2 - b.x1 + 1f) * (b.y2 - b.y1 + 1f)
        val denom = a1 + a2 - ia
        return if (denom > 0f) ia / denom else 0f
    }

    private fun contained90(inner: Det, outer: Det): Boolean {
        val iw = max(0f, min(inner.x2, outer.x2) - max(inner.x1, outer.x1))
        val ih = max(0f, min(inner.y2, outer.y2) - max(inner.y1, outer.y1))
        val ia = iw * ih
        val a1 = (inner.x2 - inner.x1) * (inner.y2 - inner.y1)
        return a1 > 0f && ia / a1 >= 0.9f
    }

    private fun orderSeqs(orderLogits: FloatArray, n: Int): IntArray {
        val os = FloatArray(n * n) { sigmoidClip(orderLogits[it]) }
        val votes = FloatArray(n)
        for (j in 0 until n) {
            for (i in 0 until j) votes[j] += os[i * n + j]
            for (i in j + 1 until n) votes[j] += 1f - os[j * n + i]
        }
        val ptrs = votes.indices.sortedWith(compareBy<Int> { votes[it] }.thenBy { it })
        val seq = IntArray(n)
        for (k in ptrs.indices) seq[ptrs[k]] = k
        return seq
    }

    private fun sigmoidClip(xIn: Float): Float {
        val x = xIn.coerceIn(-50f, 50f)
        return 1f / (1f + exp(-x))
    }

    private fun bitmapToRgb(bitmap: Bitmap): ByteArray {
        val w = bitmap.width
        val h = bitmap.height
        val pixels = IntArray(w * h)
        bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
        val rgb = ByteArray(w * h * 3)
        for (i in pixels.indices) {
            val p = pixels[i]
            rgb[i * 3] = ((p shr 16) and 0xFF).toByte()
            rgb[i * 3 + 1] = ((p shr 8) and 0xFF).toByte()
            rgb[i * 3 + 2] = (p and 0xFF).toByte()
        }
        return rgb
    }

    /** Stretch to 800x800, Catmull-Rom, align_corners = false. */
    private fun preprocess(rgb: ByteArray, width: Int, height: Int): FloatArray {
        val scaleX = INPUT.toFloat() / width
        val scaleY = INPUT.toFloat() / height
        val out = FloatArray(3 * INPUT * INPUT)
        for (c in 0 until 3) {
            val chan = c * INPUT * INPUT
            for (y in 0 until INPUT) {
                val srcY = (y + 0.5f) / scaleY - 0.5f
                val sy0 = floor(srcY).toInt() - 1
                val wy = FloatArray(4) { cubic(srcY - (sy0 + it)) }
                for (x in 0 until INPUT) {
                    val srcX = (x + 0.5f) / scaleX - 0.5f
                    val sx0 = floor(srcX).toInt() - 1
                    val wx = FloatArray(4) { cubic(srcX - (sx0 + it)) }
                    var value = 0f
                    for (dy in 0 until 4) {
                        var sy = sy0 + dy
                        if (sy < 0) sy = 0 else if (sy >= height) sy = height - 1
                        for (dx in 0 until 4) {
                            var sx = sx0 + dx
                            if (sx < 0) sx = 0 else if (sx >= width) sx = width - 1
                            val sample = (rgb[(sy * width + sx) * 3 + c].toInt() and 0xFF).toFloat()
                            value += wx[dx] * wy[dy] * sample
                        }
                    }
                    out[chan + y * INPUT + x] = value / 255f
                }
            }
        }
        return out
    }

    private fun cubic(xIn: Float): Float {
        val x = kotlin.math.abs(xIn)
        if (x < 1f) return (1.25f * x - 2.25f) * x * x + 1f
        if (x < 2f) return ((-0.75f * x + 3.75f) * x - 6f) * x + 3f
        return 0f
    }

    companion object {
        private const val INPUT = 800
        private const val CLASSES = 25
        private const val QUERIES = 300
    }
}
