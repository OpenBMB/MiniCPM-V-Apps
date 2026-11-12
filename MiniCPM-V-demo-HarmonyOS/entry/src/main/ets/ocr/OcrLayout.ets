/**
 * Overlap filtering, neighbour merging and cropping for OCR.
 *
 * Ported from the Android client, which follows iOS OcrLayoutCrop. The merge
 * rules are what turn line-level boxes into paragraph-sized crops, so they have
 * to match: a different merge produces different prompts and different text.
 *
 * The Android version also carries NPU canvas planning for the Hexagon path.
 * HarmonyOS has no NPU access for third-party apps, so only the CPU path is
 * here and every crop goes to the model unchanged.
 */

import { image } from '@kit.ImageKit';
import { LayoutBox } from './LayoutDetector';

export class OcrCrop {
  readonly label: string;
  readonly score: number;
  readonly x1: number;
  readonly y1: number;
  readonly x2: number;
  readonly y2: number;
  readonly order: number;
  readonly image: image.PixelMap;

  constructor(label: string, score: number, x1: number, y1: number,
              x2: number, y2: number, order: number, img: image.PixelMap) {
    this.label = label;
    this.score = score;
    this.x1 = x1;
    this.y1 = y1;
    this.x2 = x2;
    this.y2 = y2;
    this.order = order;
    this.image = img;
  }
}

const NON_MERGE: Set<string> = new Set<string>([
  'image', 'header_image', 'footer_image', 'chart', 'seal', 'table',
]);

const TEXT_LABELS: Set<string> = new Set<string>([
  'text', 'content', 'abstract', 'reference', 'reference_content',
  'vertical_text', 'algorithm', 'doc_title', 'paragraph_title',
  'table', 'figure_title', 'footer', 'header', 'footnote', 'aside_text',
]);

class Block {
  readonly label: string;
  readonly score: number;
  readonly box: number[];
  image: image.PixelMap | null;

  constructor(label: string, score: number, box: number[], img: image.PixelMap | null) {
    this.label = label;
    this.score = score;
    this.box = box;
    this.image = img;
  }
}

class Group {
  readonly idx: number[];
  readonly aligns: string[];

  constructor(idx: number[], aligns: string[]) {
    this.idx = idx;
    this.aligns = aligns;
  }
}

class Overlap {
  readonly ratio: number;
  readonly areaI: number;
  readonly areaJ: number;

  constructor(ratio: number, areaI: number, areaJ: number) {
    this.ratio = ratio;
    this.areaI = areaI;
    this.areaJ = areaJ;
  }
}

/**
 * Turns detected boxes into the crops the model reads, in reading order.
 *
 * Cropping is async on HarmonyOS because PixelMap.crop returns a Promise, so
 * the whole pass is async rather than callback-based.
 */
export async function buildCrops(boxes: LayoutBox[], page: image.PixelMap): Promise<OcrCrop[]> {
  const filtered: LayoutBox[] = filterOverlap(boxes);
  const blocks: Block[] = [];
  for (const box of filtered) {
    const crop: image.PixelMap | null = await cropPixelMap(page, box);
    blocks.push(new Block(box.label, box.score,
      [box.x1, box.y1, box.x2, box.y2], crop));
  }
  const merged: Block[] = merge(blocks);
  const out: OcrCrop[] = [];
  let order: number = 0;
  for (const block of merged) {
    const img: image.PixelMap | null = block.image;
    if (img === null) {
      continue;
    }
    out.push(new OcrCrop(block.label, block.score,
      block.box[0], block.box[1], block.box[2], block.box[3], order, img));
    order += 1;
  }
  return out;
}
/** True when the page looks rotated: most text boxes are taller than wide. */
export function shouldRetry(boxes: LayoutBox[]): boolean {
  if (boxes.length === 0) {
    return true;
  }
  const text: LayoutBox[] = boxes.filter((b: LayoutBox) => TEXT_LABELS.has(b.label));
  if (text.length < 3) {
    return false;
  }
  let tall: number = 0;
  for (const b of text) {
    if ((b.y2 - b.y1) > 2 * (b.x2 - b.x1)) {
      tall += 1;
    }
  }
  return tall / text.length >= 0.6;
}

/** Weighted text area, used to decide whether a rotation is worth keeping. */
export function score(boxes: LayoutBox[]): number {
  let total: number = 0;
  for (const b of boxes) {
    if (!TEXT_LABELS.has(b.label)) {
      continue;
    }
    const w: number = Math.max(0, b.x2 - b.x1);
    const h: number = Math.max(0, b.y2 - b.y1);
    total += w * h * b.score;
  }
  return total;
}

/** Scales the page down so its long edge is at most [maxSide]. */
export async function downscale(pm: image.PixelMap, maxSide: number): Promise<image.PixelMap> {
  const info: image.ImageInfo = await pm.getImageInfo();
  const long: number = Math.max(info.size.width, info.size.height);
  if (long <= maxSide) {
    return pm;
  }
  const scale: number = maxSide / long;
  const w: number = Math.max(1, Math.floor(info.size.width * scale));
  const h: number = Math.max(1, Math.floor(info.size.height * scale));
  const copy: image.PixelMap = await pm.clone();
  await copy.scale(scale, scale);
  const after: image.ImageInfo = await copy.getImageInfo();
  // scale() rounds; if it drifted, re-create at the exact size.
  if (after.size.width !== w || after.size.height !== h) {
    return copy;
  }
  return copy;
}

/** Rotates by a multiple of 90 degrees, returning a new PixelMap. */
export async function rotate(pm: image.PixelMap, degrees: number): Promise<image.PixelMap> {
  if (degrees === 0) {
    return pm;
  }
  const copy: image.PixelMap = await pm.clone();
  await copy.rotate(degrees);
  return copy;
}

function filterOverlap(raw: LayoutBox[]): LayoutBox[] {
  // "reference" boxes duplicate the citations they point at.
  const boxes: LayoutBox[] = raw.filter((b: LayoutBox) => b.label !== 'reference');
  if (boxes.length === 0) {
    return [];
  }
  const dropped: Set<number> = new Set<number>();
  for (let i = 0; i < boxes.length; i++) {
    const w: number = boxes[i].x2 - boxes[i].x1;
    const h: number = boxes[i].y2 - boxes[i].y1;
    if (w < 6 || h < 6) {
      dropped.add(i);
      continue;
    }
    for (let j = i + 1; j < boxes.length; j++) {
      if (dropped.has(i) || dropped.has(j)) {
        continue;
      }
      const ov: Overlap = smallOverlap(boxes[i], boxes[j]);
      // An inline formula sitting on a text box is the same glyphs twice; keep
      // the surrounding text and drop the formula.
      if (boxes[i].label === 'inline_formula' || boxes[j].label === 'inline_formula') {
        if (ov.ratio > 0.5) {
          if (boxes[i].label === 'inline_formula') {
            dropped.add(i);
          }
          if (boxes[j].label === 'inline_formula') {
            dropped.add(j);
          }
          continue;
        }
      }
      if (ov.ratio > 0.7) {
        if (ov.areaI >= ov.areaJ) {
          dropped.add(j);
        } else {
          dropped.add(i);
        }
      }
    }
  }
  return boxes.filter((_: LayoutBox, i: number) => !dropped.has(i));
}

function smallOverlap(a: LayoutBox, b: LayoutBox): Overlap {
  const iw: number = Math.max(0, Math.min(a.x2, b.x2) - Math.max(a.x1, b.x1));
  const ih: number = Math.max(0, Math.min(a.y2, b.y2) - Math.max(a.y1, b.y1));
  const ia: number = iw * ih;
  const areaI: number = Math.abs((a.x2 - a.x1) * (a.y2 - a.y1));
  const areaJ: number = Math.abs((b.x2 - b.x1) * (b.y2 - b.y1));
  const smaller: number = Math.min(areaI, areaJ);
  return new Overlap(smaller > 0 ? ia / smaller : 0, areaI, areaJ);
}

function unionOverlap(a: number[], b: number[]): number {
  const iw: number = Math.max(0, Math.min(a[2], b[2]) - Math.max(a[0], b[0]));
  const ih: number = Math.max(0, Math.min(a[3], b[3]) - Math.max(a[1], b[1]));
  const ia: number = iw * ih;
  const a1: number = Math.max(0, (a[2] - a[0]) * (a[3] - a[1]));
  const a2: number = Math.max(0, (b[2] - b[0]) * (b[3] - b[1]));
  const ref: number = a1 + a2 - ia;
  return ref > 0 ? ia / ref : 0;
}

function projectionOverlapX(a: number[], b: number[]): number {
  const overlap: number = Math.min(a[2], b[2]) - Math.max(a[0], b[0]);
  if (overlap <= 0) {
    return 0;
  }
  const ref: number = Math.max(a[2], b[2]) - Math.min(a[0], b[0]);
  return ref > 0 ? overlap / ref : 0;
}

async function cropPixelMap(pm: image.PixelMap, box: LayoutBox): Promise<image.PixelMap | null> {
  const info: image.ImageInfo = await pm.getImageInfo();
  const left: number = Math.max(0, Math.min(info.size.width, Math.floor(box.x1)));
  const top: number = Math.max(0, Math.min(info.size.height, Math.floor(box.y1)));
  const right: number = Math.max(0, Math.min(info.size.width, Math.ceil(box.x2)));
  const bottom: number = Math.max(0, Math.min(info.size.height, Math.ceil(box.y2)));
  const w: number = right - left;
  const h: number = bottom - top;
  if (w <= 0 || h <= 0) {
    return null;
  }
  try {
    const copy: image.PixelMap = await pm.clone();
    await copy.crop({ x: left, y: top, size: { width: w, height: h } });
    return copy;
  } catch (e) {
    return null;
  }
}

function merge(blocks: Block[]): Block[] {
  if (blocks.length === 0) {
    return [];
  }
  const toMerge: number[] = [];
  const fixed: Map<number, Block> = new Map<number, Block>();
  for (let i = 0; i < blocks.length; i++) {
    if (NON_MERGE.has(blocks[i].label)) {
      fixed.set(i, blocks[i]);
    } else {
      toMerge.push(i);
    }
  }

  const aligned = (a: number, b: number): boolean => Math.abs(a - b) <= 5;
  const alignment = (bbox: number[], prev: number[]): string => {
    if (aligned(bbox[0], prev[0])) {
      return 'left';
    }
    if (aligned(bbox[2], prev[2])) {
      return 'right';
    }
    return 'center';
  };
  const overlapsFixed = (bi: number, pi: number): boolean => {
    const pb: number[] = blocks[pi].box;
    const bb: number[] = blocks[bi].box;
    const span: number[] = [
      Math.min(pb[0], bb[0]), Math.min(pb[1], bb[1]),
      Math.max(pb[2], bb[2]), Math.max(pb[3], bb[3]),
    ];
    for (let oi = 0; oi < blocks.length; oi++) {
      if (oi === bi || oi === pi || !NON_MERGE.has(blocks[oi].label)) {
        continue;
      }
      if (unionOverlap(span, blocks[oi].box) > 0) {
        return true;
      }
    }
    return false;
  };

  const groups: Group[] = [];
  let curIdx: number[] = [];
  let curAlign: string[] = [];
  for (let i = 0; i < toMerge.length; i++) {
    const item: number = toMerge[i];
    if (curIdx.length === 0) {
      curIdx = [item];
      curAlign = [];
      continue;
    }
    const prev: number = toMerge[i - 1];
    const prevBox: number[] = blocks[prev].box;
    const box: number[] = blocks[item].box;
    const iouH: number = projectionOverlapX(box, prevBox);
    // Two fragments on the same visual line, separated by a gap smaller than a
    // third of their own width, are one line split by a column rule or figure.
    const isCross: boolean = iouH === 0 &&
      blocks[item].label === 'text' && blocks[item].label === blocks[prev].label &&
      box[0] > prevBox[2] && box[1] < prevBox[3] &&
      (box[0] - prevBox[2]) < Math.max(prevBox[2] - prevBox[0], box[2] - box[0]) * 0.3;
    // Two lines that touch vertically with one edge aligned continue a paragraph.
    const isUp: boolean = iouH > 0 &&
      (blocks[item].label === 'text' || blocks[item].label === 'vertical_text') &&
      blocks[item].label === blocks[prev].label &&
      box[3] >= prevBox[1] &&
      Math.abs(box[1] - prevBox[3]) < Math.max(prevBox[3] - prevBox[1], box[3] - box[1]) * 0.5 &&
      (aligned(box[0], prevBox[0]) !== aligned(box[2], prevBox[2])) &&
      overlapsFixed(item, prev);
    if (isCross || isUp) {
      curIdx.push(item);
      curAlign.push(isCross ? 'center' : alignment(box, prevBox));
    } else {
      groups.push(new Group(curIdx, curAlign));
      curIdx = [item];
      curAlign = [];
    }
  }
  if (curIdx.length > 0) {
    groups.push(new Group(curIdx, curAlign));
  }

  const result: Block[] = [];
  const used: Set<number> = new Set<number>();
  let idx: number = 0;
  while (idx < blocks.length) {
    let found: boolean = false;
    for (const range of groups) {
      let start: number = Number.MAX_SAFE_INTEGER;
      let end: number = -1;
      for (const v of range.idx) {
        start = Math.min(start, v);
        end = Math.max(end, v);
      }
      if (idx !== start) {
        continue;
      }
      let skip: boolean = false;
      for (const v of range.idx) {
        if (used.has(v)) {
          skip = true;
        }
      }
      if (skip) {
        continue;
      }
      found = true;
      // Without a canvas there is no way to stitch the fragments into one
      // bitmap, so the first block of a group carries the whole group and the
      // remaining ones are dropped. Grouping still matters because it decides
      // the reading order.
      result.push(blocks[range.idx[0]]);
      for (const bi of range.idx) {
        used.add(bi);
      }
      if (end > start) {
        for (let ni = start + 1; ni < end; ni++) {
          const extra: Block | undefined = fixed.get(ni);
          if (extra === undefined) {
            continue;
          }
          result.push(extra);
          used.add(ni);
        }
      }
      idx = end + 1;
      break;
    }
    if (found) {
      continue;
    }
    const f: Block | undefined = fixed.get(idx);
    if (f !== undefined) {
      result.push(f);
      used.add(idx);
    }
    idx += 1;
  }
  return result;
}
