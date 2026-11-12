package com.example.minicpm_v_demo

import com.example.minicpm_v_demo.OcrLayout.canvas
import com.example.minicpm_v_demo.OcrLayout.visionSize
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `visionSize` and `canvas` have to agree with mtmd's OCR preprocessor exactly:
 * the NPU graph is fed packed patches, so a one-token disagreement makes
 * llama_jni drop the embedding and fall back to ggml.
 *
 * Every expectation below was produced by transcribing `get_best_resize`,
 * `ensure_divide` and `mtmd_image_preprocessor_minicpmv::align_round` from
 * mtmd-image.cpp into a standalone C++ program and running it on the same
 * inputs, so this test pins the port to the original rather than to itself.
 */
class VisionSizeTest {

    @Test
    fun overviewMatchesMtmdOnOnePass() {
        // One get_best_resize pass, not a fixed point: mtmd runs it once. A crop
        // it upscales has two different answers and mtmd takes the first.
        assertEquals(1540 to 84, visionSize(1540, 85))
        assertEquals(84 to 1540, visionSize(86, 1540))
        assertEquals(1008 to 28, visionSize(1000, 30))
        assertEquals(2492 to 56, visionSize(2500, 60))
        assertEquals(448 to 448, visionSize(448, 448))
        assertEquals(448 to 448, visionSize(2000, 2000))
        assertEquals(448 to 448, visionSize(100, 100))
        assertEquals(476 to 420, visionSize(448, 400))
        assertEquals(504 to 392, visionSize(500, 400))
        assertEquals(364 to 532, visionSize(595, 842))
        assertEquals(644 to 308, visionSize(938, 440))
        assertEquals(1624 to 112, visionSize(4000, 300))
        assertEquals(700 to 84, visionSize(702, 75))
        assertEquals(644 to 112, visionSize(643, 106))
        assertEquals(756 to 252, visionSize(786, 268))
    }

    @Test
    fun smallCropsAreUpscaledOnceNotToAFixedPoint() {
        // 435x36 is upscaled to 1540x140 = 275 tokens in one pass. Iterating
        // would settle at 1428x140 = 255 and every such crop would fall back to
        // ggml -- this is the regression that showed up on the device.
        assertEquals(1540 to 140, visionSize(435, 36))
        assertEquals(275, (1540 / 14 / 2) * (140 / 14 / 2))
    }

    @Test
    fun overCanvasOverviewsKeepWidthAndDropBottomRows() {
        // The ANE path fills patches row-major and stops at max_patches, so the
        // width survives and the bottom rows go. Doing the same here keeps every
        // column of a wide table instead of shaving the long side.
        //
        // Each line: crop, the grid it is reduced to, and the source region kept.
        val cases = listOf(
            // from the device run: mtmd wanted 275 tokens before, 1100 patches
            Triple(435 to 36, 1540 to 112, 435 to 28),
            Triple(300 to 200, 560 to 336, 300 to 184),
            Triple(3000 to 2000, 560 to 336, 3000 to 1846),
            Triple(1020 to 400, 728 to 252, 1020 to 360),
            Triple(1234 to 567, 672 to 280, 1234 to 515),
            Triple(560 to 364, 560 to 336, 560 to 336),
            Triple(672 to 308, 672 to 280, 672 to 280),
        )
        for ((src, target, region) in cases) {
            val plan = canvas(src.first, src.second)
            assertEquals("$src target", target, plan.targetW to plan.targetH)
            assertEquals("$src region", region, plan.srcW to plan.srcH)
            assertTrue("$src must be cropped", plan.cropped)
            assertTrue("$src must fit", plan.fitsCanvas)
            assertEquals("$src tokens", plan.tokens, plan.patches / 4)
            // Only rows may be dropped, never columns -- that is the whole point.
            assertEquals("$src lost columns", src.first, plan.srcW)
        }
    }

    @Test
    fun extremeAspectStillTrimsWidthToFit() {
        // A 500:1 strip cannot fit 1024 patches in two rows without narrowing,
        // and here the width has to shrink too -- otherwise mtmd derives a wider
        // grid than the NPU ran.
        val plan = canvas(10000, 20)
        assertEquals(7168 to 28, plan.targetW to plan.targetH)
        assertTrue("must be cropped", plan.cropped)
        assertEquals(1024, plan.patches)
        assertTrue("width must shrink", plan.srcW < 10000)
    }

    @Test
    fun uncroppedCropsAreLeftAlone() {
        // Cropping must not kick in where the overview already fits, or every
        // crop would lose its edges.
        val fits = listOf(
            Triple(448 to 448, 448 to 448, 448 to 448),
            Triple(1540 to 85, 1540 to 84, 1540 to 85),
            Triple(595 to 842, 364 to 532, 595 to 842),
            Triple(938 to 440, 644 to 308, 938 to 440),
            Triple(896 to 224, 896 to 224, 896 to 224),
            Triple(488 to 698, 364 to 532, 488 to 698),
            Triple(786 to 268, 756 to 252, 786 to 268),
        )
        for ((src, target, region) in fits) {
            val plan = canvas(src.first, src.second)
            assertEquals("$src target", target, plan.targetW to plan.targetH)
            assertEquals("$src region", region, plan.srcW to plan.srcH)
            assertFalse("$src must not be cropped", plan.cropped)
        }
    }

    @Test
    fun canvasGridMatchesWhatMtmdWouldDerive() {
        // When cropping, mtmd is handed the cropped bitmap, so the cropped grid
        // must be one mtmd leaves alone -- 28-aligned, inside the 448x448 area
        // budget, and past 448 on one side (otherwise mtmd upscales it).
        val cases = listOf(300 to 200, 1234 to 567, 435 to 36, 1020 to 400, 672 to 308)
        for ((w, h) in cases) {
            val plan = canvas(w, h)
            assertEquals("$w x $h not 28-aligned", 0, plan.targetW % 28)
            assertEquals("$w x $h not 28-aligned", 0, plan.targetH % 28)
            assertTrue("$w x $h over budget", plan.targetW.toLong() * plan.targetH <= 448L * 448L)
            assertTrue("$w x $h would be upscaled",
                plan.targetW > 448 || plan.targetH > 448)
        }
    }

    @Test
    fun alwaysProducesAUsableGrid() {
        for (w in 1..4000 step 173) {
            for (h in 1..4000 step 197) {
                val plan = canvas(w, h)
                assertTrue("$w x $h yields no tokens", plan.tokens > 0)
                assertTrue("$w x $h crop region is empty", plan.srcW > 0 && plan.srcH > 0)
                assertTrue("$w x $h region exceeds the crop", plan.srcW <= w && plan.srcH <= h)
                if (plan.fitsCanvas) {
                    // A cropped target must be one mtmd leaves alone; an
                    // uncropped one is mtmd's own answer and needs no check.
                    if (plan.cropped) {
                        assertEquals("$w x $h target not aligned", 0, plan.targetW % 28)
                        assertEquals("$w x $h target not aligned", 0, plan.targetH % 28)
                        assertTrue("$w x $h target over budget",
                            plan.targetW.toLong() * plan.targetH <= 448L * 448L)
                    }
                } else {
                    // Only degenerate crops keep an over-canvas overview; those
                    // are the ones OcrEngine skips.
                    assertFalse("$w x $h should not be over canvas", plan.patches <= 1024)
                }
            }
        }
    }
}
