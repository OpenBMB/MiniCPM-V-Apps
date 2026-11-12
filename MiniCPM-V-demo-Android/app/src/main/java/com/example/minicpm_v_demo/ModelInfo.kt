package com.example.minicpm_v_demo

import android.content.Context

/**
 * Metadata for a downloadable MiniCPM-V variant.
 *
 * Source-of-truth for download URLs: HuggingFace ([hfRepo]) and ModelScope
 * ([msRepo]) are both registered for every model, and `LlamaEngine`'s
 * downloader runs them in a **race**: both GETs are launched in parallel and
 * the first one to deliver HTTP headers wins; the loser's connection is
 * closed immediately. Mirrors iOS opt-r1's `MBModelDownloadHelperV2.downloadV2`
 * so all three demos consume the same upstream artifacts via the same
 * topology (no OBS direct link).
 *
 * The previously used [directGgufUrl] / [directMmprojUrl] knobs are retained
 * as an optional escape hatch — if a model ever needs a temporary mirror
 * during a TestFlight period they can be set and the racer treats them as a
 * third source — but for the current release lineup they stay null.
 *
 * [ggufRemoteName] and [mmprojRemoteName] decouple the on-disk filename from
 * the path segment on HF/MS. MiniCPM-V-4.6 stores mmproj as
 * `mmproj-model-merger-f16.gguf` locally (to avoid colliding with stale
 * pre-release files left in the per-model directory) but the upstream HF/MS
 * object is `mmproj-model-f16.gguf`.
 *
 * When [ggufMd5] / [mmprojMd5] are provided, the downloader verifies the
 * downloaded file's MD5 and deletes + raises on mismatch. Mirrors iOS demo
 * `MBV4ModelDownloadManager` / `MBV46ModelDownloadManager`.
 */
data class ModelInfo(
    val id: String,
    val displayName: String,
    val descriptionResName: String,
    val ggufFileName: String,
    val mmprojFileName: String? = null,
    val acousticFileName: String? = null,
    val layoutFileName: String? = null,
    /**
     * Optional QNN context binary for the OCR vision tower. Registered here so
     * the artifact has a declared home, but it has **no** remote path yet: it
     * is an offline QAIRT conversion that has to be produced per SoC, so the
     * downloader never fetches it and the app falls back to the ggml vision
     * tower whenever the file is absent. See QnnVit for the manual push.
     */
    val qnnVitFileName: String? = null,
    val hfRepo: String? = null,
    val msRepo: String? = null,
    val hfBranch: String = "main",
    val msBranch: String = "master",
    val ggufRemoteName: String? = null,
    val mmprojRemoteName: String? = null,
    val acousticRemoteName: String? = null,
    val layoutRemoteName: String? = null,
    val directGgufUrl: String? = null,
    val directMmprojUrl: String? = null,
    val directAcousticUrl: String? = null,
    val ggufMd5: String? = null,
    val mmprojMd5: String? = null,
    val acousticMd5: String? = null,
    val layoutMd5: String? = null,
) {
    /** True for text-only models that have no vision projector. */
    val isTextOnly: Boolean
        get() = mmprojFileName == null && acousticFileName == null

    /** True for TTS (text-to-speech) models with acoustic component. */
    val isTts: Boolean
        get() = acousticFileName != null

    /** MiniCPM-OCR 1.0: LLM + 4x mmproj + PP-DocLayoutV3 ONNX. */
    val isOcr: Boolean
        get() = layoutFileName != null

    /** MiniCPM5 (text) and MiniCPM-V-4.6 expose a thinking toggle. */
    val supportsThinking: Boolean
        get() = isTextOnly || id == "minicpm-v-4_6-instruct"

    fun getDescription(context: Context): String {
        val resId = context.resources.getIdentifier(descriptionResName, "string", context.packageName)
        return if (resId != 0) context.getString(resId) else descriptionResName
    }

    /** Path segment to request on HF/MS for the gguf, falling back to local name. */
    val ggufRemotePath: String
        get() = ggufRemoteName ?: ggufFileName

    /** Path segment to request on HF/MS for the mmproj, falling back to local name. */
    val mmprojRemotePath: String?
        get() = mmprojFileName?.let { mmprojRemoteName ?: it }

    /** Path segment to request on HF/MS for the acoustic GGUF, falling back to local name. */
    val acousticRemotePath: String?
        get() = acousticFileName?.let { acousticRemoteName ?: it }

    /** Path segment to request on HF/MS for the layout ONNX, falling back to local name. */
    val layoutRemotePath: String?
        get() = layoutFileName?.let { layoutRemoteName ?: it }

    /** Whether the model registers a direct (non-HF/MS) mirror URL for all required files. */
    val hasDirectUrls: Boolean
        get() = if (isTextOnly) !directGgufUrl.isNullOrBlank()
                else !directGgufUrl.isNullOrBlank() && !directMmprojUrl.isNullOrBlank()

    /** Whether the model registers HF + MS repos for racing. */
    val hasHfMsSources: Boolean
        get() = !hfRepo.isNullOrBlank() && !msRepo.isNullOrBlank()

    companion object {
        val AVAILABLE_MODELS = listOf(
            ModelInfo(
                id = "minicpm-v-4",
                displayName = "MiniCPM-V-4 (Q4_K_M)",
                descriptionResName = "model_desc_v4",
                ggufFileName = "ggml-model-Q4_K_M.gguf",
                mmprojFileName = "mmproj-model-f16.gguf",
                hfRepo = "openbmb/MiniCPM-V-4-gguf",
                msRepo = "OpenBMB/MiniCPM-V-4-gguf"
                // No MD5 here on purpose: HF / ModelScope serve via git-LFS
                // which already provides hash-based integrity checks.
            ),
            // MiniCPM-V-4.6: HF (primary) + ModelScope (backup) racing, aligned
            // with iOS opt-r1's MBV46ModelDownloadManager. Both the local and
            // the remote file names are now the upstream-canonical
            // `mmproj-model-f16.gguf`: upstream master mtmd accepts the
            // OpenBMB-published `minicpmv4_6` projector type natively, so the
            // previous demo-private "merger" re-conversion is no longer
            // required. STALE_MMPROJ_NAMES handles cleanup of the legacy
            // `*-merger-*` file from earlier demo builds.
            ModelInfo(
                id = "minicpm-v-4_6-instruct",
                displayName = "MiniCPM-V-4.6 (Q4_K_M)",
                descriptionResName = "model_desc_v46",
                ggufFileName = "MiniCPM-V-4_6-Q4_K_M.gguf",
                mmprojFileName = "mmproj-model-f16.gguf",
                hfRepo = "openbmb/MiniCPM-V-4.6-gguf",
                msRepo = "OpenBMB/MiniCPM-V-4.6-gguf",
                ggufMd5 = "fd778481dd56b6036dd8f9cf7c1519cf",
                // OpenBMB original (projector_type=minicpmv4_6), as served by
                // both HuggingFace and ModelScope. Replaces the previous
                // OBS-only `aad0d36e..` merger-converted variant.
                mmprojMd5 = "54aea6e04d752f47309a48f12795a1a3"
            ),
            // MiniCPM5-1B: text-only model, no mmproj needed. Switched from the
            // pre-release OBS direct link to OpenBMB's official HF (primary) +
            // ModelScope (backup) GGUF repos now that the model is publicly
            // released. The repo serves Q4_K_M / Q8_0 / F16 variants under the
            // canonical `MiniCPM5-1B-*.gguf` naming; LEGACY_FILE_RENAMES below
            // is intentionally empty because the pre-release `0.9B` variant
            // was re-converted (different gguf metadata / different bytes), so
            // any local copy must be re-downloaded rather than renamed.
            ModelInfo(
                // id kept as the original pre-release identifier so the
                // per-model directory `{root}/minicpm5-0.9b/` is still found
                // for users upgrading from v1.3. The user-facing display name
                // and the on-disk gguf filename track the post-release `1B`
                // canonical naming.
                id = "minicpm5-0.9b",
                displayName = "MiniCPM5-1B (Q4_K_M)",
                descriptionResName = "model_desc_minicpm5",
                ggufFileName = "MiniCPM5-1B-Q4_K_M.gguf",
                hfRepo = "openbmb/MiniCPM5-1B-GGUF",
                msRepo = "OpenBMB/MiniCPM5-1B-GGUF"
                // No MD5 here on purpose: HF / ModelScope serve via git-LFS
                // which already provides hash-based integrity checks.
            ),
            // MiniCPM5-2B: text-only, same HF + ModelScope race as 1B now
            // that the official GGUF repos are public. No MD5 on purpose:
            // git-LFS already hashes the object. The pre-release OBS copy
            // is 160 bytes smaller than the published Q4_K_M; downloadFile
            // will replace it when the user taps Download again.
            ModelInfo(
                id = "minicpm5-2b",
                displayName = "MiniCPM5-2B (Q4_K_M)",
                descriptionResName = "model_desc_minicpm5_2b",
                ggufFileName = "MiniCPM5-2B-Q4_K_M.gguf",
                hfRepo = "openbmb/MiniCPM5-2B-GGUF",
                msRepo = "OpenBMB/MiniCPM5-2B-GGUF"
            ),
            // VoxCPM2 — text-to-speech model, ~2B params, 48kHz output.
            // Two GGUF files: a BaseLM (the MiniCPM-4 based language model)
            // and an Acoustic bundle (FSQ + ResidualLM + LocEnc + LocDiT +
            // AudioVAE V2 + stop predictor + projections). Both are loaded
            // by VoxCPM2Runtime in llama.cpp-omni tools/omni/voxcpm2/.
            // HF: tc-mb/MiniCPM-V-Apps-gguf ; MS: zerg13/MiniCPM-V-Apps-gguf
            ModelInfo(
                id = "voxcpm2",
                displayName = "VoxCPM2",
                descriptionResName = "model_desc_voxcpm2",
                ggufFileName = "VoxCPM2-BaseLM-Q4_K_M.gguf",
                acousticFileName = "VoxCPM2-Acoustic-F16.gguf",
                hfRepo = "tc-mb/MiniCPM-V-Apps-gguf",
                msRepo = "zerg13/MiniCPM-V-Apps-gguf",
                directGgufUrl = null,
                directAcousticUrl = null,
                ggufMd5 = "d8cd571526464d225187d326caa289be",
                acousticMd5 = "0f16229cfffe935102d21433f6969f8b"
            ),
            // MiniCPM-OCR 1.0 — iOS-only until this entry. Three files under
            // MiniCPM-OCR-1.0/ on the same HF/MS repos the iOS demo races.
            // The 4x mmproj is not interchangeable with the chat mmproj.
            ModelInfo(
                id = "minicpm-ocr-1.0",
                displayName = "MiniCPM-OCR 1.0",
                descriptionResName = "model_desc_ocr",
                ggufFileName = "MiniCPM-OCR-1_0-Q4_K_M.gguf",
                mmprojFileName = "MiniCPM-OCR-1_0-mmproj-F16-4x.gguf",
                layoutFileName = "PPDocLayoutV3_fix4.onnx",
                qnnVitFileName = "vit_linear_1024.bin",
                hfRepo = "tc-mb/MiniCPM-V-Apps-gguf",
                msRepo = "zerg13/MiniCPM-V-Apps-gguf",
                ggufRemoteName = "MiniCPM-OCR-1.0/MiniCPM-OCR-1_0-Q4_K_M.gguf",
                mmprojRemoteName = "MiniCPM-OCR-1.0/MiniCPM-OCR-1_0-mmproj-F16-4x.gguf",
                layoutRemoteName = "MiniCPM-OCR-1.0/PPDocLayoutV3_fix4.onnx",
                ggufMd5 = "4f8f6f58429dc9a584c70c490a120dfd",
                mmprojMd5 = "5dc7d0b598700f10581bbbcc0e420056",
                layoutMd5 = "d1a03f12240c5ae0cad14155e6c2c41b",
            )
        )

        val DEFAULT_MODEL = AVAILABLE_MODELS.first()
    }
}
