/**
 * Per-label prompts for the OCR pipeline.
 *
 * Copied verbatim from the Android and iOS clients. The wording is part of what
 * the model was trained on, so it must not be rephrased; only the surrounding
 * types are ArkTS.
 */

export class OcrElementPrompt {
  readonly prompt: string;
  readonly maxTokens: number;
  readonly outputFormat: string;
  readonly skip: boolean;

  constructor(prompt: string, maxTokens: number, outputFormat: string, skip: boolean = false) {
    this.prompt = prompt;
    this.maxTokens = maxTokens;
    this.outputFormat = outputFormat;
    this.skip = skip;
  }
}

export const DEFAULT_PROMPT: OcrElementPrompt = new OcrElementPrompt('Text Recognition:', 8192, 'text');

const ELEMENT_PROMPTS: Map<string, OcrElementPrompt> = new Map<string, OcrElementPrompt>([
  ['text', new OcrElementPrompt('Text Recognition:', 4096, 'text')],
  ['content', new OcrElementPrompt('Text Recognition:', 4096, 'text')],
  ['abstract', new OcrElementPrompt('Text Recognition:', 4096, 'text')],
  ['reference', new OcrElementPrompt('Text Recognition:', 2048, 'text')],
  ['reference_content', new OcrElementPrompt('Text Recognition:', 2048, 'text')],
  ['vertical_text', new OcrElementPrompt('Text Recognition:', 2048, 'text')],
  ['vision_footnote', new OcrElementPrompt('Text Recognition:', 1024, 'text')],
  ['algorithm', new OcrElementPrompt('Text Recognition:', 4096, 'text')],
  ['doc_title', new OcrElementPrompt('Text Recognition:', 512, 'text')],
  ['paragraph_title', new OcrElementPrompt('Text Recognition:', 512, 'text')],
  ['figure_title', new OcrElementPrompt('Text Recognition:', 512, 'text')],
  ['table', new OcrElementPrompt('Table Recognition:', 8192, 'html')],
  ['display_formula', new OcrElementPrompt('Formula Recognition:', 2048, 'latex')],
  ['inline_formula', new OcrElementPrompt('Text Recognition:', 1024, 'latex')],
  ['formula_number', new OcrElementPrompt('Text Recognition:', 256, 'text')],
  ['header', new OcrElementPrompt('Text Recognition:', 512, 'text')],
  ['footer', new OcrElementPrompt('Text Recognition:', 512, 'text')],
  ['footnote', new OcrElementPrompt('Text Recognition:', 1024, 'text')],
  ['aside_text', new OcrElementPrompt('Text Recognition:', 1024, 'text')],
  ['number', new OcrElementPrompt('Text Recognition:', 256, 'text')],
  ['image', new OcrElementPrompt('', 0, '', true)],
  ['header_image', new OcrElementPrompt('', 0, '', true)],
  ['footer_image', new OcrElementPrompt('', 0, '', true)],
  ['chart', new OcrElementPrompt('Chart to Table:', 4096, 'html')],
  ['seal', new OcrElementPrompt('Seal Recognition:', 256, 'text')],
]);

/** Model output index to label name. Shared with LayoutDetector. */
export const LABEL_ID_TO_NAME: string[] = [
  'abstract', 'algorithm', 'aside_text', 'chart', 'content', 'display_formula',
  'doc_title', 'figure_title', 'footer', 'footer_image', 'footnote',
  'formula_number', 'header', 'header_image', 'image', 'inline_formula',
  'number', 'paragraph_title', 'reference', 'reference_content', 'seal',
  'table', 'text', 'vertical_text', 'vision_footnote',
];

export const IGNORE_LABELS: Set<string> = new Set<string>([
  'number', 'footnote', 'header', 'footer', 'aside_text',
]);

export const TITLE_FORMAT: Map<string, string> = new Map<string, string>([
  ['doc_title', '# {content}'],
  ['paragraph_title', '## {content}'],
  ['figure_title', '*{content}*'],
]);

export const FORMULA_FORMAT: Map<string, string> = new Map<string, string>([
  ['display_formula', '$$\n{content}\n$$'],
  ['inline_formula', '${content}$'],
]);

export function promptFor(label: string): OcrElementPrompt {
  const found: OcrElementPrompt | undefined = ELEMENT_PROMPTS.get(label);
  return found ?? DEFAULT_PROMPT;
}
