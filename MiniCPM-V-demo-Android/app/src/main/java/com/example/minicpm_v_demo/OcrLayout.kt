package com.example.minicpm_v_demo

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** A crop ready for the VLM. [order] is the index in the merged list. */
data class OcrCrop(
    val label: String,
    val score: Float,
    val x1: Float,
    val y1: Float,
    val x2: Float,
    val y2: Float,
    val order: Int,
    val image: Bitmap,
)

/**
 * Overlap filter and neighbour merge from iOS OcrLayoutCrop, plus the
 * upright-page retry from OcrUpright.
 */
object OcrLayout {
    private val nonMerge = setOf(
        "image", "header_image", "footer_image", "chart", "seal", "table"
    )
    private val textLabels = setOf(
        "text", "content", "abstract", "reference", "reference_content",
        "vertical_text", "algorithm", "doc_title", "paragraph_title",
        "table", "figure_title", "footer", "header", "footnote", "aside_text",
    )

    private class Block(
        val label: String,
        val score: Float,
        val box: FloatArray,
        var image: Bitmap?,
    )

    fun crops(boxes: List<LayoutBox>, image: Bitmap): List<OcrCrop> {
        val filtered = filterOverlap(boxes)
        val cropped = filtered.map { box ->
            val x1 = box.x1.toInt()
            val y1 = box.y1.toInt()
            val x2 = box.x2.toInt()
            val y2 = box.y2.toInt()
            val crop = cropBitmap(image, x1, y1, x2, y2)
            Block(box.label, box.score, floatArrayOf(box.x1, box.y1, box.x2, box.y2), crop)
        }
        val merged = merge(cropped)
        val out = ArrayList<OcrCrop>()
        for ((order, block) in merged.withIndex()) {
            val img = block.image ?: continue
            out.add(
                OcrCrop(
                    block.label, block.score,
                    block.box[0], block.box[1], block.box[2], block.box[3],
                    order, img
                )
            )
        }
        return out
    }

    fun shouldRetry(boxes: List<LayoutBox>): Boolean {
        if (boxes.isEmpty()) return true
        val text = boxes.filter { textLabels.contains(it.label) }
        if (text.size < 3) return false
        val tall = text.count { (it.y2 - it.y1) > 2 * (it.x2 - it.x1) }
        return tall.toDouble() / text.size >= 0.6
    }

    fun score(boxes: List<LayoutBox>): Double {
        var total = 0.0
        for (b in boxes) {
            if (!textLabels.contains(b.label)) continue
            val w = max(0f, b.x2 - b.x1).toDouble()
            val h = max(0f, b.y2 - b.y1).toDouble()
            total += w * h * b.score
        }
        return total
    }

    fun downscale(image: Bitmap, maxSide: Int): Bitmap {
        val long = max(image.width, image.height)
        if (long <= maxSide) return image
        val scale = maxSide.toFloat() / long
        val w = max(1, (image.width * scale).toInt())
        val h = max(1, (image.height * scale).toInt())
        return Bitmap.createScaledBitmap(image, w, h, true)
    }

    // ---- mtmd's OCR resize rule -------------------------------------------
    //
    // The NPU graph is fed packed patches, so the patch grid it runs on has to
    // be the one mtmd derives from the very same bitmap. Rather than resizing
    // twice and hoping, the crop is scaled to the size mtmd will pick, which
    // makes mtmd's own resize an identity.

    private const val VISION_SLICE = 448
    private const val VISION_ALIGN = 28          // patch_size * n_merge
    private const val VISION_BUDGET = VISION_SLICE * VISION_SLICE

    /** Python's round(): ties go to even, unlike std::round's away-from-zero. */
    private fun alignRoundEven(v: Double): Int {
        val fl = floor(v)
        val diff = v - fl
        if (diff > 0.5) return fl.toInt() + 1
        if (diff < 0.5) return fl.toInt()
        val lo = fl.toInt()
        return if (lo % 2 == 0) lo else lo + 1
    }

    private fun ensureDivide(len: Int): Int =
        max(alignRoundEven(len.toDouble() / VISION_ALIGN) * VISION_ALIGN, VISION_ALIGN)

    /** One pass of `get_best_resize` with mtmd's OCR arguments. */
    private fun overviewSize(w: Int, h: Int): Pair<Int, Int> {
        var rw = max(1, w)
        var rh = max(1, h)
        // allow_overview_upscale() is !has_slices: a crop that already exceeds
        // the slice on one side keeps its native pixels.
        val allowUpscale = rw <= VISION_SLICE && rh <= VISION_SLICE
        if (rw.toLong() * rh > VISION_BUDGET || allowUpscale) {
            val r = rw.toDouble() / rh
            rh = (VISION_SLICE / sqrt(r)).toInt()
            rw = (rh * r).toInt()
        }
        return ensureDivide(rw) to ensureDivide(rh)
    }

    /**
     * The overview size mtmd's preprocessor will produce for a `srcW x srcH`
     * crop, in pixels -- exactly one `get_best_resize` pass, because that is
     * what mtmd does.
     *
     * Do not iterate this to a fixed point. For a crop that gets upscaled
     * (`allow_overview_upscale() == !has_slices`) the two answers differ: a
     * 435x36 crop is 1540x140 (275 tokens) in one pass, but 1428x140 (255) at
     * the fixed point, and mtmd takes the first. Getting this wrong costs a
     * silent fallback to ggml on every small crop.
     */
    fun visionSize(srcW: Int, srcH: Int): Pair<Int, Int> =
        overviewSize(max(1, srcW), max(1, srcH))

    /**
     * A settled overview: mtmd's `get_best_resize` leaves it unchanged.
     *
     * Three conditions, all needed. 28-aligned, because that is mtmd's
     * `get_slice_align()` for this model. Area inside the 448x448 budget and
     * one side past 448, because `mtmd_image_preprocessor_minicpm_ocr_1_0`
     * only upscales when the crop already fits inside a slice
     * (`allow_overview_upscale() == !has_slices`) -- and an upscale would move
     * the grid out from under the NPU.
     */
    private fun isSettled(w: Int, h: Int): Boolean =
        w % VISION_ALIGN == 0 && h % VISION_ALIGN == 0 &&
            w.toLong() * h <= VISION_BUDGET &&
            (w > VISION_SLICE || h > VISION_SLICE)

    /**
     * Where one crop is encoded: the bitmap to hand mtmd, and the grid to give
     * the NPU.
     *
     * `targetW x targetH` is always a settled overview, so mtmd resizes nothing
     * and both sides see the same patch grid. `srcW x srcH` is the region of
     * the original crop that maps onto it -- equal to the crop unless the
     * overview needed patches the canvas cannot hold.
     *
     * A graph canvas is a fixed 1024 patches, and mtmd's 28-alignment can put
     * an overview slightly past that (a 300x200 crop settles at 560x364 = 1040
     * patches, because the alignment rounds 379 up to 392). Those crops keep the
     * NPU and lose the bottom rows, matching what the ANE path does when it
     * stops copying at `max_patches`: patches are filled in row-major order and
     * the remainder is dropped, so the width -- and with it every column of a
     * wide table -- survives.
     *
     * Rows are trimmed in pairs because the target has to stay 28-aligned, and
     * 28 px is two patch rows.
     */
    data class Canvas(
        val targetW: Int,
        val targetH: Int,
        val srcW: Int,
        val srcH: Int,
        val cropped: Boolean,
    ) {
        val posW: Int get() = targetW / QnnVit.PATCH
        val posH: Int get() = targetH / QnnVit.PATCH
        val patches: Int get() = posW * posH

        /** Rows the merger keeps: (pos_h / 2) * (pos_w / 2). */
        val tokens: Int get() = (posH / 2) * (posW / 2)

        val fitsCanvas: Boolean get() = patches <= QnnVit.MAX_PATCHES
    }

    /**
     * The bitmap the NPU encodes: the surviving region of [image], scaled to the
     * canvas grid.
     *
     * The caller owns the result and must recycle it when it is not the same
     * object as [image].
     */
    fun overview(image: Bitmap, plan: Canvas): Bitmap {
        val region = if (plan.cropped) {
            Bitmap.createBitmap(image, 0, 0, plan.srcW, plan.srcH)
        } else {
            image
        }
        val out = if (region.width == plan.targetW && region.height == plan.targetH) {
            region
        } else {
            Bitmap.createScaledBitmap(region, plan.targetW, plan.targetH, true)
        }
        if (region !== image && region !== out) region.recycle()
        return out
    }

    fun canvas(srcW: Int, srcH: Int): Canvas {
        val (ow, oh) = visionSize(srcW, srcH)
        var posW = ow / QnnVit.PATCH
        var posH = oh / QnnVit.PATCH
        if (posW * posH <= QnnVit.MAX_PATCHES) {
            // Nothing to drop: mtmd gets the original crop and derives this
            // overview itself, which is exactly the grid the NPU runs.
            return Canvas(ow, oh, srcW, srcH, cropped = false)
        }

        // Keep the width and drop patch rows off the bottom, the way the ANE
        // path fills patches row-major and stops at max_patches. Dropping rows
        // rather than columns is what keeps every column of a wide table.
        posH = (QnnVit.MAX_PATCHES / posW) / 2 * 2
        if (posH < 2) {
            // Too wide for even two rows; trim the width as well.
            posH = 2
            posW = (QnnVit.MAX_PATCHES / posH) / 2 * 2
        }
        val tw = posW * QnnVit.PATCH
        val th = posH * QnnVit.PATCH
        if (!isSettled(tw, th)) {
            // Degenerate input; leave the crop to ggml rather than handing the
            // NPU a grid mtmd will not reproduce.
            return Canvas(ow, oh, srcW, srcH, cropped = false)
        }
        // Keep the full width and the matching fraction of the height, so the
        // surviving rows are the top ones and nothing is squashed. Width is
        // only trimmed on the degenerate case above, where even two rows would
        // overflow -- and then it has to be trimmed, or mtmd would derive a
        // wider grid than the NPU ran.
        val cw = if (tw == ow) srcW else max(1, (srcW.toLong() * tw / ow).toInt())
        val ch = if (th == oh) srcH else max(1, (srcH.toLong() * th / oh).toInt())
        return Canvas(tw, th, min(srcW, cw), min(srcH, ch),
            cropped = cw != srcW || ch != srcH)
    }

    fun rotate(image: Bitmap, degrees: Int): Bitmap {
        val m = Matrix()
        m.postRotate(degrees.toFloat())
        return Bitmap.createBitmap(image, 0, 0, image.width, image.height, m, true)
    }

    private fun filterOverlap(raw: List<LayoutBox>): List<LayoutBox> {
        val boxes = raw.filter { it.label != "reference" }
        if (boxes.isEmpty()) return emptyList()
        val dropped = HashSet<Int>()
        for (i in boxes.indices) {
            val w = boxes[i].x2 - boxes[i].x1
            val h = boxes[i].y2 - boxes[i].y1
            if (w < 6 || h < 6) {
                dropped.add(i)
                continue
            }
            for (j in i + 1 until boxes.size) {
                if (i in dropped || j in dropped) continue
                val ov = smallOverlap(boxes[i], boxes[j])
                if (boxes[i].label == "inline_formula" || boxes[j].label == "inline_formula") {
                    if (ov.ratio > 0.5) {
                        if (boxes[i].label == "inline_formula") dropped.add(i)
                        if (boxes[j].label == "inline_formula") dropped.add(j)
                        continue
                    }
                }
                if (ov.ratio > 0.7) {
                    if (ov.areaI >= ov.areaJ) dropped.add(j) else dropped.add(i)
                }
            }
        }
        return boxes.filterIndexed { index, _ -> index !in dropped }
    }

    private data class Overlap(val ratio: Double, val areaI: Double, val areaJ: Double)

    private fun smallOverlap(a: LayoutBox, b: LayoutBox): Overlap {
        val iw = max(0f, min(a.x2, b.x2) - max(a.x1, b.x1)).toDouble()
        val ih = max(0f, min(a.y2, b.y2) - max(a.y1, b.y1)).toDouble()
        val ia = iw * ih
        val areaI = abs((a.x2 - a.x1) * (a.y2 - a.y1)).toDouble()
        val areaJ = abs((b.x2 - b.x1) * (b.y2 - b.y1)).toDouble()
        val smaller = min(areaI, areaJ)
        return Overlap(if (smaller > 0) ia / smaller else 0.0, areaI, areaJ)
    }

    private fun unionOverlap(a: FloatArray, b: FloatArray): Double {
        val iw = max(0f, min(a[2], b[2]) - max(a[0], b[0])).toDouble()
        val ih = max(0f, min(a[3], b[3]) - max(a[1], b[1])).toDouble()
        val ia = iw * ih
        val a1 = max(0.0, ((a[2] - a[0]) * (a[3] - a[1])).toDouble())
        val a2 = max(0.0, ((b[2] - b[0]) * (b[3] - b[1])).toDouble())
        val ref = a1 + a2 - ia
        return if (ref > 0) ia / ref else 0.0
    }

    private fun projectionOverlapX(a: FloatArray, b: FloatArray): Double {
        val overlap = min(a[2], b[2]) - max(a[0], b[0])
        if (overlap <= 0) return 0.0
        val ref = max(a[2], b[2]) - min(a[0], b[0])
        return if (ref > 0) overlap / ref.toDouble() else 0.0
    }

    private fun cropBitmap(image: Bitmap, x1: Int, y1: Int, x2: Int, y2: Int): Bitmap? {
        val left = x1.coerceIn(0, image.width)
        val top = y1.coerceIn(0, image.height)
        val right = x2.coerceIn(0, image.width)
        val bottom = y2.coerceIn(0, image.height)
        val w = right - left
        val h = bottom - top
        if (w <= 0 || h <= 0) return null
        return Bitmap.createBitmap(image, left, top, w, h)
    }

    private fun merge(blocks: List<Block>): List<Block> {
        if (blocks.isEmpty()) return emptyList()
        val toMerge = ArrayList<Pair<Int, Block>>()
        val fixed = HashMap<Int, Block>()
        for ((idx, block) in blocks.withIndex()) {
            if (block.label in nonMerge) fixed[idx] = block else toMerge.add(idx to block)
        }
        fun aligned(a: Float, b: Float) = abs(a - b) <= 5f
        fun alignment(bbox: FloatArray, prev: FloatArray): String {
            if (aligned(bbox[0], prev[0])) return "left"
            if (aligned(bbox[2], prev[2])) return "right"
            return "center"
        }
        fun overlapsFixed(bi: Int, pi: Int): Boolean {
            val pb = blocks[pi].box
            val bb = blocks[bi].box
            val span = floatArrayOf(
                min(pb[0], bb[0]), min(pb[1], bb[1]), max(pb[2], bb[2]), max(pb[3], bb[3])
            )
            for ((oi, ob) in blocks.withIndex()) {
                if (oi == bi || oi == pi || ob.label !in nonMerge) continue
                if (unionOverlap(span, ob.box) > 0) return true
            }
            return false
        }

        data class Group(val idx: List<Int>, val aligns: List<String>)
        val groups = ArrayList<Group>()
        var curIdx = ArrayList<Int>()
        var curAlign = ArrayList<String>()
        for (i in toMerge.indices) {
            val item = toMerge[i]
            if (curIdx.isEmpty()) {
                curIdx = arrayListOf(item.first)
                curAlign = arrayListOf()
                continue
            }
            val prev = toMerge[i - 1]
            val prevBox = prev.second.box
            val box = item.second.box
            val iouH = projectionOverlapX(box, prevBox)
            val isCross = iouH == 0.0 &&
                item.second.label == "text" && item.second.label == prev.second.label &&
                box[0] > prevBox[2] && box[1] < prevBox[3] &&
                (box[0] - prevBox[2]) < max(prevBox[2] - prevBox[0], box[2] - box[0]) * 0.3f
            val isUp = iouH > 0 &&
                (item.second.label == "text" || item.second.label == "vertical_text") &&
                item.second.label == prev.second.label &&
                box[3] >= prevBox[1] &&
                abs(box[1] - prevBox[3]) < max(prevBox[3] - prevBox[1], box[3] - box[1]) * 0.5f &&
                (aligned(box[0], prevBox[0]) != aligned(box[2], prevBox[2])) &&
                overlapsFixed(item.first, prev.first)
            if (isCross || isUp) {
                curIdx.add(item.first)
                curAlign.add(if (isCross) "center" else alignment(box, prevBox))
            } else {
                groups.add(Group(curIdx, curAlign))
                curIdx = arrayListOf(item.first)
                curAlign = arrayListOf()
            }
        }
        if (curIdx.isNotEmpty()) groups.add(Group(curIdx, curAlign))

        val result = ArrayList<Block>()
        val used = HashSet<Int>()
        var idx = 0
        while (idx < blocks.size) {
            var found = false
            for (range in groups) {
                val start = range.idx.minOrNull() ?: 0
                val end = range.idx.maxOrNull() ?: 0
                if (idx != start || range.idx.any { it in used }) continue
                found = true
                val imgs = range.idx.mapNotNull { blocks[it].image }
                val w = imgs.maxOfOrNull { it.width } ?: 0
                val h = imgs.sumOf { it.height }
                val tooTall = w == 0 || imgs.size != range.idx.size || h.toDouble() / w >= 3.0
                if (tooTall) {
                    for (bi in range.idx) {
                        result.add(blocks[bi])
                        used.add(bi)
                    }
                } else {
                    val stitched = mergeImages(imgs, range.aligns)
                    for ((j, bi) in range.idx.withIndex()) {
                        val b = blocks[bi]
                        b.image = if (j == 0) stitched else null
                        result.add(b)
                        used.add(bi)
                    }
                }
                if (end > start) {
                    for (ni in (start + 1) until end) {
                        val extra = fixed[ni] ?: continue
                        result.add(extra)
                        used.add(ni)
                    }
                }
                idx = end + 1
                break
            }
            if (found) continue
            fixed[idx]?.let {
                result.add(it)
                used.add(idx)
            }
            idx += 1
        }
        return result
    }

    private fun mergeImages(images: List<Bitmap>, aligns: List<String>): Bitmap {
        if (images.size <= 1) return images[0]
        val offsets = IntArray(images.size)
        var mergedW = images[0].width
        for (i in 1 until images.size) {
            val img2W = images[i].width
            val stepW = max(mergedW, img2W)
            val align = aligns.getOrElse(i - 1) { "left" }
            val shift: Int
            val place: Int
            if (align == "center") {
                shift = (stepW - mergedW) / 2
                place = (stepW - img2W) / 2
            } else if (align == "right") {
                shift = stepW - mergedW
                place = stepW - img2W
            } else {
                shift = 0
                place = 0
            }
            for (k in 0 until i) offsets[k] += shift
            offsets[i] = place
            mergedW = stepW
        }
        val totalH = images.sumOf { it.height }
        val out = Bitmap.createBitmap(mergedW, totalH, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.drawColor(Color.WHITE)
        var y = 0
        for (i in images.indices) {
            canvas.drawBitmap(images[i], offsets[i].toFloat(), y.toFloat(), null)
            y += images[i].height
        }
        return out
    }
}
