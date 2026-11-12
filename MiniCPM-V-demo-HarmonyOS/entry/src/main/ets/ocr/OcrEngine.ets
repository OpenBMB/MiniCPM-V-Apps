/**
 * The MiniCPM-OCR pipeline on HarmonyOS.
 *
 * Layout is detected with PP-DocLayoutV3 through @ohos/onnxruntime, each crop is
 * run through the vision tower and the text tower, and the results are stitched
 * back into markdown. Every rule here mirrors the Android client; only the
 * platform plumbing differs.
 */

import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LlamaEngine } from '../engine/LlamaEngine';
import { LayoutBox, LayoutDetector, RgbImage, pixelMapToRgb } from './LayoutDetector';
import { OcrCrop, buildCrops, downscale, rotate, score, shouldRetry } from './OcrLayout';
import {
  Block, assemble, classifyEngineText, hasMixedInlineFormula, normalize, postprocess,
} from './OcrMarkdown';
import { OcrElementPrompt, promptFor } from './OcrPrompts';

const DOMAIN: number = 0x0260;
const TAG: string = 'OcrEngine';

/** Pages are detected at this long edge; bigger pages gain nothing. */
const DETECT_LONG_EDGE: number = 1600;

/** Confidence above which a rotated page is considered better than the original. */
const ROTATE_MARGIN: number = 1.3;

export class OcrEngine {
  private detector: LayoutDetector | null = null;
  private readonly detectorPath: string;
  private readonly llama: LlamaEngine;
  private cancelled: boolean = false;

  constructor(llama: LlamaEngine, detectorPath: string) {
    this.llama = llama;
    this.detectorPath = detectorPath;
  }

  cancel(): void {
    this.cancelled = true;
    this.llama.cancelGeneration();
  }

  close(): void {
    if (this.detector !== null) {
      this.detector.close();
      this.detector = null;
    }
  }

  private ensureDetector(): LayoutDetector {
    if (this.detector === null) {
      this.detector = new LayoutDetector(this.detectorPath);
    }
    return this.detector;
  }

  /**
   * Recognises one page.
   *
   * [onStatus] reports the block currently being read so the UI can show
   * progress; [onToken] receives streamed text for the live view. The returned
   * markdown is the assembled page.
   */
  async recognizePage(
    page: image.PixelMap,
    onStatus: (label: string) => void,
    onToken: (text: string) => void,
  ): Promise<string> {
    this.cancelled = false;

    let work: image.PixelMap = await downscale(page, DETECT_LONG_EDGE);
    let boxes: LayoutBox[] = await this.detect(work);

    // A page photographed sideways produces tall, narrow "text" boxes. Retry
    // the three rotations and keep one only if it scores clearly better.
    if (shouldRetry(boxes)) {
      const upright: UprightResult | null = await this.findUpright(work, boxes);
      if (upright !== null) {
        if (work !== page) {
          await work.release();
        }
        work = upright.image;
        boxes = upright.boxes;
      }
    }

    const crops: OcrCrop[] = await buildCrops(boxes, work);
    hilog.info(DOMAIN, TAG, 'page %{public}dx%{public}d -> %{public}d crops',
      work.getImageInfoSync().size.width, work.getImageInfoSync().size.height, crops.length);

    const blocks: Block[] = [];
    for (let i = 0; i < crops.length; i++) {
      if (this.cancelled) {
        break;
      }
      const crop: OcrCrop = crops[i];
      const spec: OcrElementPrompt = promptFor(crop.label);
      if (spec.skip || spec.prompt.length === 0) {
        blocks.push(new Block(crop.label, '', crop.order));
        continue;
      }
      onStatus(crop.label);
      const raw: string = await this.recognizeCrop(crop, spec, onToken);
      if (this.cancelled) {
        break;
      }
      // Keep the live view readable: blocks arrive back to back otherwise.
      if (raw.trim().length > 0) {
        onToken('\n\n');
      }
      const cleaned: string = classifyEngineText(raw);
      const content: string = postprocess(cleaned, spec.outputFormat, crop.label);
      const mixed: boolean = crop.label === 'inline_formula' && hasMixedInlineFormula(content);
      blocks.push(new Block(crop.label, content, crop.order, mixed));
    }

    if (work !== page) {
      await work.release();
    }
    return assemble(normalize(blocks));
  }

  private async recognizeCrop(
    crop: OcrCrop, spec: OcrElementPrompt, onToken: (t: string) => void): Promise<string> {
    const png: ArrayBuffer = await packPng(crop.image);
    await this.llama.clearContext();
    await this.llama.prefillImage(png);
    const text: string = await streamPrompt(this.llama, spec.prompt, spec.maxTokens, onToken);
    return text;
  }

  private async detect(pm: image.PixelMap): Promise<LayoutBox[]> {
    const rgb: RgbImage = await pixelMapToRgb(pm);
    return await this.ensureDetector().detect(rgb);
  }

  /** Probes 90/180/270 on a small copy and re-detects the winner at full size. */
  private async findUpright(
    pm: image.PixelMap, base: LayoutBox[]): Promise<UprightResult | null> {
    const probe: image.PixelMap = await downscale(pm, 900);
    const baseScore: number = score(base);
    let bestDeg: number = 0;
    let bestScore: number = baseScore;

    for (const deg of [90, 180, 270]) {
      const turned: image.PixelMap = await rotate(probe, deg);
      try {
        const boxes: LayoutBox[] = await this.detect(turned);
        const s: number = score(boxes);
        if (s > bestScore * ROTATE_MARGIN) {
          bestScore = s;
          bestDeg = deg;
        }
      } finally {
        if (turned !== probe) {
          await turned.release();
        }
      }
    }
    if (probe !== pm) {
      await probe.release();
    }
    if (bestDeg === 0) {
      return null;
    }

    // A probe won; confirm on the full page rather than trusting the thumbnail.
    const full: image.PixelMap = await rotate(pm, bestDeg);
    const fullBoxes: LayoutBox[] = await this.detect(full);
    if (score(fullBoxes) <= baseScore) {
      await full.release();
      return null;
    }
    return new UprightResult(full, fullBoxes);
  }
}

class UprightResult {
  readonly image: image.PixelMap;
  readonly boxes: LayoutBox[];

  constructor(img: image.PixelMap, boxes: LayoutBox[]) {
    this.image = img;
    this.boxes = boxes;
  }
}

/** Re-encodes a crop as PNG, which is what the native prefill expects. */
async function packPng(pm: image.PixelMap): Promise<ArrayBuffer> {
  const packer: image.ImagePacker = image.createImagePacker();
  try {
    return await packer.packing(pm, { format: 'image/png', quality: 100 });
  } finally {
    packer.release();
  }
}

/**
 * Drains a token stream into one string.
 *
 * `sendUserPrompt` exposes an explicit `next()` rather than callbacks, so the
 * poll loop is wrapped here to keep the pipeline linear.
 */
async function streamPrompt(
  llama: LlamaEngine, prompt: string, maxTokens: number,
  onToken: (t: string) => void): Promise<string> {
  const parts: string[] = [];
  const stream = llama.sendUserPrompt(prompt, maxTokens);
  while (true) {
    const chunk = await stream.next();
    if (chunk.done) {
      break;
    }
    parts.push(chunk.value);
    onToken(chunk.value);
  }
  return parts.join('');
}
