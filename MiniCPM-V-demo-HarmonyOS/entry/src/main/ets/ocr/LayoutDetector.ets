/**
 * PP-DocLayoutV3 layout detection on HarmonyOS.
 *
 * Ported from the Android client, which in turn matches iOS LayoutBridge.mm:
 * the same 800x800 Catmull-Rom stretch, the same sigmoid-clipped query scores,
 * the +1px NMS IoU and the separate 90% containment test. Keeping the three
 * platforms bit-compatible matters because layout boxes decide the crops, and a
 * shifted crop changes what the model reads.
 */

import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import * as api from '@ohos/onnxruntime';

const DOMAIN: number = 0x0260;
const TAG: string = 'LayoutDetector';

/** One layout box in original-image pixels. */
export interface LayoutBox {
  labelId: number;
  label: string;
  score: number;
  x1: number;
  y1: number;
  x2: number;
  y2: number;
}

interface Det {
  label: number;
  score: number;
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  order: number;
}

const INPUT: number = 800;
const CLASSES: number = 25;
const QUERIES: number = 300;

/** Label ids are the model's output indices; see OcrPrompts.labelIdToName. */
const LABEL_NAMES: string[] = [
  'abstract', 'algorithm', 'aside_text', 'chart', 'content', 'display_formula',
  'doc_title', 'figure_title', 'footer', 'footer_image', 'footnote',
  'formula_number', 'header', 'header_image', 'image', 'inline_formula',
  'number', 'paragraph_title', 'reference', 'reference_content', 'seal',
  'table', 'text', 'vertical_text', 'vision_footnote',
];

/** A page decoded to interleaved RGB, which is what the preprocessor wants. */
export interface RgbImage {
  width: number;
  height: number;
  rgb: Uint8Array;
}

export class LayoutDetector {
  private session: api.OnnxSession | null = null;
  private pixelName: string = '';
  private maskName: string = '';

  constructor(modelPath: string) {
    api.OnnxEnvironment.InitEnvironment();
    this.session = api.OnnxEnvironment.CreateSessionFromModelFile(modelPath);
    const names: string[] = this.session.GetInputNames();
    for (const n of names) {
      if (n.indexOf('mask') >= 0) {
        this.maskName = n;
      } else {
        this.pixelName = n;
      }
    }
  }

  close(): void {
    this.session = null;
  }

  async detect(img: RgbImage, threshold: number = 0.3): Promise<LayoutBox[]> {
    if (this.session === null || img.width <= 0 || img.height <= 0) {
      return [];
    }
    const t0: number = Date.now();
    const pixels: ArrayBuffer = await preprocess(img);
    const t1: number = Date.now();
    const maskBuffer: ArrayBuffer = new ArrayBuffer(INPUT * INPUT * 4);
    new Float32Array(maskBuffer).fill(1);

    const inputs: Record<string, api.OnnxValue> = {};
    inputs[this.pixelName] = new api.OnnxTensor(
      pixels, [1, 3, INPUT, INPUT], api.OnnxArkTSType.FLOAT);
    inputs[this.maskName] = new api.OnnxTensor(
      maskBuffer, [1, INPUT, INPUT], api.OnnxArkTSType.FLOAT);

    const result: api.OnnxResult = this.session.Run(inputs);
    const t2: number = Date.now();
    const logits: Float32Array = outputFloats(result, 'logits');
    const boxes: Float32Array = outputFloats(result, 'pred_boxes');
    const orderLogits: Float32Array = outputFloats(result, 'order_logits');
    const found: LayoutBox[] = decode(logits, boxes, orderLogits, img.width, img.height, threshold);
    hilog.info(DOMAIN, TAG, 'detect %{public}dx%{public}d: preprocess=%{public}dms run=%{public}dms decode=%{public}dms boxes=%{public}d',
               img.width, img.height, t1 - t0, t2 - t1, Date.now() - t2, found.length);
    return found;
  }
}

function outputFloats(result: api.OnnxResult, name: string): Float32Array {
  const value: api.OnnxValue = result.GetValueByName(name);
  const tensor: api.OnnxTensor = value as api.OnnxTensor;
  return new Float32Array(tensor.GetDataAsArrayBuffer());
}

function decode(
  logits: Float32Array, boxes: Float32Array, orderLogits: Float32Array,
  width: number, height: number, threshold: number): LayoutBox[] {
  const scores: Float32Array = new Float32Array(QUERIES * CLASSES);
  for (let i = 0; i < scores.length; i++) {
    scores[i] = sigmoidClip(logits[i]);
  }

  // One label per query: rank every (query, class) pair and keep the best
  // class of each query, which is what the reference decoder does.
  const rank: number[] = Array.from(scores.keys());
  rank.sort((a: number, b: number) => scores[b] - scores[a] || a - b);
  const orderSeq: number[] = orderSeqs(orderLogits, QUERIES);

  const raw: Det[] = [];
  for (let k = 0; k < QUERIES; k++) {
    const flat: number = rank[k];
    const label: number = flat % CLASSES;
    const q: number = Math.floor(flat / CLASSES);
    const cx: number = boxes[q * 4];
    const cy: number = boxes[q * 4 + 1];
    const bw: number = boxes[q * 4 + 2];
    const bh: number = boxes[q * 4 + 3];
    raw.push({
      label: label,
      score: scores[flat],
      x1: Math.round((cx - 0.5 * bw) * width),
      y1: Math.round((cy - 0.5 * bh) * height),
      x2: Math.round((cx + 0.5 * bw) * width),
      y2: Math.round((cy + 0.5 * bh) * height),
      order: orderSeq[q],
    });
  }

  let kept: Det[] = raw.filter((d: Det) => d.score > threshold && d.label > -1);
  if (kept.length === 0) {
    return [];
  }
  kept = nms(kept);
  if (kept.length === 0) {
    return [];
  }

  // Drop whole-page "image" boxes: they duplicate everything else on the page.
  if (kept.length > 1) {
    const imgArea: number = width * height;
    const areaThres: number = width > height ? 0.82 : 0.93;
    const filtered: Det[] = kept.filter((b: Det) => {
      if (b.label !== 14) {
        return true;
      }
      const x1: number = Math.max(0, b.x1);
      const y1: number = Math.max(0, b.y1);
      const x2: number = Math.min(width, b.x2);
      const y2: number = Math.min(height, b.y2);
      return (x2 - x1) * (y2 - y1) <= areaThres * imgArea;
    });
    if (filtered.length > 0) {
      kept = filtered;
    }
  }

  // A title or caption inside a figure/table block is a duplicate.
  if (kept.length >= 2) {
    const cats: number[] = [3, 5, 6, 15, 17];
    const keepMask: boolean[] = kept.map(() => true);
    for (const cat of cats) {
      const contained: boolean[] = kept.map(() => false);
      for (let i = 0; i < kept.length; i++) {
        for (let j = 0; j < kept.length; j++) {
          if (i !== j && kept[j].label === cat && contained90(kept[i], kept[j])) {
            contained[i] = true;
          }
        }
      }
      for (let i = 0; i < kept.length; i++) {
        if (contained[i]) {
          keepMask[i] = false;
        }
      }
    }
    kept = kept.filter((_: Det, i: number) => keepMask[i]);
  }
  if (kept.length === 0) {
    return [];
  }

  kept.sort((a: Det, b: Det) => a.order - b.order);
  const out: LayoutBox[] = [];
  for (const b of kept) {
    const x1: number = Math.max(0, b.x1);
    const y1: number = Math.max(0, b.y1);
    const x2: number = Math.min(width, b.x2);
    const y2: number = Math.min(height, b.y2);
    if (x2 <= x1 || y2 <= y1) {
      continue;
    }
    out.push({
      labelId: b.label,
      label: LABEL_NAMES[b.label] ?? 'text',
      score: b.score,
      x1: x1, y1: y1, x2: x2, y2: y2,
    });
  }
  return out;
}

function nms(boxes: Det[]): Det[] {
  const order: number[] = boxes.map((_: Det, i: number) => i);
  order.sort((a: number, b: number) => boxes[b].score - boxes[a].score || a - b);
  const dead: boolean[] = boxes.map(() => false);
  const kept: Det[] = [];
  for (let n = 0; n < order.length; n++) {
    const c: number = order[n];
    if (dead[c]) {
      continue;
    }
    kept.push(boxes[c]);
    for (let m = n + 1; m < order.length; m++) {
      const r: number = order[m];
      if (dead[r]) {
        continue;
      }
      // Same-label boxes overlap freely; a different label is only suppressed
      // on near-total overlap, so a caption is not eaten by its figure.
      const thr: number = boxes[c].label !== boxes[r].label ? 0.98 : 0.6;
      if (iouPlus1(boxes[c], boxes[r]) >= thr) {
        dead[r] = true;
      }
    }
  }
  return kept;
}

function iouPlus1(a: Det, b: Det): number {
  const iw: number = Math.min(a.x2, b.x2) - Math.max(a.x1, b.x1) + 1;
  const ih: number = Math.min(a.y2, b.y2) - Math.max(a.y1, b.y1) + 1;
  if (iw <= 0 || ih <= 0) {
    return 0;
  }
  const ia: number = iw * ih;
  const a1: number = (a.x2 - a.x1 + 1) * (a.y2 - a.y1 + 1);
  const a2: number = (b.x2 - b.x1 + 1) * (b.y2 - b.y1 + 1);
  const denom: number = a1 + a2 - ia;
  return denom > 0 ? ia / denom : 0;
}

function contained90(inner: Det, outer: Det): boolean {
  const iw: number = Math.max(0, Math.min(inner.x2, outer.x2) - Math.max(inner.x1, outer.x1));
  const ih: number = Math.max(0, Math.min(inner.y2, outer.y2) - Math.max(inner.y1, outer.y1));
  const ia: number = iw * ih;
  const a1: number = (inner.x2 - inner.x1) * (inner.y2 - inner.y1);
  return a1 > 0 && ia / a1 >= 0.9;
}

function orderSeqs(orderLogits: Float32Array, n: number): number[] {
  const os: Float32Array = new Float32Array(n * n);
  for (let i = 0; i < os.length; i++) {
    os[i] = sigmoidClip(orderLogits[i]);
  }
  const votes: Float32Array = new Float32Array(n);
  for (let j = 0; j < n; j++) {
    for (let i = 0; i < j; i++) {
      votes[j] += os[i * n + j];
    }
    for (let i = j + 1; i < n; i++) {
      votes[j] += 1 - os[j * n + i];
    }
  }
  const ptrs: number[] = [];
  for (let i = 0; i < n; i++) {
    ptrs.push(i);
  }
  ptrs.sort((a: number, b: number) => votes[a] - votes[b] || a - b);
  const seq: number[] = new Array<number>(n).fill(0);
  for (let k = 0; k < ptrs.length; k++) {
    seq[ptrs[k]] = k;
  }
  return seq;
}

function sigmoidClip(xIn: number): number {
  const x: number = Math.max(-50, Math.min(50, xIn));
  return 1 / (1 + Math.exp(-x));
}

/**
 * Stretch to 800x800 with Catmull-Rom, align_corners = false.
 *
 * The x and y taps only depend on the axis, so they are resolved once instead
 * of per pixel; the inner loop then does 16 multiplies with no branching.
 * Rows are batched so the caller can yield to the UI thread in between.
 *
 * Returns the raw buffer rather than a typed-array view: the native tensor
 * constructor takes an ArrayBuffer, and handing it `view.buffer` risks passing
 * a SharedArrayBuffer through a cast it cannot unwrap.
 */
async function preprocess(img: RgbImage): Promise<ArrayBuffer> {
  const width: number = img.width;
  const height: number = img.height;
  const scaleX: number = INPUT / width;
  const scaleY: number = INPUT / height;
  const outBuffer: ArrayBuffer = new ArrayBuffer(3 * INPUT * INPUT * 4);
  const out: Float32Array = new Float32Array(outBuffer);

  const sxIdx: Int32Array = new Int32Array(INPUT * 4);
  const wxAll: Float32Array = new Float32Array(INPUT * 4);
  for (let x = 0; x < INPUT; x++) {
    const srcX: number = (x + 0.5) / scaleX - 0.5;
    const base: number = Math.floor(srcX) - 1;
    for (let t = 0; t < 4; t++) {
      let sx: number = base + t;
      if (sx < 0) {
        sx = 0;
      } else if (sx >= width) {
        sx = width - 1;
      }
      sxIdx[x * 4 + t] = sx;
      wxAll[x * 4 + t] = cubic(srcX - (base + t));
    }
  }

  const syIdx: Int32Array = new Int32Array(INPUT * 4);
  const wyAll: Float32Array = new Float32Array(INPUT * 4);
  for (let y = 0; y < INPUT; y++) {
    const srcY: number = (y + 0.5) / scaleY - 0.5;
    const base: number = Math.floor(srcY) - 1;
    for (let t = 0; t < 4; t++) {
      let sy: number = base + t;
      if (sy < 0) {
        sy = 0;
      } else if (sy >= height) {
        sy = height - 1;
      }
      syIdx[y * 4 + t] = sy;
      wyAll[y * 4 + t] = cubic(srcY - (base + t));
    }
  }

  for (let c = 0; c < 3; c++) {
    const chan: number = c * INPUT * INPUT;
    for (let y = 0; y < INPUT; y++) {
      const r0: number = syIdx[y * 4];
      const r1: number = syIdx[y * 4 + 1];
      const r2: number = syIdx[y * 4 + 2];
      const r3: number = syIdx[y * 4 + 3];
      const wy0: number = wyAll[y * 4];
      const wy1: number = wyAll[y * 4 + 1];
      const wy2: number = wyAll[y * 4 + 2];
      const wy3: number = wyAll[y * 4 + 3];
      const b0: number = r0 * width * 3 + c;
      const b1: number = r1 * width * 3 + c;
      const b2: number = r2 * width * 3 + c;
      const b3: number = r3 * width * 3 + c;

      for (let x = 0; x < INPUT; x++) {
        const i0: number = b0 + sxIdx[x * 4] * 3;
        const i1: number = b0 + sxIdx[x * 4 + 1] * 3;
        const i2: number = b0 + sxIdx[x * 4 + 2] * 3;
        const i3: number = b0 + sxIdx[x * 4 + 3] * 3;
        const wx0: number = wxAll[x * 4];
        const wx1: number = wxAll[x * 4 + 1];
        const wx2: number = wxAll[x * 4 + 2];
        const wx3: number = wxAll[x * 4 + 3];

        const t0: number = wx0 * img.rgb[i0] + wx1 * img.rgb[i1]
                         + wx2 * img.rgb[i2] + wx3 * img.rgb[i3];
        const t1: number = wx0 * img.rgb[b1 + sxIdx[x * 4] * 3] + wx1 * img.rgb[b1 + sxIdx[x * 4 + 1] * 3]
                         + wx2 * img.rgb[b1 + sxIdx[x * 4 + 2] * 3] + wx3 * img.rgb[b1 + sxIdx[x * 4 + 3] * 3];
        const t2: number = wx0 * img.rgb[b2 + sxIdx[x * 4] * 3] + wx1 * img.rgb[b2 + sxIdx[x * 4 + 1] * 3]
                         + wx2 * img.rgb[b2 + sxIdx[x * 4 + 2] * 3] + wx3 * img.rgb[b2 + sxIdx[x * 4 + 3] * 3];
        const t3: number = wx0 * img.rgb[b3 + sxIdx[x * 4] * 3] + wx1 * img.rgb[b3 + sxIdx[x * 4 + 1] * 3]
                         + wx2 * img.rgb[b3 + sxIdx[x * 4 + 2] * 3] + wx3 * img.rgb[b3 + sxIdx[x * 4 + 3] * 3];

        out[chan + y * INPUT + x] =
          (wy0 * t0 + wy1 * t1 + wy2 * t2 + wy3 * t3) / 255;
      }

      if ((y & 31) === 31) {
        await yieldOnce();
      }
    }
  }
  return outBuffer;
}

/** Lets the UI thread service its queue so the freeze watchdog stays quiet. */
function yieldOnce(): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, 0));
}

function cubic(xIn: number): number {
  const x: number = Math.abs(xIn);
  if (x < 1) {
    return (1.25 * x - 2.25) * x * x + 1;
  }
  if (x < 2) {
    return ((-0.75 * x + 3.75) * x - 6) * x + 3;
  }
  return 0;
}

/**
 * Reads a PixelMap into interleaved RGB.
 *
 * PixelMap hands back whatever the decoder produced, usually BGRA_8888, so the
 * channel order has to be resolved from the image info rather than assumed.
 */
export async function pixelMapToRgb(pm: image.PixelMap): Promise<RgbImage> {
  const info: image.ImageInfo = await pm.getImageInfo();
  const width: number = info.size.width;
  const height: number = info.size.height;
  const dst: ArrayBuffer = new ArrayBuffer(width * height * 4);
  await pm.readPixelsToBuffer(dst);
  const src: Uint8Array = new Uint8Array(dst);
  const rgb: Uint8Array = new Uint8Array(width * height * 3);

  // RGBA_8888 stores R first, BGRA_8888 stores B first. Both are 4 bytes per
  // pixel, so only the red and blue offsets differ.
  const bgra: boolean = info.pixelFormat === image.PixelMapFormat.BGRA_8888;
  const rOff: number = bgra ? 2 : 0;
  const bOff: number = bgra ? 0 : 2;
  for (let i = 0; i < width * height; i++) {
    rgb[i * 3] = src[i * 4 + rOff];
    rgb[i * 3 + 1] = src[i * 4 + 1];
    rgb[i * 3 + 2] = src[i * 4 + bOff];
  }
  return { width: width, height: height, rgb: rgb };
}
