# MLPerf Mobile v6.0 LLM track

- `cases.jsonl`：133 条纯文本单轮，`image` 为 `null`
  - 1001–1100：Tiny-MMLU（100）
  - 2001–2033：Tiny-IFEval-33（33）
- `cases_short.jsonl`：同 key；Tiny-MMLU 中超过 6000 字符的 12 条改为“preface + 最后一题”的短版，便于 4096 context 设备；其余与 `cases.jsonl` 相同。
- `cases_with_warmup.jsonl`：key=9999 的带图预热 case + 上述 133 条；用于规避纯文本预热的历史 SIGKILL 问题。
- `labels.jsonl`：Tiny-MMLU 的答案/学科，Tiny-IFEval 的 instruction_id_list/kwargs。

## 来源

- Tiny-MMLU：MLPerf Mobile v6.0 `tinymmlu.tfrecord`，100 条，46 学科，答案 A-D；原始 prompt 是多示例拼接，App 侧按 2048 token 截断是 MLPerf 官方做法。
- Tiny-IFEval-33：`mobile_open/llm/dataset/ifeval_33.jsonl`，33 条，25 种指令类型（1/2/3 条指令分别 13/9/11 条；MLPerf README 写 13/10/10，实际文件为 13/9/11）。
- 校准集 WikiText-2 不属于本 track。

## 注意

- 这是**性能**数据集；App 目前不计算 MMLU/IFEval accuracy。`labels.jsonl` 只是为后续分析准备。
- 原始 Tiny-MMLU 的 FewShot prompt 可能包含最多约 14k 字符；`cases_short.jsonl` 是给 4096 context 的保守版本，但它改变了 MLPerf 的 few-shot 口径（变成零样本最后一题），跨版本比较时不要混用。
- IFEval 的 33 条 prompt 都是单轮；如果需要更大样本，可用 `ref_mlperf/mobile_open/llm/instruction_following_eval/data/input_data.jsonl` 的全量 540 条，但要另做筛选。
