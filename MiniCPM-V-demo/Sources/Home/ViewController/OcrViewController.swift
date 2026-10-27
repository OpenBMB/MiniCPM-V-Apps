//
//  OcrViewController.swift
//  MiniCPM-V-demo
//
//  OCR interface: camera/photo pick, layout view, markdown result display.
//  UIKit-based, child VC of MBHomeViewController.
//

import UIKit
import Combine
import SnapKit
import PhotosUI
import PDFKit
import ImageIO
import HXPhotoPicker

class OcrViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {

    // MARK: - Engine

    private let engine = OcrEngine.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - State

    private var selectedImage: UIImage?

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = UIColor.systemGray6
        iv.layer.cornerRadius = 8
        iv.clipsToBounds = true
        return iv
    }()

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = L.Ocr.placeholder.loc
        label.textColor = .secondaryLabel
        label.font = UIFont.systemFont(ofSize: 14)
        label.textAlignment = .center
        return label
    }()

    private let cameraBtn: UIButton = {
        let btn = UIButton(type: .system)
        let img = UIImage(systemName: "camera.fill")
        btn.setImage(img, for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.mb_color(with: "#007AFF")
        btn.layer.cornerRadius = 25
        return btn
    }()

    private let galleryBtn: UIButton = {
        let btn = UIButton(type: .system)
        let img = UIImage(systemName: "photo.on.rectangle")
        btn.setImage(img, for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.mb_color(with: "#5856D6")
        btn.layer.cornerRadius = 25
        return btn
    }()

    private let pdfBtn: UIButton = {
        let btn = UIButton(type: .system)
        let img = UIImage(systemName: "doc.text.fill")
        btn.setImage(img, for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.mb_color(with: "#FF3B30")
        btn.layer.cornerRadius = 25
        return btn
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .large)
        ai.hidesWhenStopped = true
        ai.color = .systemBlue
        return ai
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private let livePreviewContainer: UIView = {
        let v = UIView()
        v.backgroundColor = .secondarySystemBackground
        v.layer.cornerRadius = 8
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor.systemGray4.cgColor
        v.clipsToBounds = true
        v.isHidden = true
        return v
    }()

    private let liveTitleLeft: UILabel = {
        let l = UILabel()
        l.text = L.Ocr.liveOutput.loc
        l.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabel
        return l
    }()

    private let liveTitleRight: UILabel = {
        let l = UILabel()
        l.text = L.Ocr.currentArea.loc
        l.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabel
        return l
    }()

    private let liveSeparator: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.systemGray4
        return v
    }()

    private let liveStreamTextView: UITextView = {
        let tv = UITextView()
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.isEditable = false
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.textColor = .label
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.alwaysBounceVertical = true
        return tv
    }()

    private let liveCropPreviewView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = UIColor.systemGray6
        iv.layer.cornerRadius = 4
        iv.clipsToBounds = true
        return iv
    }()

    private let tableScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.alwaysBounceHorizontal = false
        sv.isScrollEnabled = false
        sv.bounces = false
        sv.clipsToBounds = true
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .secondarySystemBackground
        sv.layer.borderColor = UIColor.systemGray4.cgColor
        sv.layer.borderWidth = 1
        sv.layer.cornerRadius = 8
        return sv
    }()

    private let resultColumn: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        return stack
    }()

    private let resultTextView: TableFriendlyTextView = {
        let tv = TableFriendlyTextView(frame: .zero, textContainer: nil)
        tv.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isEditable = false
        tv.isScrollEnabled = false          // no internal scroll
        tv.alwaysBounceVertical = false
        tv.showsVerticalScrollIndicator = false
        tv.contentInsetAdjustmentBehavior = .never
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return tv
    }()

    private let toolBar: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.spacing = 12
        sv.distribution = .fillEqually
        return sv
    }()

    private let previewBtn: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("Preview", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = UIColor.mb_color(with: "#007AFF")
        btn.layer.cornerRadius = 8
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        return btn
    }()

    private let copyBtn: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("Copy", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = UIColor.mb_color(with: "#34C759")
        btn.layer.cornerRadius = 8
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        return btn
    }()

    // MARK: - State

    private var isPreviewMode = true
    private var rawMarkdown: String = ""
    private var multiPageTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    /// PDF preview slots. Each page's recognize() clears the engine slots and
    /// rewrites ocr_crop_{idx}_{label}.png, so the merged markdown has to keep
    /// its own copies. Nil means a single image, which still uses the engine slots.
    private var pdfPreviewSlots: [(index: Int, label: String)]?
    private var resultTextViewHeightConstraint: Constraint?
    private var renderedResult: NSAttributedString?
    private var livePreviewHeightConstraint: Constraint?
    /// Last `tableScrollView` width used for height measurement; relayout when it changes.
    private var lastMeasuredContainerWidth: CGFloat = 0

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Follow the app-wide appearance setting instead of forcing light.
        overrideUserInterfaceStyle = MBTheme.current.userInterfaceStyle
        view.backgroundColor = .systemGroupedBackground
        scrollView.backgroundColor = .systemGroupedBackground
        contentView.backgroundColor = .systemGroupedBackground
        setupUI()
        setupBindings()
        cameraBtn.isEnabled = false
        galleryBtn.isEnabled = false
        pdfBtn.isEnabled = false
        // Show loading indicator immediately, then kick off model load.
        // All engine methods are @MainActor — call directly, not inside Task {}.
        activityIndicator.startAnimating()
        statusLabel.text = L.Ocr.statusInitializing.loc
        loadModelsIfNeeded()
    }

    deinit {
        cancellables.removeAll()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        scrollView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.width.equalToSuperview()
        }

        imageView.addSubview(placeholderLabel)
        placeholderLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        contentView.addSubview(imageView)
        contentView.addSubview(cameraBtn)
        contentView.addSubview(pdfBtn)
        contentView.addSubview(galleryBtn)
        contentView.addSubview(activityIndicator)
        contentView.addSubview(statusLabel)
        contentView.addSubview(livePreviewContainer)
        livePreviewContainer.addSubview(liveTitleLeft)
        livePreviewContainer.addSubview(liveTitleRight)
        livePreviewContainer.addSubview(liveSeparator)
        livePreviewContainer.addSubview(liveStreamTextView)
        livePreviewContainer.addSubview(liveCropPreviewView)
        contentView.addSubview(tableScrollView)
        tableScrollView.addSubview(resultColumn)
        resultColumn.addArrangedSubview(resultTextView)
        contentView.addSubview(toolBar)
        toolBar.addArrangedSubview(previewBtn)
        toolBar.addArrangedSubview(copyBtn)

        imageView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(20)
            make.left.equalToSuperview().offset(20)
            make.right.equalToSuperview().offset(-20)
            make.height.equalTo(300)
        }

        cameraBtn.snp.makeConstraints { make in
            make.top.equalTo(imageView.snp.bottom).offset(16)
            make.right.equalToSuperview().offset(-40)
            make.width.height.equalTo(50)
        }

        galleryBtn.snp.makeConstraints { make in
            make.top.equalTo(imageView.snp.bottom).offset(16)
            make.right.equalTo(cameraBtn.snp.left).offset(-16)
            make.width.height.equalTo(50)
        }

        pdfBtn.snp.makeConstraints { make in
            make.top.equalTo(imageView.snp.bottom).offset(16)
            make.right.equalTo(galleryBtn.snp.left).offset(-16)
            make.width.height.equalTo(50)
        }

        activityIndicator.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(cameraBtn.snp.bottom).offset(20)
        }

        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(activityIndicator.snp.bottom).offset(8)
            make.left.equalToSuperview().offset(20)
            make.right.equalToSuperview().offset(-20)
        }

        livePreviewContainer.snp.makeConstraints { make in
            make.top.equalTo(statusLabel.snp.bottom).offset(12)
            make.left.equalToSuperview().offset(20)
            make.right.equalToSuperview().offset(-20)
            livePreviewHeightConstraint = make.height.equalTo(0).constraint
        }

        liveTitleLeft.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(10)
            make.left.equalToSuperview().offset(16)
            make.right.lessThanOrEqualTo(liveSeparator.snp.left).offset(-8)
        }

        liveTitleRight.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(10)
            make.right.equalToSuperview().offset(-16)
        }

        liveSeparator.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(8)
            make.bottom.equalToSuperview().offset(-8)
            make.width.equalTo(1)
        }

        liveStreamTextView.snp.makeConstraints { make in
            make.top.equalTo(liveTitleLeft.snp.bottom).offset(8)
            make.left.equalToSuperview().offset(12)
            make.bottom.equalToSuperview().offset(-12)
            make.right.equalTo(liveSeparator.snp.left).offset(-10)
        }

        liveCropPreviewView.snp.makeConstraints { make in
            make.top.equalTo(liveTitleRight.snp.bottom).offset(8)
            make.right.equalToSuperview().offset(-12)
            make.bottom.equalToSuperview().offset(-12)
            make.left.equalTo(liveSeparator.snp.right).offset(10)
        }

        resultColumn.snp.makeConstraints { make in
            make.top.left.bottom.equalTo(tableScrollView.frameLayoutGuide)
            make.width.equalTo(tableScrollView.frameLayoutGuide)
        }

        tableScrollView.snp.makeConstraints { make in
            make.top.equalTo(livePreviewContainer.snp.bottom).offset(16)
            make.left.equalToSuperview().offset(20)
            make.right.equalToSuperview().offset(-20)
            resultTextViewHeightConstraint = make.height.equalTo(0).constraint
        }

        toolBar.snp.makeConstraints { make in
            make.top.equalTo(tableScrollView.snp.bottom).offset(12)
            make.left.equalToSuperview().offset(20)
            make.right.equalToSuperview().offset(-20)
            make.height.equalTo(40)
            make.bottom.equalToSuperview().offset(-40)
        }

        cameraBtn.addTarget(self, action: #selector(openCamera), for: .touchUpInside)
        galleryBtn.addTarget(self, action: #selector(openGallery), for: .touchUpInside)
        pdfBtn.addTarget(self, action: #selector(openPDF), for: .touchUpInside)
        previewBtn.addTarget(self, action: #selector(togglePreview), for: .touchUpInside)
        copyBtn.addTarget(self, action: #selector(copyResult), for: .touchUpInside)

        resultTextView.isHidden = true
        tableScrollView.isHidden = true
        toolBar.isHidden = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = tableScrollView.bounds.width
        guard !rawMarkdown.isEmpty, !tableScrollView.isHidden, w > 1 else { return }
        if abs(w - lastMeasuredContainerWidth) > 1 {
            updateResultTextViewHeight()
        }
    }

    // MARK: - Bindings

    private func setupBindings() {
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.onStateChanged(state)
            }
            .store(in: &cancellables)

        engine.$liveCropImage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] img in
                self?.liveCropPreviewView.image = img
            }
            .store(in: &cancellables)

        engine.$liveCropStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                self.liveStreamTextView.text = text
                // Instant scroll to bottom — no animation, no delay
                let bottomOffset = CGPoint(x: 0, y: max(0, self.liveStreamTextView.contentSize.height - self.liveStreamTextView.bounds.height))
                self.liveStreamTextView.setContentOffset(bottomOffset, animated: false)
            }
            .store(in: &cancellables)

        engine.$liveDecodeSpeed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                if case .processing = self.engine.state {
                    self.applyLiveSpeed(text)
                } else {
                    self.applyLiveSpeed("")
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .ocrLiveTpsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if !MiniCPMV47Const.ocrLiveTpsEnabled() {
                    self.applyLiveSpeed("")
                }
            }
            .store(in: &cancellables)
    }

    private func applyLiveSpeed(_ text: String) {
        let show = !text.isEmpty && MiniCPMV47Const.ocrLiveTpsEnabled()
        guard show else {
            liveTitleLeft.attributedText = nil
            liveTitleLeft.text = L.Ocr.liveOutput.loc
            return
        }
        let titleFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
        let title = NSMutableAttributedString(
            string: L.Ocr.liveOutput.loc + ": ",
            attributes: [
                .font: titleFont,
                .foregroundColor: UIColor.secondaryLabel
            ])
        title.append(NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13.5, weight: .semibold),
                .foregroundColor: UIColor.mb_color(with: "#007AFF")
            ]))
        liveTitleLeft.attributedText = title
    }

    private func onStateChanged(_ state: OcrState) {
        switch state {
        case .uninitialized:
            activityIndicator.startAnimating()
            statusLabel.text = L.Ocr.statusInitializing.loc
            resultTextView.isHidden = true
            tableScrollView.isHidden = true
            toolBar.isHidden = true
            livePreviewHeightConstraint?.update(offset: 0)
            livePreviewContainer.isHidden = true
            liveStreamTextView.text = ""
            liveCropPreviewView.image = nil
            applyLiveSpeed("")
            cameraBtn.isEnabled = false
            galleryBtn.isEnabled = false
            pdfBtn.isEnabled = false

        case .loadingLayoutModel, .loadingOcrModel:
            activityIndicator.startAnimating()
            statusLabel.text = L.Ocr.statusLoadingModels.loc
            resultTextView.isHidden = true
            tableScrollView.isHidden = true
            toolBar.isHidden = true
            livePreviewHeightConstraint?.update(offset: 0)
            livePreviewContainer.isHidden = true
            applyLiveSpeed("")
            cameraBtn.isEnabled = false
            galleryBtn.isEnabled = false
            pdfBtn.isEnabled = false

        case .ready:
            activityIndicator.stopAnimating()
            statusLabel.text = nil
            livePreviewHeightConstraint?.update(offset: 0)
            livePreviewContainer.isHidden = true
            liveStreamTextView.text = ""
            liveCropPreviewView.image = nil
            applyLiveSpeed("")
            cameraBtn.isEnabled = true
            galleryBtn.isEnabled = true
            pdfBtn.isEnabled = true
            toolBar.isHidden = rawMarkdown.isEmpty

        case .processing(let detail):
            activityIndicator.startAnimating()
            statusLabel.text = detail
            livePreviewHeightConstraint?.update(offset: MBUtils.isDeviceIPad() ? 550 : 367)
            livePreviewContainer.isHidden = false
            cameraBtn.isEnabled = false
            galleryBtn.isEnabled = false
            pdfBtn.isEnabled = false

        case .error(let message):
            activityIndicator.stopAnimating()
            statusLabel.text = message
            livePreviewHeightConstraint?.update(offset: 0)
            livePreviewContainer.isHidden = true
            liveStreamTextView.text = ""
            liveCropPreviewView.image = nil
            applyLiveSpeed("")
            cameraBtn.isEnabled = true
            galleryBtn.isEnabled = true
            pdfBtn.isEnabled = true
        }
    }

    /// Trigger model loading if not already loaded/loading.
    /// Must be called on @MainActor since OcrEngine is @MainActor.
    private func loadModelsIfNeeded() {
        guard engine.modelsExist() else {
            statusLabel.text = L.Ocr.statusModelsMissing.loc
            activityIndicator.stopAnimating()
            return
        }
        // Already loading or ready: wait for Combine state update.
        if case .loadingLayoutModel = engine.state { return }
        if case .loadingOcrModel = engine.state { return }
        if case .ready = engine.state { return }
        // Kick off loading; Combine will drive UI via onStateChanged.
        Task { await engine.loadModels() }
    }

    /// Re-check and reload after model download (called from parent).
    func checkModelAndLoad() {
        guard engine.modelsExist() else {
            statusLabel.text = L.Ocr.statusModelsMissing.loc
            return
        }
        if case .ready = engine.state { return }
        if case .loadingLayoutModel = engine.state { return }
        if case .loadingOcrModel = engine.state { return }
        Task { await engine.loadModels() }
    }

    /// Reset all content (called from parent on delete).
    func resetAllContent() {
        multiPageTask?.cancel()
        multiPageTask = nil
        selectedImage = nil
        imageView.image = nil
        placeholderLabel.isHidden = false
        resultTextView.text = ""
        resultTextView.attributedText = nil
        renderedResult = nil
        resultTextView.isHidden = true
        tableScrollView.isHidden = true
        rawMarkdown = ""
        pdfPreviewSlots = nil
        isPreviewMode = true
        updatePreviewButtonAppearance()
        toolBar.isHidden = true
        statusLabel.text = nil
        activityIndicator.stopAnimating()
        // Clear live preview state
        engine.liveCropStream = ""
        engine.liveCropImage = nil
        liveStreamTextView.text = ""
        liveCropPreviewView.image = nil
        resultTextViewHeightConstraint?.update(offset: MBUtils.isDeviceIPad() ? 200 : 120)
    }

    // MARK: - Image Picker

    @objc private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func openGallery() {
        var config = PickerConfiguration.default
        config.selectMode = .single
        config.selectOptions = [.photo]
        config.maximumSelectedCount = 1
        config.maximumSelectedPhotoCount = 1
        config.isSelectedOriginal = true

        Photo.picker(config) { [weak self] result, _ in
            guard let self = self else { return }
            Task {
                let images: [UIImage] = try await result.objects()
                guard let image = images.first else { return }
                DispatchQueue.main.async {
                    self.handleSelectedImage(image)
                }
            }
        }
    }

    @objc private func openPDF() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    private func openLocalPDF(_ url: URL) {
        guard let pdfDoc = PDFDocument(url: url) else {
            statusLabel.text = L.Ocr.statusPdfOpenFailed.loc
            return
        }

        let pageCount = pdfDoc.pageCount
        guard pageCount > 0 else {
            statusLabel.text = L.Ocr.statusPdfNoPages.loc
            return
        }

        activityIndicator.startAnimating()
        statusLabel.text = String(format: L.Ocr.statusPdfRendering.loc, pageCount)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pages = Self.renderPDFPages(pdfDoc)
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !pages.isEmpty else {
                    self.statusLabel.text = L.Ocr.statusPdfRenderFailed.loc
                    self.activityIndicator.stopAnimating()
                    return
                }
                // Show first page in imageView
                self.selectedImage = pages[0]
                self.imageView.image = pages[0]
                self.placeholderLabel.isHidden = true
                self.resultTextView.isHidden = true
                self.tableScrollView.isHidden = true
                self.toolBar.isHidden = true
                self.resultTextView.text = ""
                self.rawMarkdown = ""
                self.pdfPreviewSlots = nil
                self.isPreviewMode = true
                self.updatePreviewButtonAppearance()

                guard self.engine.state == .ready else {
                    self.statusLabel.text = L.Ocr.statusNotReady.loc
                    self.activityIndicator.stopAnimating()
                    return
                }
                self.runOCROnPages(pages)
            }
        }
    }

    /// Render each PDF page at 2× the media box.
    /// format.scale = 1 so the pixel size is mediaBox × 2. The default
    /// renderer scale follows the screen and would double that again.
    private static func renderPDFPages(_ pdfDoc: PDFDocument) -> [UIImage] {
        let pageCount = pdfDoc.pageCount
        var pages: [UIImage] = []
        for i in 0..<pageCount {
            guard let page = pdfDoc.page(at: i) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            let pdfScale: CGFloat = 2.0
            let size = CGSize(width: mediaBox.width * pdfScale, height: mediaBox.height * pdfScale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1.0  // pixels are exactly mediaBox * pdfScale
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.cgContext.translateBy(x: 0, y: size.height)
                ctx.cgContext.scaleBy(x: pdfScale, y: -pdfScale)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            pages.append(image)
        }
        return pages
    }

    /// OCR a multi-page PDF: render each page, recognize, merge with page-break.
    private func runOCROnPages(_ pages: [UIImage]) {
        ocrTask?.cancel()
        let total = pages.count
        var allMarkdown: [String] = []
        var previewSlots: [(index: Int, label: String)] = []
        // Per-page crops are named ocr_crop_{block}_{label}.png and the next page
        // overwrites them. Keep preview copies above that range.
        var nextPreviewId = 10_000

        let task = Task { [weak self] in
            guard let self = self else { return }
            for (idx, page) in pages.enumerated() {
                if Task.isCancelled { break }

                await MainActor.run {
                    self.statusLabel.text = String(format: L.Ocr.statusDetectingLayout.loc, idx + 1, total)
                }

                do {
                    let md = try await self.engine.recognize(fullImage: page)
                    allMarkdown.append(md)
                    let kept = self.keepPagePreviewCrops(self.engine.imagePreviewSlots, nextId: &nextPreviewId)
                    previewSlots.append(contentsOf: kept)
                } catch {
                    if (error as? OcrError) == .cancelled { break }
                    print("[OCR] Page \(idx + 1) failed: \(error)")
                    allMarkdown.append("[Page \(idx + 1) failed: \(error.localizedDescription)]")
                }
            }

            guard !Task.isCancelled, !allMarkdown.isEmpty else { return }
            let merged = allMarkdown.joined(separator: "\n\n<!-- page-break -->\n\n")
            await MainActor.run {
                self.pdfPreviewSlots = previewSlots
                self.rawMarkdown = merged
                self.resultTextView.isHidden = false
                self.tableScrollView.isHidden = false
                self.toolBar.isHidden = false
                self.view.layoutIfNeeded()
                self.applyResultMode()
                self.statusLabel.text = String(format: L.Ocr.statusCompletePages.loc, allMarkdown.count, total)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.statusLabel.text?.hasPrefix("OCR complete") == true {
                        self?.statusLabel.text = nil
                    }
                }
            }
        }
        multiPageTask = task
    }

    // MARK: - UIImagePickerControllerDelegate (camera)

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else { return }
        handleSelectedImage(image)
    }

    // MARK: - UIDocumentPickerDelegate (PDF)

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        openLocalPDF(url)
    }

    // MARK: - PHPickerViewControllerDelegate (gallery)

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = results.first else { return }
        result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] image, _ in
            guard let self = self, let image = image as? UIImage else { return }
            DispatchQueue.main.async {
                self.handleSelectedImage(image)
            }
        }
    }

    // MARK: - Shared image handling

    private func handleSelectedImage(_ image: UIImage) {
        // Cancel any in-flight OCR task and flush pending async blocks
        ocrTask?.cancel()
        multiPageTask?.cancel()

        selectedImage = image
        imageView.image = image
        placeholderLabel.isHidden = true
        resultTextView.isHidden = true
        tableScrollView.isHidden = true
        toolBar.isHidden = true
        resultTextView.text = ""
        rawMarkdown = ""
        pdfPreviewSlots = nil
        isPreviewMode = true
        updatePreviewButtonAppearance()

        // Auto-detect OCR if models loaded
        if engine.state == .ready {
            runOCR(image: image)
        } else if engine.modelsExist() {
            Task {
                await engine.loadModels()
                if engine.state == .ready {
                    runOCR(image: image)
                }
            }
        } else {
            statusLabel.text = L.Ocr.statusModelsMissing.loc
        }
    }

    // MARK: - OCR Pipeline

    private func runOCR(image: UIImage) {
        ocrTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let markdown = try await self.engine.recognize(fullImage: image)
                DispatchQueue.main.async {
                    self.rawMarkdown = markdown
                    self.resultTextView.isHidden = false
                    self.tableScrollView.isHidden = false
                    self.toolBar.isHidden = false
                    self.view.layoutIfNeeded()
                    self.applyResultMode()
                    self.statusLabel.text = L.Ocr.statusComplete.loc
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if self.statusLabel.text == L.Ocr.statusComplete.loc { self.statusLabel.text = nil }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if case OcrError.cancelled = error {
                        self.statusLabel.text = nil
                        self.activityIndicator.stopAnimating()
                        return
                    }
                    self.statusLabel.text = String(format: L.Ocr.statusFailed.loc, error.localizedDescription)
                    self.rawMarkdown = "Error: \(error.localizedDescription)"
                    self.applyResultMode()
                    self.resultTextView.isHidden = false
                    self.tableScrollView.isHidden = false
                    self.toolBar.isHidden = false
                }
            }
        }
    }

    // MARK: - Result display

    /// Body is base 14 plus this offset. iPhone is one point smaller than iPad.
    private var resultFontSizeOffset: CGFloat { MBUtils.isDeviceIPad() ? 2 : 1 }

    private func applyResultMode() {
        if isPreviewMode {
            let baseAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor.label
            ]
            let containerWidth = tableScrollView.bounds.width > 0
                ? tableScrollView.bounds.width
                : (view.bounds.width - 40)
            let rendered = OcrMarkdownRenderer.render(
                markdownForPreview(rawMarkdown),
                baseAttributes: baseAttrs,
                fontSizeOffset: resultFontSizeOffset,
                maxFormulaWidth: max(1, containerWidth - 24))
            let withImages = replaceImageMarkers(in: rendered)
            renderedResult = trimmingTrailingNewlines(withImages)
        } else {
            renderedResult = nil
            resultTextView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            resultTextView.text = rawMarkdown.trimmingCharacters(in: .newlines)
        }
        updateResultTextViewHeight()
    }

    /// Copy this page's preview crops before the next page reuses the same names.
    private func keepPagePreviewCrops(_ slots: [(index: Int, label: String)], nextId: inout Int) -> [(index: Int, label: String)] {
        let docs = OcrEngine.cropPreviewDirectory
        var kept: [(index: Int, label: String)] = []
        for slot in slots {
            let src = docs.appendingPathComponent("ocr_crop_\(slot.index)_\(slot.label).png")
            let dst = docs.appendingPathComponent("ocr_crop_\(nextId)_\(slot.label).png")
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
            kept.append((index: nextId, label: slot.label))
            nextId += 1
        }
        return kept
    }

    /// The stored markdown keeps `![image]()`. Preview swaps each one, in order,
    /// for the crop saved as ocr_crop_{index}_{label}.png. Header and footer
    /// images stay out of the string, matching the pipeline ignore list.
    private func markdownForPreview(_ markdown: String) -> String {
        let slots = pdfPreviewSlots ?? engine.imagePreviewSlots
        let token = "![image]()"
        guard !slots.isEmpty, markdown.contains(token) else { return markdown }
        var out = ""
        var rest = markdown[...]
        var i = 0
        while let range = rest.range(of: token) {
            out += rest[..<range.lowerBound]
            if i < slots.count {
                let slot = slots[i]
                out += "![ocr_img_\(slot.index)_\(slot.label)]()"
                i += 1
            } else {
                out += token
            }
            rest = rest[range.upperBound...]
        }
        out += rest
        return out
    }

    /// Replace ![ocr_img_{order}_{label}]() markers with actual crop images loaded
    /// from the app's Documents directory.
    private func replaceImageMarkers(in attributedString: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedString)
        let pattern = "\\[ocr_img_(\\d+)_(\\w+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return attributedString
        }

        let fullRange = NSRange(location: 0, length: mutable.length)
        let matches = regex.matches(in: mutable.string, range: fullRange)

        // Process in reverse order to preserve range validity through replacements
        for match in matches.reversed() {
            guard match.numberOfRanges == 3,
                  let orderRange = Range(match.range(at: 1), in: mutable.string),
                  let labelRange = Range(match.range(at: 2), in: mutable.string) else {
                continue
            }
            let order = String(mutable.string[orderRange])
            let label = String(mutable.string[labelRange])
            let filename = "ocr_crop_\(order)_\(label).png"
            let fileURL = OcrEngine.cropPreviewDirectory.appendingPathComponent(filename)

            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let image = UIImage(contentsOfFile: fileURL.path) else {
                print("[OcrVC] image marker \(filename) not found, keeping placeholder")
                continue
            }

            // Calculate display size: fill container width, maintain aspect ratio
            let containerWidth = tableScrollView.bounds.width > 0
                ? tableScrollView.bounds.width - 32  // inset for text container
                : (view.bounds.width - 72)
            let maxWidth: CGFloat = max(containerWidth, 100)
            let displaySize = image.size.width > maxWidth
                ? CGSize(width: maxWidth, height: maxWidth * image.size.height / image.size.width)
                : image.size

            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: displaySize)

            let replacement = NSMutableAttributedString()
            if match.range.location > 0 {
                let prev = (mutable.string as NSString).substring(with: NSRange(location: match.range.location - 1, length: 1))
                if prev != "\n" {
                    replacement.append(NSAttributedString(string: "\n"))
                }
            }
            replacement.append(NSAttributedString(attachment: attachment))
            mutable.replaceCharacters(in: match.range, with: replacement)
        }

        return mutable
    }

    /// Drop trailing `\n` / `\r` so the last paragraph does not leave empty
    /// line-fragments that `sizeThatFits` then counts as extra height.
    private func trimmingTrailingNewlines(_ attributed: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        while mutable.length > 0 {
            let last = (mutable.string as NSString).substring(from: mutable.length - 1)
            if last == "\n" || last == "\r" {
                mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
            } else {
                break
            }
        }
        if mutable.length > 0 {
            let ns = mutable.string as NSString
            let lastPara = ns.paragraphRange(for: NSRange(location: mutable.length - 1, length: 1))
            if let style = mutable.attribute(.paragraphStyle, at: lastPara.location, effectiveRange: nil) as? NSParagraphStyle {
                let trimmed = style.mutableCopy() as! NSMutableParagraphStyle
                trimmed.paragraphSpacing = 0
                mutable.addAttribute(.paragraphStyle, value: trimmed, range: lastPara)
            }
        }
        return mutable
    }

    private func updateResultTextViewHeight() {
        let containerWidth = tableScrollView.bounds.width > 0
            ? tableScrollView.bounds.width
            : (view.bounds.width - 40)
        guard containerWidth > 1 else { return }
        lastMeasuredContainerWidth = containerWidth
        tableScrollView.isScrollEnabled = false

        for view in resultColumn.arrangedSubviews {
            resultColumn.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let targetH: CGFloat
        if let rendered = renderedResult, rendered.length > 0 {
            resultColumn.layoutMargins = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
            resultColumn.isLayoutMarginsRelativeArrangement = true
            var total = resultColumn.layoutMargins.top + resultColumn.layoutMargins.bottom
            for segment in previewSegments(rendered) {
                total += addPreviewSegment(segment.text, isTable: segment.isTable, containerWidth: containerWidth)
            }
            targetH = max(1, total)
        } else {
            resultColumn.layoutMargins = .zero
            resultColumn.isLayoutMarginsRelativeArrangement = false
            let fittedH = layoutSourceResult(containerWidth: containerWidth)
            targetH = rawMarkdown.isEmpty
                ? max(MBUtils.isDeviceIPad() ? 200 : 120, fittedH)
                : max(1, fittedH)
        }

        resultTextViewHeightConstraint?.update(offset: targetH)
        tableScrollView.layoutIfNeeded()
        tableScrollView.contentSize = CGSize(width: containerWidth, height: targetH)
        scrollView.layoutIfNeeded()
    }

    private func layoutSourceResult(containerWidth: CGFloat) -> CGFloat {
        resultColumn.addArrangedSubview(resultTextView)
        let inset = resultTextView.textContainerInset
        let pad = resultTextView.textContainer.lineFragmentPadding
        let textWidth = max(1, containerWidth - inset.left - inset.right - pad * 2)
        resultTextView.textContainer.widthTracksTextView = false
        resultTextView.textContainer.heightTracksTextView = false
        resultTextView.textContainer.size = CGSize(width: textWidth, height: 10_000_000)
        resultTextView.layoutManager.ensureLayout(for: resultTextView.textContainer)
        let glyphs = resultTextView.layoutManager.glyphRange(for: resultTextView.textContainer)
        let used = glyphs.length == 0
            ? CGRect.zero
            : resultTextView.layoutManager.boundingRect(forGlyphRange: glyphs, in: resultTextView.textContainer)
        let fittedH = ceil(used.height + inset.top + inset.bottom + 1)
        resultTextView.snp.remakeConstraints { make in
            make.height.equalTo(fittedH)
        }
        return fittedH
    }

    private func previewSegments(_ text: NSAttributedString) -> [(isTable: Bool, text: NSAttributedString)] {
        let ns = text.string as NSString
        var segments: [(isTable: Bool, text: NSMutableAttributedString)] = []
        var location = 0
        var inTable = false
        while location < text.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let isTable = isTableParagraph(text, at: paragraph.location)
                || (inTable && isTableSeparator(text, at: paragraph.location))
            let piece = text.attributedSubstring(from: paragraph)
            if segments.isEmpty || isTable != inTable {
                segments.append((isTable, NSMutableAttributedString(attributedString: piece)))
                inTable = isTable
            } else {
                segments[segments.count - 1].text.append(piece)
            }
            let next = NSMaxRange(paragraph)
            if next <= location { break }
            location = next
        }
        return segments.map { (isTable: $0.isTable, text: $0.text) }
    }

    private func isTableParagraph(_ text: NSAttributedString, at location: Int) -> Bool {
        guard location < text.length,
              let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        else { return false }
        if style.lineBreakMode == .byTruncatingTail,
           style.tabStops.contains(where: { $0.alignment == .right }) {
            return true
        }
        let font = text.attribute(.font, at: location, effectiveRange: nil) as? UIFont
        let name = font?.fontName ?? ""
        let mono = name.contains("Menlo") || name.contains("Mono")
        return style.lineBreakMode == .byClipping && mono
    }

    private func isTableSeparator(_ text: NSAttributedString, at location: Int) -> Bool {
        guard location < text.length,
              let font = text.attribute(.font, at: location, effectiveRange: nil) as? UIFont
        else { return false }
        return font.pointSize <= 2 && text.attribute(.backgroundColor, at: location, effectiveRange: nil) != nil
    }

    private func measureSegment(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        let inner = max(1, width - 24)
        let laid = laidOutSize(text, innerWidth: inner)
        return CGSize(width: width, height: laid.height)
    }

    private func tableSegmentSize(_ text: NSAttributedString) -> CGSize {
        let inset: CGFloat = 24
        var tabWidth: CGFloat = 0
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            for tab in style.tabStops where tab.alignment == .right {
                tabWidth = max(tabWidth, tab.location)
            }
        }
        if tabWidth > 0 {
            let laid = laidOutSize(text, innerWidth: tabWidth)
            return CGSize(width: ceil(tabWidth) + inset, height: laid.height)
        }
        let laid = laidOutSize(text, innerWidth: 100_000)
        return CGSize(width: laid.width + inset, height: laid.height)
    }

    private func laidOutSize(_ text: NSAttributedString, innerWidth: CGFloat) -> CGSize {
        let storage = NSTextStorage(attributedString: text)
        let layout = TableLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: max(1, innerWidth), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        var contentWidth: CGFloat = 0
        var contentHeight: CGFloat = 0
        let glyphs = layout.glyphRange(for: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, usedRect, _, _, _ in
            contentWidth = max(contentWidth, usedRect.maxX)
            contentHeight = max(contentHeight, rect.maxY)
        }
        return CGSize(width: max(1, ceil(contentWidth)), height: max(1, ceil(contentHeight)))
    }

    private func addPreviewSegment(_ text: NSAttributedString, isTable: Bool, containerWidth: CGFloat) -> CGFloat {
        let fitted = isTable ? tableSegmentSize(text) : nil
        let scrolls = (fitted?.width ?? 0) > containerWidth + 1
        let width = fitted.map { scrolls ? $0.width : containerWidth } ?? containerWidth
        let height = fitted?.height ?? measureSegment(text, width: containerWidth).height
        let textView = makePieceTextView(text, width: width)
        if scrolls {
            let scroll = UIScrollView()
            scroll.backgroundColor = .clear
            scroll.showsHorizontalScrollIndicator = true
            scroll.showsVerticalScrollIndicator = false
            scroll.alwaysBounceVertical = false
            scroll.alwaysBounceHorizontal = false
            scroll.bounces = true
            scroll.addSubview(textView)
            textView.frame = CGRect(x: 0, y: 0, width: width, height: height)
            scroll.contentSize = CGSize(width: width, height: height)
            scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            scroll.snp.makeConstraints { make in
                make.height.equalTo(height)
                make.width.equalTo(containerWidth)
            }
            resultColumn.addArrangedSubview(scroll)
        } else {
            textView.snp.makeConstraints { make in
                make.height.equalTo(height)
                make.width.equalTo(containerWidth)
            }
            resultColumn.addArrangedSubview(textView)
        }
        return height
    }

    private func makePieceTextView(_ text: NSAttributedString, width: CGFloat) -> TableFriendlyTextView {
        let textView = TableFriendlyTextView(frame: .zero, textContainer: nil)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.heightTracksTextView = false
        textView.textContainer.size = CGSize(width: max(1, width - 24), height: 10_000_000)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.attributedText = text
        return textView
    }

    private func updatePreviewButtonAppearance() {
        if isPreviewMode {
            previewBtn.setTitle("Preview", for: .normal)
            previewBtn.backgroundColor = UIColor.mb_color(with: "#007AFF")
        } else {
            previewBtn.setTitle("Source", for: .normal)
            previewBtn.backgroundColor = UIColor.mb_color(with: "#FF9500")
        }
    }

    @objc private func togglePreview() {
        isPreviewMode.toggle()
        updatePreviewButtonAppearance()
        applyResultMode()
    }

    @objc private func copyResult() {
        guard !rawMarkdown.isEmpty else { return }
        UIPasteboard.general.string = rawMarkdown
        let hud = MBHUD.showAdded(to: view, animated: true)
        hud.mode = .text
        hud.label.text = "Copied"
        hud.hide(animated: true, afterDelay: 1.5)
    }
}

// MARK: - Custom NSLayoutManager (full-line-height table background)

/// Expands `.backgroundColor` fill height to the full line-fragment `usedRect`
/// so alternating-row colours cover the entire `minimumLineHeight` (1.5× font)
/// instead of being clipped to the per-glyph bounding box.
private class TableLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>,
                                           count rectCount: Int,
                                           forCharacterRange charRange: NSRange,
                                           color: UIColor) {
        var rects = Array(UnsafeBufferPointer(start: rectArray, count: rectCount))
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: charRange,
                                                          actualCharacterRange: nil)) { _, usedRect, _, _, _ in
            let targetH = usedRect.size.height
            for i in 0..<rectCount
                where rects[i].midY >= usedRect.minY && rects[i].midY <= usedRect.maxY {
                let halfExpand = (targetH - rects[i].size.height) / 2.0
                rects[i].origin.y -= halfExpand
                rects[i].size.height = targetH
            }
        }
        super.fillBackgroundRectArray(rects, count: rectCount,
                                       forCharacterRange: charRange, color: color)
    }
}

/// UITextView that uses `TableLayoutManager` as its *only* layout manager.
/// The previous init (`super.init` then `addLayoutManager`) left UIKit's
/// default manager attached; `sizeThatFits` then reported roughly 2× height
/// and the result box grew a large empty tail under the last line.
private class TableFriendlyTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        let layout = TableLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
