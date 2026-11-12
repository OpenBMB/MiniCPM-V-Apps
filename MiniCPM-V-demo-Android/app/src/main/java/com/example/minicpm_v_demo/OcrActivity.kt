package com.example.minicpm_v_demo

import android.Manifest
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.media.ExifInterface
import android.net.Uri
import android.os.Bundle
import android.text.TextPaint
import android.util.Log
import android.util.TypedValue
import android.view.View
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import io.noties.markwon.Markwon
import io.noties.markwon.ext.latex.JLatexMathPlugin
import io.noties.markwon.inlineparser.MarkwonInlineParserPlugin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * MiniCPM-OCR page. The chat activity is not kept underneath, so leaving
 * here only unloads weights and leaves the native runtime up for the next chat.
 */
class OcrActivity : AppCompatActivity() {
    private lateinit var tvStatus: TextView
    private lateinit var tvResult: TextView
    private lateinit var scrollResult: ScrollView
    private lateinit var ivPreview: ImageView
    private lateinit var btnPdf: ImageButton
    private lateinit var btnGallery: ImageButton
    private lateinit var btnCamera: ImageButton
    private lateinit var btnCancel: com.google.android.material.button.MaterialButton

    private lateinit var engine: LlamaEngine
    private lateinit var ocr: OcrEngine
    private lateinit var markwon: Markwon
    private var createdWithLocale: String? = null
    private var loadStarted = false
    private var pendingPath: String? = null
    private var running = false
    private var job: Job? = null
    private var cameraUri: Uri? = null

    private val pickPdf = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) runDocument(uri)
    }

    private val pickAlbum = registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) runDocument(uri)
    }

    private val takePicture = registerForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val uri = cameraUri
        if (ok && uri != null) runDocument(uri)
    }

    private val requestCamera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) launchCamera() else {
            Toast.makeText(this, R.string.ocr_camera_denied, Toast.LENGTH_SHORT).show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createdWithLocale = LocaleManager.currentLanguage(this).tag
        if (!LlamaEngine.getSelectedModel(applicationContext).isOcr) {
            startActivity(Intent(this, MainActivity::class.java))
            finish()
            return
        }
        setContentView(R.layout.activity_ocr)

        // Edge-to-edge: pad for status/nav bars and the IME. Without this the
        // toolbar draws under the status bar, which hides the title and makes
        // the settings button untappable. Same approach as MainActivity.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val rootContent = findViewById<View>(android.R.id.content)
        ViewCompat.setOnApplyWindowInsetsListener(rootContent) { v, insets ->
            val sysBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
            v.updatePadding(
                left = sysBars.left,
                top = sysBars.top,
                right = sysBars.right,
                bottom = maxOf(sysBars.bottom, ime.bottom)
            )
            insets
        }

        tvStatus = findViewById(R.id.tv_status)
        tvResult = findViewById(R.id.tv_result)
        scrollResult = findViewById(R.id.scroll_result)
        ivPreview = findViewById(R.id.iv_preview)
        btnPdf = findViewById(R.id.btn_pdf)
        btnGallery = findViewById(R.id.btn_gallery)
        btnCamera = findViewById(R.id.btn_camera)
        btnCancel = findViewById(R.id.btn_cancel)
        markwon = buildMarkwon()
        engine = LlamaEngine.getInstance(applicationContext)
        ocr = OcrEngine(engine, applicationContext)

        findViewById<android.view.View>(R.id.btn_model_manager).setOnClickListener {
            startActivity(Intent(this, ModelManagerActivity::class.java))
        }
        btnPdf.setOnClickListener { pickPdf.launch(arrayOf("application/pdf")) }
        btnGallery.setOnClickListener { pickAlbum.launch("image/*") }
        btnCamera.setOnClickListener { requestCamera.launch(Manifest.permission.CAMERA) }
        btnCancel.setOnClickListener {
            ocr.cancelRequested = true
            engine.cancelGeneration()
            tvStatus.setText(R.string.ocr_status_cancel)
        }
        setBusy(false)
        pendingPath = intent?.getStringExtra(EXTRA_OCR_PATH)
        ensureModel()
    }

    override fun onResume() {
        super.onResume()
        val currentTag = LocaleManager.currentLanguage(this).tag
        if (createdWithLocale != null && createdWithLocale != currentTag) {
            LocaleManager.recreateSeamlessly(this)
            return
        }
        if (!LlamaEngine.getSelectedModel(applicationContext).isOcr) {
            leaveForChat()
            return
        }
        if (!loadStarted) ensureModel()
    }

    override fun onDestroy() {
        job?.cancel()
        ocr.cancelRequested = true
        if (::engine.isInitialized) engine.cancelGeneration()
        // Always release, never gated on `running`: skipping this leaks the
        // 856 MiB NPU context and the loaded weights. QnnVit.shutdown() takes
        // the same native mutex as an in-flight encode, so it waits for that
        // to finish instead of pulling the session out from under it.
        if (::ocr.isInitialized) ocr.close()
        super.onDestroy()
    }

    private fun leaveForChat() {
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                if (engine.state.value is LlamaState.ModelReady) engine.unloadModel()
            } catch (e: Exception) {
                Log.w(TAG, "unload before chat failed", e)
            }
            withContext(Dispatchers.Main) {
                val intent = Intent(this@OcrActivity, MainActivity::class.java)
                intent.flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                startActivity(intent)
                finish()
            }
        }
    }

    private fun ensureModel() {
        if (!LlamaEngine.modelsExist(this)) {
            promptDownload()
            return
        }
        loadStarted = true
        tvStatus.setText(R.string.ocr_status_loading)
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                val ready = engine.state.first {
                    it is LlamaState.Initialized || it is LlamaState.ModelReady || it is LlamaState.Error
                }
                if (ready is LlamaState.Error) throw ready.exception
                if (ready is LlamaState.ModelReady) engine.unloadModel()
                val gguf = LlamaEngine.modelPath(applicationContext)
                val mmproj = LlamaEngine.mmprojPath(applicationContext)
                engine.loadModel(
                    gguf,
                    mmproj,
                    imageMaxSliceNums = 9,
                    nCtx = 12288,
                    temperature = 0.01f,
                    topK = 1,
                    topP = 0.001f,
                    nUbatch = 512,
                )
                withContext(Dispatchers.Main) {
                    tvStatus.setText(R.string.ocr_status_ready)
                    setBusy(false)
                    startPendingPath()
                }
            } catch (e: Exception) {
                Log.e(TAG, "ocr model load failed", e)
                loadStarted = false
                withContext(Dispatchers.Main) {
                    tvStatus.text = getString(R.string.toast_model_load_failed, e.message)
                }
            }
        }
    }

    private fun promptDownload() {
        AlertDialog.Builder(this)
            .setTitle(R.string.download_prompt_title)
            .setMessage(R.string.download_prompt_all_missing)
            .setPositiveButton(R.string.go_download) { _, _ ->
                startActivity(Intent(this, ModelManagerActivity::class.java))
            }
            .setNegativeButton(R.string.later, null)
            .show()
    }

    private fun launchCamera() {
        val dir = File(cacheDir, "ocr").apply { mkdirs() }
        val file = File(dir, "capture.jpg")
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        cameraUri = uri
        takePicture.launch(uri)
    }

    private fun runDocument(uri: Uri) {
        if (engine.state.value !is LlamaState.ModelReady || running) {
            Toast.makeText(this, R.string.toast_load_model_first, Toast.LENGTH_SHORT).show()
            return
        }
        ocr.cancelRequested = false
        setBusy(true)
        tvResult.text = ""
        job = lifecycleScope.launch(Dispatchers.IO) {
            // Held so the finally block can free every decoded page, whether
            // the run finished, failed, or was cancelled by onDestroy.
            var pages: List<Bitmap> = emptyList()
            try {
                pages = decodePages(uri)
                if (pages.isEmpty()) error(getString(R.string.ocr_decode_failed))
                val parts = ArrayList<String>()
                for ((index, page) in pages.withIndex()) {
                    if (ocr.cancelRequested) break
                    withContext(Dispatchers.Main) {
                        tvStatus.text = getString(R.string.ocr_status_page, index + 1, pages.size)
                        // Every crop already ends with its own two newlines, so
                        // only top up when starting from a non-empty buffer.
                        if (parts.isNotEmpty() && !tvResult.text.endsWith("\n\n")) {
                            tvResult.append("\n\n")
                            scrollResultToBottom()
                        }
                    }
                    val pageText = StringBuilder()
                    val markdown = ocr.recognizePage(
                        page,
                        onStatus = { label ->
                            withContext(Dispatchers.Main) {
                                tvStatus.text = getString(
                                    R.string.ocr_status_block, index + 1, pages.size, label
                                )
                            }
                        },
                        onPreview = { preview ->
                            val copy = preview.copy(Bitmap.Config.ARGB_8888, false)
                            withContext(Dispatchers.Main) { ivPreview.setImageBitmap(copy) }
                        },
                        onToken = { token ->
                            pageText.append(token)
                            withContext(Dispatchers.Main) {
                                tvResult.append(token)
                                scrollResultToBottom()
                            }
                        },
                    )
                    parts.add(markdown)
                }
                val joined = parts.joinToString(OcrEngine.PAGE_BREAK)
                Log.i(TAG, "ocr done chars=${joined.length}\n$joined")
                withContext(Dispatchers.Main) {
                    // Single-$ formulas are rewritten to $$ for the LaTeX plugin
                    // inside renderResult; the stored markdown stays standard.
                    renderResult(joined)
                    // The live view was pinned to the bottom; the final markdown
                    // replaces the whole buffer, so rewind to the top to read it.
                    scrollResult.scrollTo(0, 0)
                    tvStatus.setText(
                        if (ocr.cancelRequested) R.string.ocr_status_cancel else R.string.ocr_status_done
                    )
                }
            } catch (e: CancellationException) {
                // Normal path when the activity goes away mid-run: the stack
                // unwinds through here, so nothing below may suspend.
                Log.i(TAG, "ocr cancelled", e)
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "ocr failed", e)
                try {
                    withContext(Dispatchers.Main) {
                        tvStatus.text = getString(R.string.ocr_failed, e.message)
                    }
                } catch (_: CancellationException) {
                    // Activity is gone; the status line has nowhere to go.
                }
            } finally {
                // Must run even when the scope was cancelled: leaving `running`
                // stuck at true would make onDestroy() skip ocr.close() and
                // leak the 856 MiB NPU context plus the model weights.
                for (page in pages) {
                    if (!page.isRecycled) page.recycle()
                }
                withContext(NonCancellable + Dispatchers.Main) {
                    setBusy(false)
                }
            }
        }
    }

    /**
     * Keeps the live output pinned to the newest text. Called after every
     * append, so the deferred [View.post] runs once layout for that append has
     * been measured — scrolling immediately would use the pre-append height and
     * land one character short every time.
     */
    private fun scrollResultToBottom() {
        scrollResult.post {
            scrollResult.fullScroll(View.FOCUS_DOWN)
        }
    }

    private fun decodePages(uri: Uri): List<Bitmap> {
        val type = contentResolver.getType(uri).orEmpty()
        val name = uri.lastPathSegment.orEmpty().lowercase()
        if (type == "application/pdf" || name.endsWith(".pdf")) return decodePdf(uri)
        val bitmap = decodeImage(uri) ?: return emptyList()
        return listOf(bitmap)
    }

    private fun decodePdf(uri: Uri): List<Bitmap> {
        val pfd = contentResolver.openFileDescriptor(uri, "r") ?: return emptyList()
        pfd.use {
            PdfRenderer(it).use { renderer ->
                val pages = ArrayList<Bitmap>(renderer.pageCount)
                for (i in 0 until renderer.pageCount) {
                    renderer.openPage(i).use { page ->
                        val width = (page.width * 2).coerceAtLeast(1)
                        val height = (page.height * 2).coerceAtLeast(1)
                        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                        Canvas(bitmap).drawColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        pages.add(bitmap)
                    }
                }
                return pages
            }
        }
    }

    private fun decodeImage(uri: Uri): Bitmap? {
        val bitmap = contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
            ?: return null
        val degrees = contentResolver.openInputStream(uri)?.use { input ->
            when (ExifInterface(input).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL
            )) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90
                ExifInterface.ORIENTATION_ROTATE_180 -> 180
                ExifInterface.ORIENTATION_ROTATE_270 -> 270
                else -> 0
            }
        } ?: 0
        if (degrees == 0) return bitmap
        val rotated = OcrLayout.rotate(bitmap, degrees)
        if (rotated !== bitmap) bitmap.recycle()
        return rotated
    }

    /**
     * Markwon with math typesetting. The LaTeX plugin draws formulas into
     * bitmaps at an explicit pixel size and needs an explicit colour, since
     * jlatexmath's own default is black and this theme has a night variant.
     */
    private fun buildMarkwon(): Markwon {
        val textSizePx = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_SP, 15f, resources.displayMetrics
        )
        val plugin = JLatexMathPlugin.builder(textSizePx)
        plugin.inlinesEnabled(true)
        plugin.blocksEnabled(true)
        plugin.errorHandler { latex, error ->
            // Returning null leaves the formula undrawn and logs why; drawing a
            // placeholder box would be worse than the gap. The loader checks for
            // null explicitly, so this is a supported outcome, not a bug.
            Log.w(TAG, "latex failed: $latex", error)
            null
        }
        // theme() hands back the mutable theme builder the plugin already holds,
        // so the colour set here is picked up by build().
        plugin.theme().textColor(resolveOnSurfaceColor())

        return Markwon.builder(this)
            // JLatexMathPlugin's inline processor requires the inline parser to
            // be registered explicitly; it is a dependency, not an auto-plugin.
            .usePlugin(MarkwonInlineParserPlugin.create())
            .usePlugin(JLatexMathPlugin.create(plugin.build()))
            .build()
    }

    private fun resolveOnSurfaceColor(): Int {
        val value = TypedValue()
        theme.resolveAttribute(com.google.android.material.R.attr.colorOnSurface, value, true)
        return value.data
    }

    /**
     * Renders the finished page. Tables are lifted out and drawn as spans
     * because Markwon drops `<table>` blocks (see [OcrTableMarkdown]).
     *
     * A table span cannot know its width until the text view has been laid
     * out, so the first pass measures against whatever is known (often zero
     * right after a page finishes); the span re-measures on its first draw and
     * asks for a relayout. Only the layout repeats, not the markdown parsing.
     */
    private fun renderResult(markdown: String) {
        val width = (tvResult.width - tvResult.paddingLeft - tvResult.paddingRight)
            .coerceAtLeast(0)
        val basePaint = TextPaint(tvResult.paint)
        val spanned = OcrTableMarkdown.render(markwon, markdown, tableStyle, basePaint, width) {
            // Called from inside a draw pass, so queue the relayout.
            tvResult.post { tvResult.requestLayout() }
        }
        // setParsedMarkdown rather than setText so CorePlugin attaches
        // TextViewSpan -- the table spans read their width back through it --
        // and the LaTeX plugin schedules its draws.
        markwon.setParsedMarkdown(tvResult, spanned)
    }

    /** Table colours follow the theme so dark mode does not show white blocks. */
    private val tableStyle: OcrTableStyle
        get() {
            val dark = (resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                android.content.res.Configuration.UI_MODE_NIGHT_YES
            val onSurface = resolveOnSurfaceColor()
            return OcrTableStyle(
                textSize = TypedValue.applyDimension(
                    TypedValue.COMPLEX_UNIT_SP, 13f, resources.displayMetrics
                ),
                textColor = onSurface,
                headerBackground = if (dark) 0x33FFFFFF else 0x14000000,
                oddRowBackground = if (dark) 0x14FFFFFF else 0x0A000000,
                borderColor = if (dark) 0x4DFFFFFF.toInt() else 0x33000000,
                cellPadding = (6 * resources.displayMetrics.density).toInt(),
                borderWidth = maxOf(1, resources.displayMetrics.density.toInt()),
            )
        }

    private fun setBusy(busy: Boolean) {
        running = busy
        btnPdf.isEnabled = !busy
        btnGallery.isEnabled = !busy
        btnCamera.isEnabled = !busy
        btnCancel.isEnabled = busy
        btnCancel.visibility = if (busy) android.view.View.VISIBLE else android.view.View.GONE
    }

    private fun startPendingPath() {
        val path = pendingPath ?: return
        pendingPath = null
        val file = File(path)
        if (!file.isFile) {
            Log.e(TAG, "ocr path missing: $path")
            return
        }
        runDocument(Uri.fromFile(file))
    }

    companion object {
        private const val TAG = "OcrActivity"
        const val EXTRA_OCR_PATH = "ocr_path"
    }
}
