package com.example.minicpm_v_demo

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import java.io.File
import java.nio.ByteBuffer

/**
 * Vision front-end for OCR, running the 4x ViT on the Hexagon HTP instead of
 * Vulkan.
 *
 * The tower is precompiled offline into a QNN context binary; this object only
 * keeps the session alive and pushes frames through it. Measured 791 ms per
 * image on SM8975/HTP V85 versus 25.3 s on the Vulkan ggml path, so the OCR
 * pipeline calls this whenever the binary is present and silently falls back to
 * ggml otherwise.
 *
 * The graph uses the CoreML/ANE canvas, `[1, 3, 14, 14336]`: 1024 patches laid
 * end to end. The shape is therefore grid-independent, and the caller passes
 * patches at native resolution with the tail left zero, so one binary serves
 * every aspect ratio. A square 448x448 canvas could not: layout boxes are
 * line-level with aspect ratios from 3 to 18, and squeezing a 1540x85 strip
 * into 448x448 throws away 71% of its horizontal detail.
 *
 * That freedom is not free -- the grid has to travel as graph inputs
 * (position buckets, 2x2 gather ids, padding mask), which is why [encode] takes
 * posW/posH and why only `(posH/2)*(posW/2)` of the 256 output rows are real.
 *
 * The image handed to [encode] must be exactly `posW*14 x posH*14` and its
 * patch grid must be the one mtmd derives from the same bitmap. See OcrEngine.
 */
object QnnVit {

    private const val TAG = "QnnVit"

    /** Side of one ViT patch; also what the graph input is built around. */
    const val PATCH = 14

    /** Patches the canvas holds; a grid must satisfy posW*posH <= this. */
    const val MAX_PATCHES = 1024

    /** Only used when the selected model declares no QNN artifact. */
    private const val DEFAULT_BINARY_NAME = "vit_linear_1024.bin"

    @Volatile
    private var state: State = State.ABSENT

    private enum class State { ABSENT, READY, FAILED }

    /** True once the binary exists and the NPU session came up. */
    val isReady: Boolean get() = state == State.READY

    /**
     * Locates the context binary. The model manifest names it, and the
     * downloader would place it in the per-model directory; the legacy
     * `files/qnn/` location is still honoured so an existing manual push keeps
     * working. Returns the canonical path when nothing exists yet.
     */
    fun binary(context: Context): File {
        val canonical = LlamaEngine.qnnVitPath(context)?.let { File(it) }
        if (canonical != null && canonical.isFile) return canonical

        // legacy manual-push location, from before the file was in the manifest
        val legacy = File(qnnDir(context), canonical?.name ?: DEFAULT_BINARY_NAME)
        if (legacy.isFile) return legacy

        return canonical ?: legacy
    }

    /**
     * Brings the NPU session up. Cheap to call repeatedly: after the first
     * success it returns immediately. Must not run on the main thread — the
     * context binary is 868 MiB and loading it takes a few hundred ms plus the
     * DSP spawn.
     */
    @Synchronized
    fun ensureReady(context: Context): Boolean {
        when (state) {
            State.READY -> return true
            State.FAILED -> return false
            State.ABSENT -> Unit
        }

        val bin = binary(context)
        if (!bin.isFile || bin.length() == 0L) {
            Log.i(TAG, "no ${bin.absolutePath}; OCR will use the ggml vision tower")
            state = State.FAILED
            return false
        }

        return try {
            val skelDir = extractSkel(context)
            // The JNI entry points live in the same shared library as the rest
            // of the app's native code. Normally LlamaEngine loads it; the OCR
            // path may reach here first, so make it idempotent.
            System.loadLibrary("minicpm_v_demo")
            System.loadLibrary("QnnHtp")
            System.loadLibrary("QnnSystem")

            val rc = nativeInit(skelDir.absolutePath, bin.absolutePath)
            state = if (rc == 0) State.READY else State.FAILED
            Log.i(TAG, "NPU init rc=$rc state=$state")
            state == State.READY
        } catch (t: Throwable) {
            Log.w(TAG, "NPU init threw, falling back to ggml", t)
            state = State.FAILED
            false
        }
    }

    fun shutdown() {
        if (state == State.READY) {
            try {
                nativeShutdown()
            } catch (t: Throwable) {
                Log.w(TAG, "NPU shutdown threw", t)
            }
        }
        state = State.ABSENT
    }

    /**
     * Encodes [bitmap], which must be exactly `posW*14 x posH*14`, and publishes
     * the embeddings for the next image chunk. Returns false when the NPU is not
     * usable, in which case the caller must let the ggml path run.
     *
     * The caller is responsible for the grid matching what mtmd will derive from
     * the same bitmap; a mismatch is caught downstream by the token-count check
     * in llama_jni rather than producing silent garbage.
     */
    fun encode(bitmap: Bitmap, posW: Int, posH: Int): Boolean {
        if (!isReady) return false
        if (posW <= 0 || posH <= 0 || posW * posH > MAX_PATCHES) {
            Log.w(TAG, "encode: grid ${posW}x$posH does not fit $MAX_PATCHES patches")
            return false
        }
        val wantW = posW * PATCH
        val wantH = posH * PATCH
        if (bitmap.width != wantW || bitmap.height != wantH) {
            Log.w(TAG, "encode expects ${wantW}x$wantH for a ${posW}x$posH grid, " +
                    "got ${bitmap.width}x${bitmap.height}")
            return false
        }
        val bytes = ByteArray(wantW * wantH * 4)
        bitmap.copyPixelsToBuffer(ByteBuffer.wrap(bytes))
        return nativeEncode(bytes, posW, posH) == 0
    }

    private fun qnnDir(context: Context): File = File(context.filesDir, "qnn").apply { mkdirs() }

    /**
     * The DSP skel has 0x1000 LOAD alignment, so shipping it in `jniLibs`
     * would break the 16 KB page-size requirement on Android 15+. It is
     * extracted to app storage instead and located through ADSP_LIBRARY_PATH,
     * which the native side sets before opening the backend.
     */
    private fun extractSkel(context: Context): File {
        val dir = File(qnnDir(context), "libs").apply { mkdirs() }
        val skel = File(dir, "libQnnHtpV85Skel.so")
        if (skel.isFile && skel.length() > 0) return dir
        context.assets.open("qnn/libQnnHtpV85Skel.so").use { input ->
            skel.outputStream().use { output -> input.copyTo(output) }
        }
        Log.i(TAG, "extracted skel to ${skel.absolutePath} (${skel.length()} bytes)")
        return dir
    }

    private external fun nativeInit(skelDir: String, binPath: String): Int
    private external fun nativeReady(): Boolean
    private external fun nativeShutdown()
    private external fun nativeEncode(rgba: ByteArray, posW: Int, posH: Int): Int
}
