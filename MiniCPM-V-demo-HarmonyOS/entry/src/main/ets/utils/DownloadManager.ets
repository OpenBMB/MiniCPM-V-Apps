// Multi-source racing downloader. Mirrors the Android LlamaEngine.kt
// downloadFileMultiSource path and iOS opt-r1's MBModelDownloadHelperV2.
//
// For every model file we register every available source (HuggingFace +
// ModelScope, plus an optional direct mirror) and run the GETs in parallel.
// The first task whose @ohos.request.agent emits a non-empty `progress` is
// taken as the winner; the other tasks are immediately `stop()`'d and
// removed, and their temporary files (`*.r0.tmp`, `*.r1.tmp`, ...) are
// deleted. Only the winner's bytes ever land in the canonical target path.
//
// Why progress-based and not response-headers-based: @ohos.request.agent is
// the OS-managed background download service; it doesn't expose raw HTTP
// response headers to ArkTS. The first `progress` callback with
// `processed > 0` is the closest analog to "got the first body byte" and
// behaves equivalently for our race semantics (the slower mirror will
// stay at `processed == 0` long enough for the winner to capture the slot).
//
// Streaming-md5 and the rest of the resume/cleanup logic match the Android
// implementation byte-for-byte.

import request from '@ohos.request';
import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import common from '@ohos.app.ability.common';
import dataPreferences from '@ohos.data.preferences';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import resourceManager from '@ohos.resourceManager';

import {
  ModelInfo,
  findModelById,
  AVAILABLE_MODELS,
  DEFAULT_MODEL,
} from '../engine/ModelInfo';

const DOMAIN = 0xC0DE;
const TAG = 'DownloadManager';
const PREFS_NAME = 'model_prefs';

export type ProgressListener = (msg: string) => void;

/** One physical source for a given file. */
interface RaceSource {
  label: string;
  url:   string;
}

/** A file plus all of its candidate sources for racing. */
interface MultiSourceJob {
  name:    string;          // local on-disk filename
  sources: RaceSource[];    // 1..N candidates; first non-empty progress wins
  md5:     string | null;
}

function str(rm: resourceManager.ResourceManager, name: string): string {
  return rm.getStringByNameSync(name);
}

// Async because the underlying preferences API is async; called from
// LlamaEngine.downloadModels which itself is awaited.
async function getSelectedModelAsync(context: common.Context): Promise<ModelInfo> {
  try {
    const p = await dataPreferences.getPreferences(context, PREFS_NAME);
    const id = await p.get('selected_model_id', DEFAULT_MODEL.id) as string;
    return findModelById(id);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'getSelectedModelAsync fallback to default: %{public}s', `${e}`);
    return DEFAULT_MODEL;
  }
}

export async function downloadModelsForSelected(
  context: common.Context,
  onProgress: ProgressListener,
): Promise<void> {
  const rm = context.resourceManager;
  const model = await getSelectedModelAsync(context);
  const dir = `${context.filesDir}/models/${model.id}`;
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true);
  }

  const ggufSources:   RaceSource[] = [];
  const mmprojSources: RaceSource[] = [];
  const acousticSources: RaceSource[] = [];
  const layoutSources: RaceSource[] = [];

  if (model.hasHfMsSources()) {
    const hfBase = `https://huggingface.co/${model.hfRepo}/resolve/${model.hfBranch}`;
    const msBase = `https://www.modelscope.cn/models/${model.msRepo}/resolve/${model.msBranch}`;
    ggufSources.push(  { label: 'HuggingFace', url: `${hfBase}/${model.ggufRemotePath()}`   });
    ggufSources.push(  { label: 'ModelScope',  url: `${msBase}/${model.ggufRemotePath()}`   });
    if (!model.isTextOnly) {
      mmprojSources.push({ label: 'HuggingFace', url: `${hfBase}/${model.mmprojRemotePath()}` });
      mmprojSources.push({ label: 'ModelScope',  url: `${msBase}/${model.mmprojRemotePath()}` });
    }
    if (model.isTts) {
      acousticSources.push({ label: 'HuggingFace', url: `${hfBase}/${model.acousticRemotePath()}` });
      acousticSources.push({ label: 'ModelScope',  url: `${msBase}/${model.acousticRemotePath()}` });
    }
    if (model.layout !== null) {
      layoutSources.push({ label: 'HuggingFace', url: `${hfBase}/${model.layout.remotePath()}` });
      layoutSources.push({ label: 'ModelScope',  url: `${msBase}/${model.layout.remotePath()}` });
    }
  }
  if (model.directGgufUrl) {
    ggufSources.push({ label: str(rm, 'source_direct'), url: model.directGgufUrl });
  }
  if (!model.isTextOnly && model.directMmprojUrl) {
    mmprojSources.push({ label: str(rm, 'source_direct'), url: model.directMmprojUrl });
  }
  if (model.isTts && model.directAcousticUrl) {
    acousticSources.push({ label: str(rm, 'source_direct'), url: model.directAcousticUrl });
  }
  if (model.layout !== null && model.layout.directUrl) {
    layoutSources.push({ label: str(rm, 'source_direct'), url: model.layout.directUrl });
  }
  if (ggufSources.length === 0) {
    throw new Error(`Model ${model.id} has no GGUF download source configured`);
  }
  if (!model.isTextOnly && mmprojSources.length === 0 && !model.isTts) {
    throw new Error(`Model ${model.id} has no mmproj download source configured`);
  }
  if (model.isTts && acousticSources.length === 0 && !model.hasHfMsSources()) {
    throw new Error(`Model ${model.id} has no acoustic download source configured`);
  }

  const labelSummary = ggufSources.map(s => s.label).join('+');
  onProgress(str(rm, 'download_race_start').replace('%s', labelSummary));

  const jobs: MultiSourceJob[] = [
    { name: model.ggufFileName,   sources: ggufSources,   md5: model.ggufMd5 },
  ];
  if (!model.isTextOnly && !model.isTts) {
    jobs.push({ name: model.mmprojFileName, sources: mmprojSources, md5: model.mmprojMd5 });
  }
  if (model.isTts && acousticSources.length > 0) {
    jobs.push({ name: model.acousticFileName, sources: acousticSources, md5: model.acousticMd5 });
  }
  if (model.layout !== null) {
    jobs.push({
      name: model.layout.fileName, sources: layoutSources, md5: model.layout.md5,
    });
  }
  for (const job of jobs) {
    await downloadFileWithSources(context, dir, job, onProgress);
  }
  onProgress(str(rm, 'download_all_complete'));
}

/**
 * Multi-source race download.
 */
async function downloadFileWithSources(
  context: common.Context,
  dir: string,
  job: MultiSourceJob,
  onProgress: ProgressListener,
): Promise<void> {
  const rm = context.resourceManager;
  const targetPath = `${dir}/${job.name}`;

  // Fast path: target already present and MD5 matches the manifest.
  if (fs.accessSync(targetPath) && job.md5) {
    onProgress(str(rm, 'download_verifying_existing').replace('%s', job.name));
    const actual = await computeMd5(targetPath);
    if (actual.toLowerCase() === job.md5.toLowerCase()) {
      onProgress(str(rm, 'download_file_ready').replace('%s', job.name));
      return;
    }
    hilog.warn(DOMAIN, TAG, '%{public}s MD5 mismatch (got %{public}s, want %{public}s); re-downloading',
               job.name, actual, job.md5);
    try { fs.unlinkSync(targetPath); } catch (_) { /* ignore */ }
  }

  // Single-source -> bypass race machinery for clarity / lower overhead.
  if (job.sources.length === 1) {
    const src = job.sources[0];
    if (isLoopbackUrl(src.url)) {
      await downloadViaHttpStream(context, dir, job, src, onProgress);
      return;
    }
    await downloadSingleSource(context, dir, job.name, src, job.md5, onProgress);
    return;
  }

  // A loopback mirror is only reachable through a device-local tunnel, which
  // request.agent refuses to schedule without an active network. Take it
  // directly and skip the race.
  for (const src of job.sources) {
    if (isLoopbackUrl(src.url)) {
      await downloadViaHttpStream(context, dir, job, src, onProgress);
      return;
    }
  }

  hilog.info(DOMAIN, TAG, 'Race-downloading %{public}s from %{public}d sources', job.name, job.sources.length);

  return new Promise<void>((resolve, reject) => {
    // Per-source state.
    const tmpPaths: string[] = job.sources.map((_, i) => `${targetPath}.r${i}.tmp`);
    const tasks: (request.agent.Task | null)[] = job.sources.map(() => null);
    const createFailures: number[] = [];
    const taskFailures:   number[] = [];
    let winnerIdx = -1;
    let settled = false;
    let lastProgressTime = 0;

    const stopLoser = (idx: number): void => {
      const task = tasks[idx];
      if (task) {
        try {
          task.stop().then(() => {
            request.agent.remove(task.tid).catch(() => undefined);
          }).catch(() => {
            request.agent.remove(task.tid).catch(() => undefined);
          });
        } catch (_) { /* ignore */ }
      }
      try {
        if (fs.accessSync(tmpPaths[idx])) fs.unlinkSync(tmpPaths[idx]);
      } catch (_) { /* ignore */ }
    };

    const cleanupLosers = (winIdx: number): void => {
      for (let j = 0; j < job.sources.length; j++) {
        if (j !== winIdx) stopLoser(j);
      }
    };

    const settleAllFailed = (): void => {
      if (settled) return;
      settled = true;
      reject(new Error(`${job.name}: all ${job.sources.length} sources failed`));
    };

    for (let i = 0; i < job.sources.length; i++) {
      const idx = i;
      const src = job.sources[idx];
      try {
        if (fs.accessSync(tmpPaths[idx])) fs.unlinkSync(tmpPaths[idx]);
      } catch (_) { /* ignore */ }

      hilog.info(DOMAIN, TAG, 'race[%{public}d] %{public}s start: %{public}s', idx, src.label, src.url);

      const config: request.agent.Config = {
        action: request.agent.Action.DOWNLOAD,
        url: src.url,
        headers: { 'User-Agent': 'MiniCPMV-demo/1.0' },
        saveas: tmpPaths[idx],
        overwrite: true,
        method: 'GET',
        mode: request.agent.Mode.FOREGROUND,
        network: request.agent.Network.ANY,
        retry: false,
      };

      request.agent.create(context, config).then((task: request.agent.Task) => {
        tasks[idx] = task;

        task.on('progress', (p: request.agent.Progress) => {
          // Race gate: first task to report non-empty bytes wins.
          if (winnerIdx === -1 && p.processed > 0) {
            winnerIdx = idx;
            hilog.info(DOMAIN, TAG, '%{public}s race winner: idx=%{public}d source=%{public}s',
                       job.name, idx, src.label);
            onProgress(str(rm, 'download_race_winner').replace('%s', src.label).replace('%s', job.name));
            cleanupLosers(idx);
          }
          if (winnerIdx !== idx) return;

          const now = Date.now();
          if (now - lastProgressTime > 500) {
            lastProgressTime = now;
            const got = p.processed;
            const totalArr = p.sizes;
            const total = totalArr && totalArr.length > 0 ? totalArr[0] : -1;
            if (total > 0) {
              const pct = Math.floor(got * 100 / total);
              const mb = Math.floor(got / (1024 * 1024));
              const totalMb = Math.floor(total / (1024 * 1024));
              onProgress(`${job.name}: ${pct}% (${mb}/${totalMb} MB) [${src.label}]`);
            } else {
              const mb = Math.floor(got / (1024 * 1024));
              onProgress(`${job.name}: ${mb} MB [${src.label}]`);
            }
          }
        });

        task.on('completed', async () => {
          if (settled) return;
          if (winnerIdx !== idx) {
            stopLoser(idx);
            return;
          }
          settled = true;
          try {
            if (fs.accessSync(targetPath)) fs.unlinkSync(targetPath);
            fs.renameSync(tmpPaths[idx], targetPath);

            if (job.md5) {
              onProgress(str(rm, 'download_verifying_md5').replace('%s', src.label).replace('%s', job.name));
              const actual = await computeMd5(targetPath);
              if (actual.toLowerCase() !== job.md5.toLowerCase()) {
                hilog.error(DOMAIN, TAG, '%{public}s MD5 mismatch: expected %{public}s, got %{public}s',
                            job.name, job.md5, actual);
                try { fs.unlinkSync(targetPath); } catch (_) { /* ignore */ }
                reject(new Error(
                  str(rm, 'download_md5_failed').replace('%s', job.name).replace('%s', job.md5).replace('%s', actual)
                ));
                return;
              }
              hilog.info(DOMAIN, TAG, '%{public}s MD5 OK (%{public}s)', job.name, actual);
            }

            const size = fs.statSync(targetPath).size;
            const mbSize = Math.floor(size / (1024 * 1024));
            onProgress(str(rm, 'download_file_complete').replace('%s', job.name).replace('%d', `${mbSize}`));
            resolve();
          } catch (e) {
            reject(e as object);
          } finally {
            request.agent.remove(task.tid).catch(() => undefined);
            cleanupLosers(idx);
          }
        });

        task.on('failed', () => {
          if (settled) return;
          if (winnerIdx === idx) {
            settled = true;
            request.agent.show(task.tid).then(info => {
              reject(new Error(
                str(rm, 'download_source_failed_detail').replace('%s', src.label).replace('%s', JSON.stringify(info.faults))
              ));
            }).catch(() => {
              reject(new Error(str(rm, 'download_source_failed').replace('%s', src.label)));
            }).finally(() => {
              request.agent.remove(task.tid).catch(() => undefined);
              try {
                if (fs.accessSync(tmpPaths[idx])) fs.unlinkSync(tmpPaths[idx]);
              } catch (_) { /* ignore */ }
            });
            return;
          }
          taskFailures.push(idx);
          hilog.warn(DOMAIN, TAG, '%{public}s race source %{public}s failed (%{public}d/%{public}d)',
                     job.name, src.label, taskFailures.length + createFailures.length, job.sources.length);
          request.agent.remove(task.tid).catch(() => undefined);
          try {
            if (fs.accessSync(tmpPaths[idx])) fs.unlinkSync(tmpPaths[idx]);
          } catch (_) { /* ignore */ }
          if (taskFailures.length + createFailures.length >= job.sources.length) {
            settleAllFailed();
          }
        });

        task.start().catch((e: BusinessError) => {
          if (settled) return;
          hilog.warn(DOMAIN, TAG, '%{public}s race source %{public}s task.start() failed: %{public}s',
                     job.name, src.label, `${e}`);
          taskFailures.push(idx);
          request.agent.remove(task.tid).catch(() => undefined);
          if (taskFailures.length + createFailures.length >= job.sources.length) {
            settleAllFailed();
          }
        });
      }).catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '%{public}s race source %{public}s agent.create failed: %{public}s',
                   job.name, src.label, `${e}`);
        createFailures.push(idx);
        if (taskFailures.length + createFailures.length >= job.sources.length) {
          settleAllFailed();
        }
      });
    }
  });
}

/** Simple wrapper for the rare 1-source case (e.g. legacy direct-mirror only). */
/** True for URLs that only resolve on this device (dev mirrors over a tunnel). */
function isLoopbackUrl(url: string): boolean {
  return url.indexOf('://127.0.0.1') >= 0 || url.indexOf('://localhost') >= 0;
}

/**
 * Streams a URL straight into [targetPath].
 *
 * request.agent needs an active network to schedule anything, so it never
 * starts when the only route is loopback. This path dials the socket itself and
 * is used for the direct-URL escape hatch.
 */
async function downloadViaHttpStream(
  context: common.Context,
  dir: string,
  job: MultiSourceJob,
  src: RaceSource,
  onProgress: ProgressListener,
): Promise<void> {
  const rm = context.resourceManager;
  const targetPath = `${dir}/${job.name}`;
  const tmpPath = `${targetPath}.stream.tmp`;
  const fileName = job.name;

  onProgress(str(rm, 'download_fetching_file').replace('%s', src.label).replace('%s', fileName));

  const client = http.createHttp();
  let file: fs.File | null = null;
  let written = 0;
  let lastTick = 0;

  try {
    file = fs.openSync(tmpPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    const fd = file.fd;

    client.on('dataReceive', (chunk: ArrayBuffer) => {
      if (chunk && chunk.byteLength > 0) {
        fs.writeSync(fd, chunk, { offset: written });
        written += chunk.byteLength;
      }
    });
    client.on('dataReceiveProgress', (p: http.DataReceiveProgressInfo) => {
      const now = Date.now();
      if (now - lastTick < 500) return;
      lastTick = now;
      const gotMb = Math.floor(p.receiveSize / (1024 * 1024));
      if (p.totalSize > 0) {
        const pct = Math.floor(p.receiveSize * 100 / p.totalSize);
        const totalMb = Math.floor(p.totalSize / (1024 * 1024));
        onProgress(`${fileName}: ${pct}% (${gotMb}/${totalMb} MB) [${src.label}]`);
      } else {
        onProgress(`${fileName}: ${gotMb} MB [${src.label}]`);
      }
    });

    const code = await new Promise<number>((resolve, reject) => {
      client.requestInStream(src.url, {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 120000,
      }, (err: BusinessError, responseCode: number) => {
        if (err) {
          reject(new Error(`${src.label} ${fileName}: ${err.message} (${err.code})`));
          return;
        }
        resolve(responseCode);
      });
    });
    if (code !== 200) {
      throw new Error(`${src.label} ${fileName}: HTTP ${code}`);
    }

    // The callback fires once headers are read; body chunks keep arriving until
    // dataEnd. Give the last chunk a moment to land before rotating the file.
    await new Promise<void>((resolve) => setTimeout(resolve, 300));
  } finally {
    client.off('dataReceive');
    client.off('dataReceiveProgress');
    client.destroy();
    if (file !== null) {
      fs.closeSync(file);
    }
  }

  if (written === 0) {
    try { fs.unlinkSync(tmpPath); } catch (_) { /* ignore */ }
    throw new Error(`${src.label} ${fileName}: empty body`);
  }

  if (job.md5) {
    onProgress(str(rm, 'download_verifying_md5').replace('%s', src.label).replace('%s', fileName));
    const actual = await computeMd5(tmpPath);
    if (actual.toLowerCase() !== job.md5.toLowerCase()) {
      try { fs.unlinkSync(tmpPath); } catch (_) { /* ignore */ }
      throw new Error(
        str(rm, 'download_md5_failed').replace('%s', fileName).replace('%s', job.md5).replace('%s', actual)
      );
    }
  }

  try { if (fs.accessSync(targetPath)) fs.unlinkSync(targetPath); } catch (_) { /* ignore */ }
  fs.renameSync(tmpPath, targetPath);
  const mbSize = Math.floor(fs.statSync(targetPath).size / (1024 * 1024));
  onProgress(str(rm, 'download_file_complete').replace('%s', fileName).replace('%d', `${mbSize}`));
}

async function downloadSingleSource(
  context: common.Context,
  dir: string,
  fileName: string,
  src: RaceSource,
  md5: string | null,
  onProgress: ProgressListener,
): Promise<void> {
  const rm = context.resourceManager;
  const targetPath = `${dir}/${fileName}`;
  onProgress(str(rm, 'download_fetching_file').replace('%s', src.label).replace('%s', fileName));
  hilog.info(DOMAIN, TAG, 'Downloading %{public}s from %{public}s: %{public}s',
             fileName, src.label, src.url);

  const tmpPath = `${targetPath}.tmp`;
  if (fs.accessSync(tmpPath)) fs.unlinkSync(tmpPath);

  await new Promise<void>((resolve, reject) => {
    let lastProgressTime = 0;
    const config: request.agent.Config = {
      action: request.agent.Action.DOWNLOAD,
      url: src.url,
      headers: { 'User-Agent': 'MiniCPMV-demo/1.0' },
      saveas: tmpPath,
      overwrite: true,
      method: 'GET',
      mode: request.agent.Mode.FOREGROUND,
      network: request.agent.Network.ANY,
      retry: false,
    };
    request.agent.create(context, config).then((task: request.agent.Task) => {
      task.on('progress', (p: request.agent.Progress) => {
        const now = Date.now();
        if (now - lastProgressTime > 500) {
          lastProgressTime = now;
          const got = p.processed;
          const totalArr = p.sizes;
          const total = totalArr && totalArr.length > 0 ? totalArr[0] : -1;
          if (total > 0) {
            const pct = Math.floor(got * 100 / total);
            const mb = Math.floor(got / (1024 * 1024));
            const totalMb = Math.floor(total / (1024 * 1024));
            onProgress(`${fileName}: ${pct}% (${mb}/${totalMb} MB)`);
          } else {
            const mb = Math.floor(got / (1024 * 1024));
            onProgress(`${fileName}: ${mb} MB`);
          }
        }
      });
      task.on('completed', async () => {
        try {
          if (fs.accessSync(targetPath)) fs.unlinkSync(targetPath);
          fs.renameSync(tmpPath, targetPath);
          resolve();
        } catch (e) {
          reject(e as object);
        } finally {
          request.agent.remove(task.tid).catch(() => undefined);
        }
      });
      task.on('failed', () => {
        request.agent.show(task.tid).then(info => {
          reject(new Error(`Download failed: ${JSON.stringify(info.faults)}`));
        }).catch(() => {
          reject(new Error('Download failed'));
        }).finally(() => {
          request.agent.remove(task.tid).catch(() => undefined);
        });
      });
      task.start();
    }).catch((e: object) => reject(e));
  });

  if (md5) {
    onProgress(str(rm, 'download_verifying_md5').replace('%s', src.label).replace('%s', fileName));
    const actual = await computeMd5(targetPath);
    if (actual.toLowerCase() !== md5.toLowerCase()) {
      hilog.error(DOMAIN, TAG, '%{public}s MD5 mismatch: expected %{public}s, got %{public}s',
                  fileName, md5, actual);
      try { fs.unlinkSync(targetPath); } catch (_) { /* ignore */ }
      throw new Error(
        str(rm, 'download_md5_failed').replace('%s', fileName).replace('%s', md5).replace('%s', actual)
      );
    }
    hilog.info(DOMAIN, TAG, '%{public}s MD5 OK (%{public}s)', fileName, actual);
  }

  const size = fs.statSync(targetPath).size;
  const mbSize = Math.floor(size / (1024 * 1024));
  onProgress(str(rm, 'download_file_complete').replace('%s', fileName).replace('%d', `${mbSize}`));
}

// Streaming MD5 — keeps memory bounded on the 1GB+ mmproj. 64KB chunks
// give ~150 MB/s on the test phone, identical to the Android implementation.
export async function computeMd5(path: string): Promise<string> {
  const md = cryptoFramework.createMd('MD5');
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const CHUNK = 64 * 1024;
    const buf = new ArrayBuffer(CHUNK);
    let offset = 0;
    while (true) {
      const read = fs.readSync(file.fd, buf, { offset, length: CHUNK });
      if (read <= 0) break;
      // The crypto framework expects a DataBlob; copy only the read portion.
      const slice = read === CHUNK ? buf : buf.slice(0, read);
      await md.update({ data: new Uint8Array(slice) });
      offset += read;
    }
    const digest = await md.digest();
    return bytesToHex(digest.data);
  } finally {
    fs.closeSync(file);
  }
}

function bytesToHex(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    const h = bytes[i].toString(16);
    s += h.length === 1 ? `0${h}` : h;
  }
  return s;
}

// Convenience wrapper used by ModelManager to delete the currently
// selected model's two files. Mirrors deleteModelFiles() on Android.
export async function deleteSelectedModelFiles(context: common.Context): Promise<boolean> {
  const model = await getSelectedModelAsync(context);
  const dir = `${context.filesDir}/models/${model.id}`;
  let deleted = false;
  const filesToDelete: string[] = [model.ggufFileName];
  if (model.mmprojFileName) {
    filesToDelete.push(model.mmprojFileName);
  }
  if (model.acousticFileName) {
    filesToDelete.push(model.acousticFileName);
  }
  if (model.layout !== null) {
    filesToDelete.push(model.layout.fileName);
  }
  for (const name of filesToDelete) {
    const p = `${dir}/${name}`;
    if (fs.accessSync(p)) {
      try { fs.unlinkSync(p); deleted = true; }
      catch (e) {
        hilog.warn(DOMAIN, TAG, 'unlink %{public}s failed: %{public}s', p, `${e}`);
      }
    }
  }
  return deleted;
}
