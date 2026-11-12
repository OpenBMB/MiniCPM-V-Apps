// MiniCPM-OCR 1.0 entry page. Mirrors the Android OcrActivity flow:
// pick an image, run layout detection + per-crop recognition, show markdown.

import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import pasteboard from '@ohos.pasteboard';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@ohos.base';

import { LlamaEngine } from '../engine/LlamaEngine';
import { OcrEngine } from '../ocr/OcrEngine';
import { downscale } from '../ocr/OcrLayout';
import { PickedImage, pickAndDecodeImage } from '../utils/ImageCodec';

const DOMAIN: number = 0xC0DE;
const TAG: string = 'OcrPage';

@Entry
@Component
struct OcrPage {
  @State imageUri: string = '';
  @State imageW: number = 0;
  @State imageH: number = 0;
  @State running: boolean = false;
  @State loadingModel: boolean = false;
  @State statusText: string = '';
  @State statusBlock: string = '';
  @State result: string = '';
  @State errorText: string = '';

  private page: image.PixelMap | null = null;
  private engine: LlamaEngine | null = null;
  private ocr: OcrEngine | null = null;
  private ctx: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    this.engine = LlamaEngine.getInstance(this.ctx);
  }

  aboutToDisappear(): void {
    if (this.ocr !== null) {
      this.ocr.cancel();
      this.ocr.close();
      this.ocr = null;
    }
    this.releasePage();
  }

  private releasePage(): void {
    if (this.page !== null) {
      this.page.release().catch(() => { /* ignore */ });
      this.page = null;
    }
  }

  /** Loads the gguf pair unless it is already in memory. */
  private async ensureModelLoaded(): Promise<boolean> {
    if (this.engine === null || this.ctx === null) {
      return false;
    }
    if (this.engine.getState().name === 'ModelReady') {
      return true;
    }
    const gguf: string = LlamaEngine.modelPath(this.ctx);
    const mmproj: string = LlamaEngine.mmprojPath(this.ctx);
    this.loadingModel = true;
    this.statusText = '加载模型中...';
    try {
      await this.engine.loadModel(gguf, mmproj.length > 0 ? mmproj : null);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadModel failed: %{public}s', `${err.message ?? e}`);
      this.errorText = `模型加载失败: ${err.message ?? e}`;
      return false;
    } finally {
      this.loadingModel = false;
    }
  }

  private async onPickImage(): Promise<void> {
    if (this.running) {
      return;
    }
    this.errorText = '';
    this.result = '';
    this.statusBlock = '';
    this.statusText = '';

    let picked: PickedImage | null = null;
    try {
      picked = await pickAndDecodeImage();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'pick failed: %{public}s', `${e}`);
    }
    if (picked === null) {
      return;
    }
    this.releasePage();
    this.page = picked.pixelMap;
    this.imageUri = picked.fileName;
    this.imageW = picked.width;
    this.imageH = picked.height;
    this.statusText = `${picked.width} x ${picked.height}`;
  }

  private async onRun(): Promise<void> {
    if (this.running || this.loadingModel || this.page === null || this.ctx === null) {
      return;
    }
    const ready: boolean = await this.ensureModelLoaded();
    if (!ready) {
      return;
    }
    const layoutPath: string = LlamaEngine.layoutPath(this.ctx);
    if (layoutPath.length === 0) {
      this.errorText = '当前模型不是 OCR 模型';
      return;
    }

    this.running = true;
    this.errorText = '';
    this.result = '';
    this.statusText = '识别中...';
    try {
      if (this.ocr === null) {
        this.ocr = new OcrEngine(this.engine!, layoutPath);
      }
      let acc: string = '';
      const md: string = await this.ocr.recognizePage(
        this.page,
        (label: string) => {
          this.statusBlock = label;
        },
        (token: string) => {
          acc += token;
          this.result = acc;
        },
      );
      this.result = md;
      this.statusBlock = '';
      this.statusText = '识别完成';
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'ocr failed: %{public}s', `${err.message ?? e}`);
      this.errorText = `识别失败: ${err.message ?? e}`;
    } finally {
      this.running = false;
    }
  }

  /** Runs the pipeline on a bundled sample, so the demo works on a fresh device. */
  private async onSample(): Promise<void> {
    if (this.running || this.loadingModel || this.ctx === null) {
      return;
    }
    this.errorText = '';
    this.result = '';
    this.statusBlock = '';
    this.statusText = '';
    try {
      const bytes: Uint8Array = await this.ctx.resourceManager.getRawFileContent('test_ticket.jpg');
      const src = image.createImageSource(bytes.buffer as ArrayBuffer);
      let pm: image.PixelMap;
      try {
        pm = await src.createPixelMap();
      } finally {
        await src.release();
      }
      const scaled: image.PixelMap = await downscale(pm, 1600);
      if (scaled !== pm) {
        await pm.release();
      }
      this.releasePage();
      this.page = scaled;
      const info: image.ImageInfo = await scaled.getImageInfo();
      this.imageUri = '示例：test_ticket.jpg';
      this.imageW = info.size.width;
      this.imageH = info.size.height;
      await this.onRun();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'sample failed: %{public}s', `${err.message ?? e}`);
      this.errorText = `示例加载失败: ${err.message ?? e}`;
    }
  }

  private onCancel(): void {
    if (this.ocr !== null) {
      this.ocr.cancel();
    }
    this.running = false;
  }

  private async onCopy(): Promise<void> {
    if (this.result.length === 0) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.result);
    await pasteboard.getSystemPasteboard().setData(data);
    promptAction.showToast({ message: '已复制', duration: 1500 });
  }

  @Builder
  private appBar() {
    Row() {
      Button('返回')
        .fontSize(14)
        .height(32)
        .backgroundColor(Color.Transparent)
        .fontColor('#333333')
        .onClick(() => router.back())
      Text('MiniCPM-OCR 1.0')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
      Button('模型')
        .fontSize(14)
        .height(32)
        .backgroundColor(Color.Transparent)
        .fontColor('#333333')
        .onClick(() => {
          router.pushUrl({ url: 'pages/ModelManager' }).catch((e: object) => {
            hilog.error(DOMAIN, TAG, 'pushUrl failed: %{public}s', `${e}`);
          });
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 8, right: 8 })
  }

  build() {
    Column() {
      this.appBar()
      Divider().color('#E5E5E5')

      Scroll() {
        Column({ space: 12 }) {
          if (this.imageUri.length > 0) {
            Text(`${this.imageUri}  ${this.imageW}x${this.imageH}`)
              .fontSize(12)
              .fontColor('#888888')
              .width('100%')
          }

          Row({ space: 10 }) {
            Button(this.imageUri.length > 0 ? '重新选择' : '选择图片')
              .layoutWeight(1)
              .height(40)
              .enabled(!this.running)
              .onClick(() => { this.onPickImage(); })

            Button('示例文档')
              .layoutWeight(1)
              .height(40)
              .enabled(!this.running && !this.loadingModel)
              .backgroundColor('#455A64')
              .onClick(() => { this.onSample(); })

            Button(this.running ? '取消' : '开始识别')
              .layoutWeight(1)
              .height(40)
              .enabled(this.page !== null && !this.loadingModel)
              .backgroundColor(this.running ? '#C0392B' : '#2E7D32')
              .onClick(() => {
                if (this.running) {
                  this.onCancel();
                } else {
                  this.onRun();
                }
              })
          }
          .width('100%')

          if (this.loadingModel || this.statusText.length > 0 || this.statusBlock.length > 0) {
            Row({ space: 8 }) {
              if (this.loadingModel || this.running) {
                LoadingProgress().width(16).height(16)
              }
              Text(this.statusBlock.length > 0
                ? `${this.statusText}  ·  ${this.statusBlock}`
                : this.statusText)
                .fontSize(12)
                .fontColor('#666666')
                .layoutWeight(1)
            }
            .width('100%')
          }

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(12)
              .fontColor('#C0392B')
              .width('100%')
          }

          if (this.result.length > 0) {
            Row() {
              Text('识别结果')
                .fontSize(13)
                .fontColor('#666666')
                .layoutWeight(1)
              Button('复制')
                .fontSize(12)
                .height(28)
                .backgroundColor(Color.Transparent)
                .fontColor('#2E7D32')
                .onClick(() => { this.onCopy(); })
            }
            .width('100%')

            Text(this.result)
              .fontSize(14)
              .lineHeight(22)
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
              .textAlign(TextAlign.Start)
          }
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
  }
}
