import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import { preferences } from '@kit.ArkData';

import { LlamaEngine } from '../engine/LlamaEngine';
import { LocaleManager } from '../manager/LocaleManager';
import { findModelById } from '../engine/ModelInfo';

const DOMAIN = 0xC0DE;
const TAG = 'EntryAbility';
const PREFS_NAME = 'model_prefs';
const KEY_SELECTED_MODEL = 'selected_model_id';
const DEFAULT_MODEL_ID = 'minicpm-v-4_6-instruct';

export default class EntryAbility extends UIAbility {
  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    hilog.info(DOMAIN, TAG, 'Ability onCreate (launchReason=%{public}d)',
               launchParam.launchReason);
    await LocaleManager.applyOnAppStart(this.context);
    LlamaEngine.migrateLegacyLayoutIfNeeded(this.context);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    let page = 'pages/Index';
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      const id = prefs.getSync(KEY_SELECTED_MODEL, DEFAULT_MODEL_ID) as string;
      LlamaEngine.warmCache(id);
      const model = findModelById(id);
      if (model.isTts) {
        page = 'pages/TtsPage';
      } else if (model.isOcr) {
        page = 'pages/OcrPage';
      }
      hilog.info(DOMAIN, TAG, 'Selected model: %{public}s, isTts=%{public}s → %{public}s',
                 id, `${model.isTts}`, page);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to read model preference: %{public}s', `${e}`);
    }

    windowStage.loadContent(page, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s loaded', page);
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Window stage destroyed');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Foreground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Background');
  }
}
