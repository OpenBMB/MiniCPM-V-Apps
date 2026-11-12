// Model management page. Mirrors ModelManagerActivity.kt + activity_model_manager.xml
// from the Android demo.

import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import resourceManager from '@ohos.resourceManager';

import { LlamaEngine } from '../engine/LlamaEngine';
import { LlamaState, LlamaStateName } from '../engine/LlamaState';
import { TtsEngine, TtsState } from '../engine/TtsEngine';
import {
  ModelInfo,
  AVAILABLE_MODELS,
  DEFAULT_MODEL,
  findModelById,
} from '../engine/ModelInfo';
import { deleteSelectedModelFiles } from '../utils/DownloadManager';
import { LocaleManager, AppLanguage } from '../manager/LocaleManager';

const DOMAIN = 0xC0DE;
const TAG = 'ModelManager';

@Entry
@Component
struct ModelManager {
  @State stateName: LlamaStateName = 'Uninitialized';
  @State statusText: string = '';
  @State selectedId: string = DEFAULT_MODEL.id;
  @State modelExists: boolean = false;
  @State downloading: boolean = false;
  @State downloadProgress: number = 0;
  @State loading: boolean = false;
  @State isModelReady: boolean = false;
  @State currentLang: AppLanguage = AppLanguage.ZH;
  private loadingLock: boolean = false;

  private engine: LlamaEngine | null = null;
  private engineListener = (s: LlamaState) => this.onEngineState(s);
  private ttsEngine: TtsEngine | null = null;
  private ttsEngineListener = (s: TtsState) => this.onTtsEngineState(s);
  private resMgr: resourceManager.ResourceManager | null = null;

  private str(name: string): string {
    return this.resMgr!.getStringByNameSync(name);
  }

  aboutToAppear(): void {
    this.resMgr = getContext(this).resourceManager;
    this.engine = LlamaEngine.getInstance(getContext(this));
    this.ttsEngine = TtsEngine.getInstance(getContext(this));
    const m = LlamaEngine.getSelectedModel(getContext(this));
    this.selectedId = m.id;
    this.modelExists = LlamaEngine.modelsExist(getContext(this));
    this.engine.addListener(this.engineListener);
    this.ttsEngine.addListener(this.ttsEngineListener);
    this.currentLang = LocaleManager.currentLanguageSync();
  }

  aboutToDisappear(): void {
    if (this.engine) this.engine.removeListener(this.engineListener);
    if (this.ttsEngine) this.ttsEngine.removeListener(this.ttsEngineListener);
  }

  // ------------------------------------------------------------------
  // State machine wiring (mirrors ModelManagerActivity.observeEngineState)
  // ------------------------------------------------------------------

  private onEngineState(state: LlamaState): void {
    this.stateName = state.name;
    switch (state.name) {
      case 'Uninitialized':           this.statusText = this.str('status_uninitialized');
                                       this.isModelReady = false; break;
      case 'Initializing':            this.statusText = this.str('status_initializing'); break;
      case 'Initialized':             this.statusText = this.str('status_initialized'); break;
      case 'LoadingModel':            this.statusText = this.str('status_loading'); break;
      case 'ModelReady':              this.statusText = this.str('status_ready');
                                       this.isModelReady = true; break;
      case 'ProcessingSystemPrompt':
      case 'ProcessingUserPrompt':
      case 'Generating':              this.statusText = this.str('status_generating'); break;
      case 'PrefillingImage':         this.statusText = this.str('status_prefilling_image'); break;
      case 'UnloadingModel':          this.statusText = this.str('status_unloading'); break;
      case 'Error':                   this.statusText = `${this.str('status_error')}: ${state.errorMessage ?? ''}`; break;
      default:                        this.statusText = ''; break;
    }
    // modelExists is managed by onSelectModel / download / delete —
    // do NOT update it here because the engine state callback may fire
    // for a stale model while getSelectedModel() already points to
    // the newly selected one.
  }

  private onTtsEngineState(state: TtsState): void {
    switch (state.name) {
      case 'Uninitialized':  this.statusText = this.str('status_uninitialized');
                              this.isModelReady = false; break;
      case 'LoadingModel':   this.statusText = this.str('status_loading'); break;
      case 'Ready':          this.statusText = this.str('status_ready');
                              this.isModelReady = true; break;
      case 'Generating':     this.statusText = this.str('status_generating'); break;
      case 'Error':          this.statusText = `${this.str('status_error')}: ${state.errorMessage ?? ''}`; break;
      default:               this.statusText = ''; break;
    }
  }

  // ------------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------------

  private onSelectModel(modelId: string): void {
    this.selectedId = modelId;
    // setSelectedModel syncs cachedSelectedId immediately so the
    // following modelsExist() reads the *new* model, not the old one.
    LlamaEngine.setSelectedModel(getContext(this), modelId);
    this.modelExists = LlamaEngine.modelsExist(getContext(this));
    const m = findModelById(modelId);
    promptAction.showToast({ message: this.str('toast_model_selected').replace('%s', m.displayName), duration: 1500 });
    if (this.modelExists) {
      setTimeout(() => { this.onClickLoad(); }, 100);
    }
  }

  private async onClickDownload(): Promise<void> {
    if (this.modelExists) {
      promptAction.showToast({ message: this.str('toast_already_downloaded'), duration: 1500 });
      return;
    }
    this.downloading = true;
    this.downloadProgress = 0;
    this.statusText = this.str('status_downloading');
    try {
      await LlamaEngine.downloadModels(getContext(this), (msg) => {
        this.statusText = msg;
        const pctMatch = msg.match(/(\d+)%/);
        if (pctMatch) {
          this.downloadProgress = parseInt(pctMatch[1], 10);
        }
      });
      this.modelExists = LlamaEngine.modelsExist(getContext(this));
      this.statusText = this.str('download_complete_status');
      promptAction.showToast({ message: this.str('download_complete_toast'), duration: 1500 });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'download failed: %{public}s', `${e}`);
      this.statusText = this.str('toast_download_failed').replace('%s', `${e}`);
      promptAction.showToast({ message: this.str('toast_download_failed').replace('%s', `${e}`), duration: 4000 });
    } finally {
      this.downloading = false;
    }
  }

  private onClickLoad(): void {
    if (this.loadingLock) return;
    this.loadingLock = true;

    const ctx = getContext(this);
    const selectedModel = LlamaEngine.getSelectedModel(ctx);

    // TTS models (VoxCPM2): load both GGUF files via TtsEngine.
    if (selectedModel.isTts) {
      this.loadTtsModel();
      return;
    }

    // Non-TTS: load via LlamaEngine.
    if (!this.engine) { this.loadingLock = false; return; }
    const modelPath = LlamaEngine.modelPath(ctx);
    const mmprojPath = LlamaEngine.mmprojPath(ctx);
    if (!fs.accessSync(modelPath)) {
      promptAction.showToast({ message: this.str('toast_model_not_found'), duration: 4000 });
      this.loadingLock = false;
      return;
    }

    this.loading = true;
    this.statusText = this.str('status_loading');

    setTimeout(async () => {
      try {
        // loadModel auto-unloads if a model is already loaded,
        // so we don't need to call unloadModel() explicitly.
        const mm = (mmprojPath && fs.accessSync(mmprojPath)) ? mmprojPath : null;
        await this.engine!.loadModel(modelPath, mm);
        this.loading = false;
        this.loadingLock = false;
        promptAction.showToast({ message: this.str('toast_model_loaded'), duration: 1500 });
        const loaded = LlamaEngine.getSelectedModel(getContext(this));
        router.replaceUrl({ url: loaded.isOcr ? 'pages/OcrPage' : 'pages/Index' });
        return;
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'load failed: %{public}s', `${e}`);
        this.engine!.resetToInitialized();
        this.statusText = this.str('toast_load_failed').replace('%s', `${e}`);
        this.loading = false;
        this.loadingLock = false;
      }
    }, 50);
  }

  private loadTtsModel(): void {
    if (!this.ttsEngine) { this.loadingLock = false; return; }
    const ctx = getContext(this);
    const baseLmPath = LlamaEngine.modelPath(ctx);
    const acousticPath = LlamaEngine.acousticPath(ctx);

    if (!fs.accessSync(baseLmPath) || !acousticPath || !fs.accessSync(acousticPath)) {
      promptAction.showToast({ message: this.str('toast_model_not_found'), duration: 4000 });
      this.loadingLock = false;
      return;
    }

    // TtsEngine.loadModel handles reload internally (free + re-init).
    // No need to call free() separately here.
    this.loading = true;
    this.statusText = this.str('status_loading');

    (async () => {
      try {
        await this.ttsEngine!.loadModel(baseLmPath, acousticPath);
        this.loading = false;
        this.loadingLock = false;
        promptAction.showToast({ message: this.str('toast_model_loaded'), duration: 1500 });
        router.replaceUrl({ url: 'pages/TtsPage' });
        return;
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'TTS load failed: %{public}s', `${e}`);
        this.statusText = this.str('toast_load_failed').replace('%s', `${e}`);
        this.loading = false;
        this.loadingLock = false;
      }
    })();
  }

  private onClickDelete(): void {
    const m = findModelById(this.selectedId);
    const filesLine = m.mmprojFileName
      ? `\n• ${m.ggufFileName}\n• ${m.mmprojFileName}`
      : `\n• ${m.ggufFileName}`;
    AlertDialog.show({
      title: this.str('delete_dialog_title'),
      message: `${this.str('delete_dialog_message_prefix').replace('%s', m.displayName)}\n${filesLine}\n\n${this.str('delete_dialog_message_suffix')}`,
      autoCancel: true,
      primaryButton: { value: this.str('btn_delete'), action: () => this.doDelete() },
      secondaryButton: { value: this.str('btn_cancel'), action: () => undefined },
    });
  }

  private async doDelete(): Promise<void> {
    try {
      const deleted = await deleteSelectedModelFiles(getContext(this));
      this.modelExists = LlamaEngine.modelsExist(getContext(this));
      if (deleted) {
        this.statusText = this.str('model_files_deleted');
        promptAction.showToast({ message: this.str('model_files_deleted'), duration: 1500 });
      } else {
        promptAction.showToast({ message: this.str('toast_no_files_to_delete'), duration: 1500 });
      }
    } catch (e) {
      promptAction.showToast({ message: this.str('toast_delete_failed').replace('%s', `${e}`), duration: 3000 });
    }
  }

  private showLanguagePicker(): void {
    const options: AppLanguage[] = [AppLanguage.ZH, AppLanguage.EN];
    const current = this.currentLang;
    AlertDialog.show({
      title: this.str('language_picker_title'),
      message: ' ',
      autoCancel: true,
      primaryButton: {
        value: current === AppLanguage.ZH ? `${LocaleManager.displayName(AppLanguage.ZH)}  ✓` : LocaleManager.displayName(AppLanguage.ZH),
        action: () => {
          if (current !== AppLanguage.ZH) {
            this.switchLanguage(AppLanguage.ZH);
          }
        },
      },
      secondaryButton: {
        value: current === AppLanguage.EN ? `${LocaleManager.displayName(AppLanguage.EN)}  ✓` : LocaleManager.displayName(AppLanguage.EN),
        action: () => {
          if (current !== AppLanguage.EN) {
            this.switchLanguage(AppLanguage.EN);
          }
        },
      },
    });
  }

  private async switchLanguage(lang: AppLanguage): Promise<void> {
    await LocaleManager.setLanguage(getContext(this), lang);
    this.currentLang = lang;
    // Re-resolve all non-$r() strings after locale change.
    // Force a re-render by refreshing state-driven text.
    this.refreshLocalizedState();
  }

  private refreshLocalizedState(): void {
    // Re-evaluate statusText for the current engine state.
    if (this.engine) {
      const state = this.engine.getCurrentState();
      this.onEngineState(state);
    }
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  build() {
    Column() {
      this.AppBar();
      this.LanguageRow();
      this.StatusBar();
      this.ModelList();
      this.ActionBar();
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.surface'));
  }

  @Builder AppBar() {
    Row() {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Text('←').fontSize(18);
      }
      .width(36).height(36)
      .backgroundColor($r('app.color.surface_variant'))
      .fontColor($r('app.color.on_surface'))
      .margin({ left: 12, right: 12 })
      .onClick(() => router.back());

      Text($r('app.string.page_title_model'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_surface'))
        .layoutWeight(1);
    }
    .width('100%').height(56)
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 0.5 }, color: $r('app.color.outline') });
  }

  @Builder LanguageRow() {
    Row() {
      Text($r('app.string.settings_language'))
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .layoutWeight(1);
      Text(LocaleManager.displayName(this.currentLang))
        .fontSize(14)
        .fontColor($r('app.color.on_surface_variant'));
      Text(' ›')
        .fontSize(16)
        .fontColor($r('app.color.on_surface_variant'));
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor($r('app.color.surface'))
    .border({ width: { bottom: 0.5 }, color: $r('app.color.outline') })
    .onClick(() => this.showLanguagePicker());
  }

  @Builder StatusBar() {
    Column() {
      Text(this.statusText)
        .fontSize(14)
        .fontColor($r('app.color.on_surface_variant'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 });
      if (this.downloading) {
        Progress({ value: this.downloadProgress, total: 100, type: ProgressType.Linear })
          .width('100%').height(4)
          .margin({ left: 16, right: 16, bottom: 8 });
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'));
  }

  @Builder ModelList() {
    List() {
      ForEach(AVAILABLE_MODELS, (m: ModelInfo) => {
        ListItem() {
          Row() {
            Radio({ value: m.id, group: 'model' })
              .checked(this.selectedId === m.id)
              .onChange((checked: boolean) => {
                if (checked) this.onSelectModel(m.id);
              })
              .margin({ right: 12 });
            Column() {
              Text(m.displayName)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.on_surface'));
              Text(this.str(m.descriptionResName))
                .fontSize(13)
                .fontColor($r('app.color.on_surface_variant'))
                .margin({ top: 4 });
              Text(m.mmprojFileName ? `${m.ggufFileName} + ${m.mmprojFileName}` : m.ggufFileName)
                .fontSize(11)
                .fontColor($r('app.color.on_surface_variant'))
                .margin({ top: 6 });
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center);
        }
        .onClick(() => this.onSelectModel(m.id));
      }, (m: ModelInfo) => m.id)
    }
    .layoutWeight(1)
    .width('100%')
    .divider({ strokeWidth: 0.5, color: $r('app.color.outline') });
  }

  @Builder ActionBar() {
    Row({ space: 12 }) {
      Button(this.modelExists ? this.str('btn_downloaded') : this.str('btn_download'))
        .layoutWeight(1).height(44)
        .backgroundColor($r('app.color.surface_variant'))
        .fontColor($r('app.color.on_surface'))
        .enabled(!this.modelExists && !this.downloading)
        .onClick(() => this.onClickDownload());

      Button(this.loading ? this.str('status_loading') : (this.isModelReady ? this.str('btn_reload') : this.str('btn_load')))
        .layoutWeight(1).height(44)
        .backgroundColor(this.loading ? $r('app.color.surface_variant') : $r('app.color.primary'))
        .fontColor(this.loading ? $r('app.color.on_surface_variant') : $r('app.color.on_primary'))
        .enabled(this.modelExists && !this.loading && !this.downloading)
        .onClick(() => this.onClickLoad());

      Button($r('app.string.btn_delete'))
        .layoutWeight(1).height(44)
        .backgroundColor($r('app.color.surface_variant'))
        .fontColor($r('app.color.on_surface'))
        .enabled(this.modelExists && !this.loading && !this.downloading)
        .onClick(() => this.onClickDelete());
    }
    .width('100%')
    .padding(12)
    .border({ width: { top: 0.5 }, color: $r('app.color.outline') });
  }
}
