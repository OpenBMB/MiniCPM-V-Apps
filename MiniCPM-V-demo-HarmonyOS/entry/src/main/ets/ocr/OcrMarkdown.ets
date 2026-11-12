/**
 * Crop cleanup and markdown assembly.
 *
 * A direct port of the Android client, which follows iOS OcrMarkdownUtils: the
 * same repetition guards, the OTSL table-to-HTML conversion and the LaTeX
 * repair chain. These run on model output, so the rules have to stay identical
 * across platforms or the same page renders differently on each.
 */

import { IGNORE_LABELS, TITLE_FORMAT, FORMULA_FORMAT } from './OcrPrompts';

export class Block {
  readonly label: string;
  readonly content: string;
  readonly order: number;
  readonly inlineFormulaMixed: boolean;

  constructor(label: string, content: string, order: number, inlineFormulaMixed: boolean = false) {
    this.label = label;
    this.content = content;
    this.order = order;
    this.inlineFormulaMixed = inlineFormulaMixed;
  }

  withContent(content: string): Block {
    return new Block(this.label, content, this.order, this.inlineFormulaMixed);
  }
}

const TEXT_BLOCK_LABELS: Set<string> = new Set<string>([
  'text', 'content', 'abstract', 'reference', 'reference_content',
  'vertical_text', 'vision_footnote', 'algorithm', 'header', 'footer',
  'footnote', 'aside_text',
]);

const FAILURE_MARKERS: string[] = [
  'failed', 'cuda out of memory', 'outofmemoryerror', 'enginecore', 'traceback',
];

const COMMENT_RE: RegExp = /^\s*<!--\s*([\s\S]*?)\s*-->\s*$/;
const INLINE_MATH_RE: RegExp = /(?<!\\)\$(?!\$)(?:[^$\n]|\\.)+?(?<!\\)\$(?!\$)|\\\([^\n]*?\\\)/g;

/** Drops an engine failure message that arrived instead of content. */
export function classifyEngineText(raw: string): string {
  const match: RegExpMatchArray | null = raw.match(COMMENT_RE);
  if (match === null) {
    return raw;
  }
  const msg: string = (match[1] ?? '').trim().toLowerCase();
  for (const marker of FAILURE_MARKERS) {
    if (msg.includes(marker)) {
      return '';
    }
  }
  return raw;
}

/** True when the block is prose with formulas mixed in, not a formula alone. */
export function hasMixedInlineFormula(content: string): boolean {
  const stripped: string = content.trim();
  if (stripped.length === 0) {
    return false;
  }
  const all: RegExpMatchArray | null = stripped.match(new RegExp('^(?:' + INLINE_MATH_RE.source + ')$'));
  if (all !== null) {
    return false;
  }
  const without: string = stripped.replace(new RegExp(INLINE_MATH_RE.source, 'g'), '');
  return without.trim().length > 0;
}

export function postprocess(raw: string, outputFormat: string, label: string): string {
  let content: string = truncateRepetitive(raw.trim(), label === 'table' ? 5000 : 50);
  if (outputFormat === 'latex') {
    if (label === 'display_formula') {
      content = repairDisplayDollars(content);
    }
    content = content.replace(/\\\[\s*\\\]|\\\(\s*\\\)/g, ' ');
    const wraps: string[][] = [['$$', '$$'], ['$', '$'], ['\\(', '\\)'], ['\\[', '\\]']];
    for (const w of wraps) {
      const open: string = w[0];
      const close: string = w[1];
      if (content.startsWith(open) && content.endsWith(close) &&
          content.length >= open.length + close.length) {
        content = content.substring(open.length, content.length - close.length).trim();
      }
    }
    if (label === 'display_formula') {
      // Plain string replace, not regex: a pattern replacement string would
      // read `$$` as a group reference and collapse it to one `$`.
      content = content.replace(/\\]\s*\\\[/g, '$$   $$');
      content = content.replace(/\\\[/g, '').replace(/\\\]/g, '');
    }
    if (label === 'display_formula' || label === 'inline_formula') {
      content = repairLatex(content, label);
    }
  } else if (outputFormat === 'html') {
    if (content.startsWith('```html')) {
      content = content.substring(7);
    }
    if (content.startsWith('```')) {
      content = content.substring(3);
    }
    if (content.endsWith('```')) {
      content = content.substring(0, content.length - 3);
    }
    content = content.trim();
    if (label === 'table') {
      const openCount: number = countOccurrences(content, '<table');
      const closeCount: number = countOccurrences(content, '</table>');
      for (let i = 0; i < openCount - closeCount; i++) {
        content += '</table>';
      }
    }
  }
  return content;
}

export function normalize(blocks: Block[]): Block[] {
  const seen: Set<string> = new Set<string>();
  const out: Block[] = [];
  const sorted: Block[] = blocks.slice().sort((a: Block, b: Block) => a.order - b.order);
  for (const block of sorted) {
    let content: string = truncateSuffix(block.content.trim());
    if (block.label !== 'display_formula') {
      content = content.replace(/\\\((.+?)\\\)/g, (_m: string, g1: string) => '$' + g1.trim() + '$');
    } else {
      content = content.replace(/\\]\s*\\\[/g, '$$   $$');
      content = content.replace(/\\\[/g, '').replace(/\\\]/g, '');
    }
    content = content.replace(/[ \t]+/g, ' ');
    content = content.replace(/\n{3,}/g, '\n\n');
    if (block.label === 'table' || block.label === 'chart') {
      const html: string = otslToHtml(content);
      if (html.length > 0) {
        content = html;
      }
    }
    if (TEXT_BLOCK_LABELS.has(block.label)) {
      content = splitText(content, false);
    } else if (block.label === 'inline_formula' && block.inlineFormulaMixed) {
      content = splitText(content, true);
    }
    const key: string = `${block.order}|${block.label}|${content}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    out.push(block.withContent(content));
  }
  return out;
}

export function assemble(blocks: Block[]): string {
  const imageLabels: Set<string> = new Set<string>(['image', 'header_image', 'footer_image']);
  const parts: string[] = [];
  const sorted: Block[] = blocks.slice().sort((a: Block, b: Block) => a.order - b.order);
  for (const block of sorted) {
    const label: string = block.label;
    const content: string = block.content;
    if (IGNORE_LABELS.has(label)) {
      continue;
    }
    if (content.length === 0 && !imageLabels.has(label) && label !== 'chart' && label !== 'seal') {
      continue;
    }
    const title: string | undefined = TITLE_FORMAT.get(label);
    const formula: string | undefined = FORMULA_FORMAT.get(label);
    if (title !== undefined) {
      parts.push(title.replace('{content}', content));
    } else if (formula !== undefined) {
      if (label === 'inline_formula' && block.inlineFormulaMixed) {
        parts.push(content);
      } else {
        parts.push(formula.replace('{content}', content));
      }
    } else if (imageLabels.has(label)) {
      parts.push('![image]()');
    } else if (label === 'chart' || label === 'seal') {
      parts.push(content.length === 0 ? '![image]()' : content);
    } else {
      parts.push(content);
    }
  }
  return parts.join('\n\n');
}

function truncateRepetitive(content: string, minCount: number): string {
  if (content.length === 0 || content.length < minCount) {
    return content;
  }
  const stripped: string = content.trim();
  if (stripped.length === 0) {
    return content;
  }
  // A model that gets stuck repeats one tail unit; keep only the run before it.
  if (!stripped.includes('\n') && stripped.length > 100) {
    const n: number = stripped.length;
    const upper: number = Math.floor(n / 5);
    if (upper >= 8) {
      for (let unitLen = 8; unitLen <= upper; unitLen++) {
        const unit: string = stripped.substring(n - unitLen);
        let count: number = 0;
        let pos: number = n - unitLen;
        while (pos >= 0 && stripped.substring(pos, pos + unitLen) === unit) {
          count += 1;
          pos -= unitLen;
        }
        if (count >= 5 && unit.length * count > n * 0.5) {
          return stripped.substring(0, n - count * unitLen);
        }
      }
    }
  }
  return content;
}

function truncateSuffix(text: string): string {
  const words: string[] = [];
  const pos: number[] = [];
  const re: RegExp = /\S+/g;
  let m: RegExpExecArray | null = re.exec(text);
  while (m !== null) {
    words.push(m[0].toLowerCase());
    pos.push(m.index);
    m = re.exec(text);
  }
  if (words.length < 18) {
    return text;
  }
  let earliest: number = text.length;
  const maxWindow: number = Math.min(64, Math.floor(words.length / 3));
  if (maxWindow >= 6) {
    for (let window = 6; window <= maxWindow; window++) {
      const limit: number = words.length - window * 3 + 1;
      if (limit <= 0) {
        continue;
      }
      for (let start = 0; start < limit; start++) {
        let same: boolean = true;
        for (let k = 0; k < window && same; k++) {
          const w: string = words[start + k];
          if (words[start + window + k] !== w || words[start + window * 2 + k] !== w) {
            same = false;
          }
        }
        if (same) {
          earliest = Math.min(earliest, pos[start]);
          break;
        }
      }
    }
  }
  return earliest < text.length ? text.substring(0, earliest).replace(/\s+$/, '') : text;
}

function splitText(content: string, protectInlineMath: boolean): string {
  const lines: string[] = content.split('\n');
  const output: string[] = [];
  for (const line of lines) {
    const stripped: string = line.trim();
    if (stripped.length === 0) {
      continue;
    }
    if (output.length > 0 && output[output.length - 1].trim().length > 0) {
      output.push('');
    }
    output.push(protectInlineMath ? line : stripped);
    output.push('');
  }
  let joined: string = output.join('\n').replace(/\n{3,}/g, '\n\n');
  joined = joined.replace(/^\n+/, '').replace(/\n+$/, '');
  return joined;
}

function repairDisplayDollars(markdown: string): string {
  const tokens: string[] = [];
  let rest: string = markdown;
  while (true) {
    const at: number = rest.indexOf('$$');
    if (at < 0) {
      break;
    }
    tokens.push(rest.substring(0, at));
    tokens.push('$$');
    rest = rest.substring(at + 2);
  }
  tokens.push(rest);

  const output: string[] = [];
  let inDisplay: boolean = false;
  for (let index = 0; index < tokens.length; index++) {
    const token: string = tokens[index];
    if (token !== '$$') {
      output.push(token);
      continue;
    }
    const nextSegment: string = index + 1 < tokens.length ? tokens[index + 1] : '';
    const nextIsDelimiter: boolean = index + 2 < tokens.length && tokens[index + 2] === '$$';
    const hasLater: boolean = tokens.slice(index + 2).includes('$$');
    if (!inDisplay) {
      if ((nextSegment.trim().length === 0 && nextIsDelimiter) || !hasLater) {
        continue;
      }
      output.push(token);
      inDisplay = true;
    } else {
      output.push(token);
      inDisplay = false;
    }
  }
  if (inDisplay && output.length > 0) {
    output.pop();
  }
  return output.join('');
}

// ------------------------------------------------------------------ OTSL

const NL: string = '<nl>';
const FCEL: string = '<fcel>';
const ECEL: string = '<ecel>';
const LCEL: string = '<lcel>';
const UCEL: string = '<ucel>';
const XCEL: string = '<xcel>';

const OTSL_TAGS: Set<string> = new Set<string>([NL, FCEL, ECEL, LCEL, UCEL, XCEL]);
const OTSL_TOKEN_RE: RegExp = /(<nl>|<fcel>|<ecel>|<lcel>|<ucel>|<xcel>)/g;
const CELL_TAGS: Set<string> = new Set<string>([FCEL, ECEL, LCEL, UCEL, XCEL]);
const SPAN_TAGS: Set<string> = new Set<string>([LCEL, UCEL, XCEL]);

class OtslCell {
  readonly text: string;
  readonly row: number;
  readonly col: number;
  readonly rowSpan: number;
  readonly colSpan: number;

  constructor(text: string, row: number, col: number, rowSpan: number, colSpan: number) {
    this.text = text;
    this.row = row;
    this.col = col;
    this.rowSpan = rowSpan;
    this.colSpan = colSpan;
  }
}

/** Converts OTSL markup to an HTML table, or '' when there is none. */
export function otslToHtml(otsl: string): string {
  if (!otsl.includes('<fcel>') && !otsl.includes('<nl>')) {
    return '';
  }
  const padded: string = padOtsl(otsl.trim());
  const extracted: string[][] = extractOtsl(padded);
  const tokens: string[] = extracted[0];
  const mixed: string[] = extracted[1];
  const parsed: Object[] = parseOtsl(mixed, tokens);
  const cells: OtslCell[] = parsed[0] as OtslCell[];
  const rows: string[][] = parsed[1] as string[][];
  if (cells.length === 0) {
    return '';
  }
  let cols: number = 0;
  for (const row of rows) {
    cols = Math.max(cols, row.length);
  }
  return exportOtsl(cells, rows.length, cols);
}

function padOtsl(otsl: string): string {
  if (!otsl.includes(NL)) {
    return otsl + NL;
  }
  const lineRE: RegExp = /(?:<fcel>|<ecel>|<nl>|<lcel>|<ucel>|<xcel>).*?(?=(?:<fcel>|<ecel>|<nl>|<lcel>|<ucel>|<xcel>)|$)/g;
  const rawRows: string[][] = [];
  const sizes: number[] = [];
  const minLens: number[] = [];
  for (const line of otsl.split(NL)) {
    if (line.length === 0) {
      continue;
    }
    const raw: string[] = [];
    const matches: RegExpMatchArray | null = line.match(lineRE);
    if (matches !== null) {
      for (const v of matches) {
        raw.push(v);
      }
    }
    let minLen: number = 0;
    for (let i = 0; i < raw.length; i++) {
      if (raw[i].startsWith(FCEL)) {
        minLen = i + 1;
      }
    }
    rawRows.push(raw);
    sizes.push(raw.length);
    minLens.push(minLen);
  }
  if (rawRows.length === 0) {
    return NL;
  }
  let globalMin: number = 0;
  let maxTotal: number = 0;
  for (let i = 0; i < rawRows.length; i++) {
    globalMin = Math.max(globalMin, minLens[i]);
    maxTotal = Math.max(maxTotal, sizes[i]);
  }
  // Pad every row to one common width, choosing the width whose padding is
  // cheapest overall rather than simply the widest row.
  let width: number = Math.max(globalMin, maxTotal);
  let best: number = Number.MAX_SAFE_INTEGER;
  for (let w = globalMin; w <= Math.max(globalMin, maxTotal); w++) {
    let cost: number = 0;
    for (const s of sizes) {
      cost += Math.abs(s - w);
    }
    if (cost < best) {
      best = cost;
      width = w;
    }
  }
  const outRows: string[] = [];
  for (let i = 0; i < rawRows.length; i++) {
    let cells: string[] = rawRows[i];
    if (cells.length > width) {
      cells = cells.slice(0, width);
    } else {
      const pad: string[] = new Array<string>(width - cells.length).fill(ECEL);
      cells = cells.concat(pad);
    }
    outRows.push(cells.join(''));
  }
  return outRows.join(NL) + NL;
}

function extractOtsl(s: string): string[][] {
  const tokens: string[] = [];
  const parts: string[] = [];
  let cursor: number = 0;
  const re: RegExp = /(<nl>|<fcel>|<ecel>|<lcel>|<ucel>|<xcel>)/g;
  let m: RegExpExecArray | null = re.exec(s);
  while (m !== null) {
    if (m.index > cursor) {
      parts.push(s.substring(cursor, m.index));
    }
    parts.push(m[0]);
    tokens.push(m[0]);
    cursor = m.index + m[0].length;
    m = re.exec(s);
  }
  if (cursor < s.length) {
    parts.push(s.substring(cursor));
  }
  return [tokens, parts.filter((p: string) => p.trim().length > 0)];
}

function rowsOfOtsl(tokens: string[]): string[][] {
  const rows: string[][] = [];
  let cur: string[] = [];
  let open: boolean = false;
  for (const token of tokens) {
    if (token === NL) {
      if (open) {
        rows.push(cur);
        cur = [];
        open = false;
      }
    } else {
      cur.push(token);
      open = true;
    }
  }
  if (open) {
    rows.push(cur);
  }
  return rows;
}

function parseOtsl(input: string[], tokens: string[]): Object[] {
  const splitRows: string[][] = rowsOfOtsl(tokens);
  let texts: string[] = input;
  if (splitRows.length > 0) {
    let maxCols: number = 0;
    for (const row of splitRows) {
      maxCols = Math.max(maxCols, row.length);
    }
    for (const row of splitRows) {
      while (row.length < maxCols) {
        row.push(ECEL);
      }
    }
    const rebuilt: string[] = [];
    let textIdx: number = 0;
    for (const row of splitRows) {
      for (const token of row) {
        rebuilt.push(token);
        if (textIdx < texts.length && texts[textIdx] === token) {
          textIdx += 1;
          if (textIdx < texts.length && !OTSL_TAGS.has(texts[textIdx])) {
            rebuilt.push(texts[textIdx]);
            textIdx += 1;
          }
        }
      }
      rebuilt.push(NL);
      if (textIdx < texts.length && texts[textIdx] === NL) {
        textIdx += 1;
      }
    }
    texts = rebuilt;
  }

  const cells: OtslCell[] = [];
  let rIdx: number = 0;
  let cIdx: number = 0;
  for (let i = 0; i < texts.length; i++) {
    const text: string = texts[i];
    if (text === FCEL || text === ECEL) {
      let rowSpan: number = 1;
      let colSpan: number = 1;
      let rightOffset: number = 1;
      let cellText: string = '';
      if (text !== ECEL) {
        cellText = i + 1 < texts.length ? texts[i + 1] : '';
        rightOffset = 2;
      }
      const nextRight: string = i + rightOffset < texts.length ? texts[i + rightOffset] : '';
      const nextBottom: string = (rIdx + 1 < splitRows.length && cIdx < splitRows[rIdx + 1].length)
        ? splitRows[rIdx + 1][cIdx] : '';

      if (nextRight === LCEL || nextRight === XCEL) {
        let span: number = 0;
        let ci: number = cIdx + 1;
        while (ci < splitRows[rIdx].length && SPAN_TAGS.has(splitRows[rIdx][ci])) {
          ci += 1;
          span += 1;
        }
        colSpan += span;
      }
      if (nextBottom === UCEL || nextBottom === XCEL) {
        let span: number = 0;
        let ri: number = rIdx + 1;
        while (ri < splitRows.length && cIdx < splitRows[ri].length &&
               (splitRows[ri][cIdx] === UCEL || splitRows[ri][cIdx] === XCEL)) {
          ri += 1;
          span += 1;
        }
        rowSpan += span;
      }
      cells.push(new OtslCell(cellText.trim(), rIdx, cIdx, rowSpan, colSpan));
    }
    if (CELL_TAGS.has(text)) {
      cIdx += 1;
    }
    if (text === NL) {
      rIdx += 1;
      cIdx = 0;
    }
  }
  return [cells, splitRows];
}

function exportOtsl(cells: OtslCell[], rows: number, cols: number): string {
  if (cells.length === 0 || rows === 0 || cols === 0) {
    return '';
  }
  const grid: OtslCell[][] = [];
  for (let r = 0; r < rows; r++) {
    const row: OtslCell[] = [];
    for (let c = 0; c < cols; c++) {
      row.push(new OtslCell('', r, c, 1, 1));
    }
    grid.push(row);
  }
  for (const cell of cells) {
    const rEnd: number = Math.min(cell.row + cell.rowSpan, rows);
    const cEnd: number = Math.min(cell.col + cell.colSpan, cols);
    for (let i = cell.row; i < rEnd; i++) {
      for (let j = cell.col; j < cEnd; j++) {
        grid[i][j] = cell;
      }
    }
  }
  const body: string[] = [];
  for (let i = 0; i < rows; i++) {
    body.push('<tr>');
    for (let j = 0; j < cols; j++) {
      const cell: OtslCell = grid[i][j];
      // A spanned cell is drawn once, at its anchor; the rest are covered.
      if (cell.row !== i || cell.col !== j) {
        continue;
      }
      let span: string = '';
      if (cell.rowSpan > 1) {
        span += ` rowspan="${cell.rowSpan}"`;
      }
      if (cell.colSpan > 1) {
        span += ` colspan="${cell.colSpan}"`;
      }
      body.push(`<td${span}>${htmlEscape(cell.text.trim())}</td>`);
    }
    body.push('</tr>');
  }
  return `<table>${body.join('')}</table>`;
}

function htmlEscape(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function countOccurrences(haystack: string, needle: string): number {
  let count: number = 0;
  let from: number = 0;
  while (true) {
    const at: number = haystack.indexOf(needle, from);
    if (at < 0) {
      break;
    }
    count += 1;
    from = at + needle.length;
  }
  return count;
}

// ----------------------------------------------------------- LaTeX repair

const ENV_TYPES: string[] = [
  'array', 'matrix', 'pmatrix', 'bmatrix', 'vmatrix',
  'Bmatrix', 'Vmatrix', 'cases', 'aligned', 'gathered', 'align', 'align*',
];

const LEFT_RE: RegExp = /(\\left)(?![a-zA-Z])(\\(?:lceil|rceil|lfloor|rfloor|backslash|uparrow|downarrow|Uparrow|Downarrow|langle|rangle)|\\[{}|.]|[()[\]{}/|.])?/g;
const RIGHT_RE: RegExp = /(\\right)(?![a-zA-Z])(\\(?:lceil|rceil|lfloor|rfloor|backslash|uparrow|downarrow|Uparrow|Downarrow|langle|rangle)|\\[{}|.]|[()[\]{}/|.])?/g;
const LEFT_COUNT_RE: RegExp = /\\left(?![a-zA-Z])/g;
const RIGHT_COUNT_RE: RegExp = /\\right(?![a-zA-Z])/g;
const LEFT_RIGHT_REMOVE_RE: RegExp = /\\left(?![a-zA-Z])\.?|\\right(?![a-zA-Z])\.?/g;

/** Balances braces, `\left`/`\right` pairs and environments. */
export function repairLatex(s: string, label: string): string {
  if (s.trim().length === 0) {
    return s;
  }
  let out: string = fixUnbalancedBraces(s);
  out = fixLeftRight(out, label === 'display_formula' || label.length === 0);
  out = fixEnvironments(out);
  out = out.replace(/(\\end\{array\}\s*\\right\.\s*){2,}/g, '\\end{array} \\right.');
  out = out.replace(/(\\\]\s*){2,}/g, '\\]');
  return out.replace(/\\+$/, '').trim();
}

function fixUnbalancedBraces(s: string): string {
  const chars: string[] = s.split('');
  const stack: number[] = [];
  const unmatched: Set<number> = new Set<number>();
  for (let i = 0; i < chars.length; i++) {
    const ch: string = chars[i];
    if (ch !== '{' && ch !== '}') {
      continue;
    }
    if (isEscaped(chars, i)) {
      continue;
    }
    if (ch === '{') {
      stack.push(i);
    } else if (stack.length === 0) {
      unmatched.add(i);
    } else {
      stack.pop();
    }
  }
  for (const i of stack) {
    unmatched.add(i);
  }
  if (unmatched.size === 0) {
    return s;
  }
  return chars.filter((_: string, i: number) => !unmatched.has(i)).join('');
}

function isEscaped(chars: string[], pos: number): boolean {
  let count: number = 0;
  let j: number = pos - 1;
  while (j >= 0 && chars[j] === '\\') {
    count += 1;
    j -= 1;
  }
  return count % 2 === 1;
}

function fixLeftRight(s: string, fixDelimiter: boolean): string {
  let out: string = s;
  if (fixDelimiter) {
    // A bare `\left(` with no closing delimiter breaks the renderer, so supply
    // an invisible `.` which LaTeX accepts.
    out = out.replace(LEFT_RE, (m: string, g1: string, g2: string) => {
      return (g2 === undefined || g2.length === 0) ? g1 + '.' : m;
    });
    out = out.replace(RIGHT_RE, (m: string, g1: string, g2: string) => {
      return (g2 === undefined || g2.length === 0) ? g1 + '.' : m;
    });
  }
  const left: number = countRegex(out, LEFT_COUNT_RE);
  const right: number = countRegex(out, RIGHT_COUNT_RE);
  return left === right ? out : out.replace(LEFT_RIGHT_REMOVE_RE, '');
}

function fixEnvironments(s: string): string {
  let out: string = s;
  for (const env of ENV_TYPES) {
    const begin: number = countOccurrences(out, `\\begin{${env}}`);
    const end: number = countOccurrences(out, `\\end{${env}}`);
    if (begin === end) {
      continue;
    }
    if (end > begin) {
      const fmt: string = env === 'array' ? '{c}' : '';
      let prefix: string = '';
      for (let i = 0; i < end - begin; i++) {
        prefix += `\\begin{${env}}${fmt} `;
      }
      out = prefix + out;
    } else {
      let suffix: string = '';
      for (let i = 0; i < begin - end; i++) {
        suffix += ` \\end{${env}}`;
      }
      out += suffix;
    }
  }
  return out;
}

function countRegex(s: string, re: RegExp): number {
  const m: RegExpMatchArray | null = s.match(re);
  return m === null ? 0 : m.length;
}
