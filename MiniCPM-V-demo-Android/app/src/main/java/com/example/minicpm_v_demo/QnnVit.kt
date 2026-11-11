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
    /** Name used before per-architecture binaries existed; still honoured. */
    const val DEFAULT_BINARY_NAME = "minicpm-ocr-qnn.bin"

    /** File name of the context binary for one Hexagon generation. */
    fun binaryNameFor(arch: Int): String = "minicpm-ocr-qnn-v$arch.bin"

    /**
     * Hexagon generation of this device, as QAIRT numbers it (69, 73, 75, 85),
     * or 0 while unknown. A context binary is compiled for exactly one
     * generation, so this decides which file to load.
     */
    @Volatile
    private var arch: Int = 0

    @Volatile
    private var state: State = State.ABSENT

    private enum class State { ABSENT, READY, FAILED }

    /**
     * Hexagon generation this device would use, or null when the NPU path is not
     * available or not worth trying. Used by the downloader to fetch exactly one
     * context binary, so it must work without any QNN library loaded.
     */
    fun deviceArch(context: Context): Int? {
        if (!hardwarePresent()) return null
        val candidate = candidateArch(context)
        return if (candidate > 0) candidate else null
    }

    /**
     * SoC to Hexagon generation.
     *
     * This is a lookup, not a guess about capability: the QNN backend is only
     * touched when the mapped generation has both a skeleton in this APK and a
     * binary on the model repo, and even then the driver has to confirm the
     * generation before a session is opened. Anything absent from this table
     * stays on the CPU vision tower, which is slower but always correct.
     */
    private val SOC_TO_ARCH = linkedMapOf(
        85 to setOf("SM8750", "SM8750P", "SM8975"),                  // 8 Elite, 8 Elite Gen 5
        75 to setOf("SM8650", "SM8550", "SM7550", "SM7675"),          // 8 Gen 3, 8 Gen 2, 7+ Gen 3, 7+ Gen 2
        73 to setOf("SM8450", "SM8350", "SM7325"),                   // 8 Gen 1, 888, 778G
        69 to setOf("SM8250", "SM8150", "SM7250"),                   // 865, 855, 765G
    )

    private val socName: String
        get() = (android.os.Build.SOC_MODEL ?: "").uppercase()
            .ifEmpty { readProp("ro.soc.model").uppercase() }

    private fun readProp(name: String): String = try {
        val p = Runtime.getRuntime().exec(arrayOf("getprop", name))
        p.inputStream.bufferedReader().use { it.readText() }.trim().also { p.waitFor() }
    } catch (t: Throwable) {
        ""
    }

    /** Generation this build can serve on this device, or 0 when it cannot. */
    private fun candidateArch(context: Context): Int {
        val soc = socName
        if (soc.isEmpty()) {
            Log.i(TAG, "SoC model unknown; OCR will use the ggml vision tower")
            return 0
        }
        for ((candidate, socs) in SOC_TO_ARCH) {
            if (socs.none { soc.startsWith(it) }) continue
            if (hasSkel(context, candidate)) return candidate
            Log.i(TAG, "this build ships no skeleton for Hexagon v$candidate")
            return 0
        }
        Log.i(TAG, "SoC '${soc}' has no QNN build; OCR will use the ggml vision tower")
        return 0
    }

    private fun hasSkel(context: Context, candidate: Int): Boolean = try {
        context.assets.open("qnn/libQnnHtpV${candidate}Skel.so").close()
        true
    } catch (e: java.io.IOException) {
        false
    }

    /**
     * True when this device has a Hexagon DSP at all.
     *
     * Checked before anything QNN is loaded: deviceCreate() on a part with no
     * DSP aborts the process instead of returning an error, and a native abort
     * is not catchable from Kotlin. The Adreno/FastRPC transport is the cheapest
     * reliable signal, and it rules out MediaTek, Exynos and Kirin outright.
     */
    private fun hardwarePresent(): Boolean {        val markers = listOf(
            "/dev/adsprpc-smd",
            "/dev/adsprpc-smd-secure",
            "/vendor/lib64/libcdsprpc.so",
            "/system/lib64/libcdsprpc.so",
        )
        val found = markers.any { File(it).exists() }
        if (!found) {
            Log.i(TAG, "no FastRPC transport; OCR will use the ggml vision tower")
        }
        return found
    }

    /**
     * Context binary for this generation, or null when it has not been fetched.
     *
     * Names are `minicpm-ocr-qnn-v<arch>.bin`, matching what the downloader
     * requests. The legacy unsuffixed name is still accepted so an install that
     * was provisioned by hand before multi-arch support keeps working.
     */
    private fun findBinary(context: Context, arch: Int): File? {
        val canonical = LlamaEngine.qnnVitPath(context)?.let { File(it) }
        val dirs = listOfNotNull(canonical?.parentFile, qnnDir(context))

        for (d in dirs) {
            File(d, binaryNameFor(arch)).takeIf { it.isFile }?.let { return it }
        }
        for (d in dirs) {
            File(d, DEFAULT_BINARY_NAME).takeIf { it.isFile }?.let { return it }
        }
        return null
    }

    /**
     * Brings the NPU session up. Cheap to call repeatedly: after the first
     * success it returns immediately. Must not run on the main thread, because
     * the context binary is ~868 MiB and loading it takes a few hundred ms plus
     * the DSP spawn.
     */
    @Synchronized
    fun ensureReady(context: Context): Boolean {
        when (state) {
            State.READY -> return true
            State.FAILED -> return false
            State.ABSENT -> Unit
        }

        // Nothing QNN-shaped happens until the part is known to be one this
        // build can serve: the transport check rules out non-Qualcomm silicon,
        // and candidateArch() rules out Qualcomm parts whose DSP generation has
        // no binary or skeleton here. See VALIDATED_SOCS for why that gate is
        // not merely an optimisation.
        if (!hardwarePresent()) {
            state = State.FAILED
            return false
        }
        val candidate = candidateArch(context)
        if (candidate <= 0) {
            state = State.FAILED
            return false
        }

        return try {
            System.loadLibrary("minicpm_v_demo")
            arch = candidate
            val bin = findBinary(context, arch)
            if (bin == null) {
                Log.i(TAG, "no context binary for Hexagon v$arch; " +
                        "OCR will use the ggml vision tower")
                state = State.FAILED
                return false
            }

            val skelDir = extractSkel(context, arch)
            if (skelDir == null) {
                state = State.FAILED
                return false
            }
            // The JNI entry points live in the same shared library as the rest
            // of the app's native code. Normally LlamaEngine loads it; the OCR
            // path may reach here first, so make it idempotent.
            System.loadLibrary("QnnHtp")
            System.loadLibrary("QnnSystem")

            val rc = nativeInit(skelDir.absolutePath, bin.absolutePath, arch)
            state = if (rc == 0) State.READY else State.FAILED
            Log.i(TAG, "NPU init arch=v$arch rc=$rc state=$state")
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
        if (state != State.READY) return false
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
     *
     * One skel per Hexagon generation is packaged; only the matching one is
     * extracted, keyed by arch so moving between devices never reuses the wrong
     * one. Returns null when this build has no skel for the device.
     */
    private fun extractSkel(context: Context, arch: Int): File? {
        val name = "libQnnHtpV${arch}Skel.so"
        val dir = File(qnnDir(context), "libs-v$arch").apply { mkdirs() }
        val skel = File(dir, name)
        if (skel.isFile && skel.length() > 0) return dir
        return try {
            context.assets.open("qnn/$name").use { input ->
                skel.outputStream().use { output -> input.copyTo(output) }
            }
            Log.i(TAG, "extracted skel to ${skel.absolutePath} (${skel.length()} bytes)")
            dir
        } catch (e: java.io.IOException) {
            Log.i(TAG, "this build ships no $name; OCR will use the ggml vision tower")
            null
        }
    }

    private external fun nativeInit(skelDir: String, binPath: String, arch: Int): Int
    private external fun nativeReady(): Boolean
    private external fun nativeShutdown()
    private external fun nativeEncode(rgba: ByteArray, posW: Int, posH: Int): Int
}
