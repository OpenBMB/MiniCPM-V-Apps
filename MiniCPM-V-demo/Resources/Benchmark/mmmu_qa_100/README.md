# MMMU QA 100 —— 单图问答 track

## 数据

- 来源：`MMMU/MMMU` **validation** split（HuggingFace，Apache-2.0）
- 抽样：只保留**恰好一张图**、`question_type=multiple-choice`、答案 A-D、2–4 个选项的题；按 30 个学科每科 3 条，再用固定种子 `20261020` 从剩余题中补 10 条；共 **100** 条。
- 覆盖：30 学科；答案分布 {'C': 22, 'B': 34, 'A': 30, 'D': 14}。
- 图片：原字节保存，未重新编码；总大小约 36.4 MB，单图最小/中位/最大 = 5446 / 48192 / 8931104 bytes。
- `cases.jsonl`：`key` 1–100，`image` 为扁平文件名，`text` 为题干 + 选项 + “Answer with the option letter only.”。
- `labels.jsonl`：`answer`、`subject`、`subfield`、`topic_difficulty`、`img_type`、原始 `source_id` 等。

## 判分

模型输出第一个单独的 A/B/C/D 字母即可与 `labels.jsonl` 的 `answer` 比对；App 目前只测速，不自动判分。

## 限制

- MMMU 是英文、大学/专业难度，不是中文日常 VQA；产品中文能力请另配中文集（如 MMBench-CN/OCRBench 中文）。
- 只选单图题；多图题被排除，因此这不是完整 MMMU 分数，不能对外声称“MMMU xx%”。
- 图片尺寸/字节数差异较大；分析 TTFT 时建议按 image token 或图片字节分组，不要只报一个总均值。
- 许可：数据集卡 Apache-2.0；图片来自原数据集，对外再分发前建议再核对原始来源。
