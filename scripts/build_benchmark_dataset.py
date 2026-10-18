#!/usr/bin/env python3
"""
从 35BA3B_cases.md 解析出批量基准测试的数据集，落到 App 的 bundle 资源目录。

- 图片：从源目录原样拷贝，**不做任何缩放/重编码** —— 分辨率与文件大小本身
  就是影响 mmproj 切片与首帧耗时的变量，动了就与 App 手工测的行为不一致。
- 提示词：取 md 表格「输入提示词」列原文。

产物：
  MiniCPM-V-demo/Resources/Benchmark/
      cases.jsonl
      <图片文件…>

脚本幂等：重复跑会覆盖同名产物。
"""
import json
import re
import shutil
import sys
import urllib.parse
from pathlib import Path

SRC = Path("/Users/tc/Downloads/proj/数据/35BA3B_cases")
DST = Path(__file__).parent.parent / "MiniCPM-V-demo" / "Resources" / "Benchmark"

# md 表格行：| 1（zh） | ![..](images/x.png)<br><br>`images/x.png` | 提示词 | …
ROW = re.compile(r"^\|\s*(\d+)\s*（")


def split_cells(line: str) -> list[str]:
    """按未转义的 | 切分 markdown 表格行。"""
    return re.split(r"(?<!\\)\|", line)


def main() -> None:
    if not SRC.is_dir():
        sys.exit(f"源目录不存在：{SRC}")

    md = (SRC / "35BA3B_cases.md").read_text(encoding="utf-8")
    images_dir = SRC / "images"

    rows = [ln for ln in md.splitlines() if ROW.match(ln)]
    if not rows:
        sys.exit("没解析到任何 case 行，检查 md 表格格式")

    DST.mkdir(parents=True, exist_ok=True)

    cases = []
    for ln in rows:
        cells = [c.strip() for c in split_cells(ln)]
        # cells[0] 是行首空串，cells[1]=编号，cells[2]=图片，cells[3]=提示词
        if len(cells) < 4:
            continue
        idx = int(ROW.match(ln).group(1))

        # 图片文件名：取反引号里的路径（md 里是 URL 编码过的）
        m = re.search(r"`([^`]+)`", cells[2])
        if not m:
            print(f"⚠️ 第 {idx} 行取不到图片名，跳过")
            continue
        rel = urllib.parse.unquote(m.group(1))
        src_img = images_dir / Path(rel).name
        if not src_img.is_file():
            alt = images_dir / rel
            src_img = alt if alt.is_file() else None
        if src_img is None:
            print(f"⚠️ 第 {idx} 行图片不存在：{rel}，跳过")
            continue

        prompt = cells[3].replace("\\|", "|").strip()
        if not prompt:
            print(f"⚠️ 第 {idx} 行提示词为空，跳过")
            continue

        dst_img = DST / src_img.name
        shutil.copyfile(src_img, dst_img)

        cases.append({
            "key": idx,
            "image": src_img.name,
            "text": prompt,
        })

    if not cases:
        sys.exit("没有解析出任何有效 case")

    cases.sort(key=lambda c: c["key"])
    with open(DST / "cases.jsonl", "w", encoding="utf-8") as f:
        for c in cases:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")

    total = sum((DST / c["image"]).stat().st_size for c in cases)
    print(f"✅ 生成 {len(cases)} 条 case → {DST}")
    print(f"   图片合计 {total / 1024 / 1024:.1f} MB")
    for c in cases:
        print(f"   #{c['key']:>2}  {c['image']}  「{c['text'][:28]}…」")


if __name__ == "__main__":
    main()
