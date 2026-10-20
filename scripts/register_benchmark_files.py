#!/usr/bin/env python3
"""
把 Sources/Benchmark/ 下的新 Swift 文件注册进 Xcode 工程。

工程用的是传统 pbxproj（objectVersion 56、无 PBXFileSystemSynchronizedRootGroup），
新文件不会自动纳管，必须显式加四处：
  1. PBXFileReference   —— 文件实体
  2. PBXBuildFile       —— 「编译这个文件」
  3. PBXGroup children  —— 挂到 Sources/Benchmark 组里
  4. Sources build phase —— 真正参与编译

⚠️ 历史坑（务必别退回去）：
   早期版本每次都「新建 Benchmark 组」，而组 ID 是按名字算的固定值 ——
   于是第二次运行会插入**第二个同 UUID 的 PBXGroup**。pbxproj 里后定义覆盖前定义，
   结果新文件进了组、老文件全被孤立，路径退回到工程根，编译报
   "Build input files cannot be found: .../MBBenchmarkViewController.swift"。
   现在改为：组已存在就**只追加 children**，绝不新建；建完后自检 ID 唯一性。

脚本幂等：已注册过的文件会跳过。改动前自动备份。
"""
import hashlib
import re
import shutil
import sys
from pathlib import Path

# 本脚本放在 scripts/ 下，所以相对于工程根要多退一层（.parent.parent）。
REPO = Path(__file__).resolve().parent.parent
PBX = REPO / "MiniCPM-V-demo.xcodeproj" / "project.pbxproj"
SRCDIR = REPO / "MiniCPM-V-demo" / "Sources" / "Benchmark"

# 主 App target 的 Sources build phase 与 Sources group（从工程里查出来的固定 ID）
APP_SOURCES_PHASE = "FA3FA25F2C1176E80077F732"
SOURCES_GROUP = "FA3FA2932C118A980077F732"


def uid(key: str) -> str:
    """稳定的 24 位十六进制 ID（pbxproj 惯例）。"""
    return "BE" + hashlib.md5(key.encode()).hexdigest().upper()[:22]


def insert_before(section_marker: str, block: str, s: str) -> str:
    """在 `/* End <marker> section */` 之前插入一段。"""
    end = f"/* End {section_marker} section */"
    idx = s.find(end)
    if idx == -1:
        sys.exit(f"找不到 {end}")
    return s[:idx] + block + s[idx:]


def main() -> None:
    files = sorted(p.name for p in SRCDIR.glob("*.swift"))
    if not files:
        sys.exit("Sources/Benchmark/ 下没有 .swift 文件")

    s = PBX.read_text(encoding="utf-8")

    already = [f for f in files if f"/* {f} */ = {{isa = PBXFileReference" in s]
    if already:
        print(f"已注册，跳过：{already}")
        files = [f for f in files if f not in already]
        if not files:
            return

    shutil.copyfile(PBX, PBX.with_suffix(".pbxproj.bak"))
    print(f"已备份 → {PBX.with_suffix('.pbxproj.bak').name}")

    # 1) PBXFileReference
    refs = "".join(
        f"\t\t{uid('ref:' + f)} /* {f} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = \"<group>\"; }};\n"
        for f in files
    )
    s = insert_before("PBXFileReference", refs, s)

    # 2) PBXBuildFile
    builds = "".join(
        f"\t\t{uid('build:' + f)} /* {f} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {uid('ref:' + f)} /* {f} */; }};\n"
        for f in files
    )
    s = insert_before("PBXBuildFile", builds, s)

    # 3) 挂到 Benchmark 组：已存在则只追加 children，不存在才新建
    gid = uid("group:Benchmark")
    group_children = "".join(f"\t\t\t\t{uid('ref:' + f)} /* {f} */,\n" for f in files)

    if f"{gid} /* Benchmark */ = {{" in s:
        pat_children = re.compile(
            re.escape(gid) + r" /\* Benchmark \*/ = \{\s*\n"
            r"\s*isa = PBXGroup;\s*\n"
            r"\s*children = \(\s*\n"
        )
        if not pat_children.search(s):
            sys.exit("Benchmark 组已存在但 children 格式不符，中止（不要硬改）")
        s = pat_children.sub(lambda m: m.group(0) + group_children, s, count=1)
        print("Benchmark 组已存在，只追加 children（未新建组）")
    else:
        group_block = (
            f"\t\t{gid} /* Benchmark */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n"
            f"{group_children}"
            f"\t\t\t);\n"
            f"\t\t\tpath = Benchmark;\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};\n"
        )
        s = insert_before("PBXGroup", group_block, s)
        print("新建 Benchmark 组")

        # 3b) 仅新建时需要挂到 Sources 组下
        pat_src = re.compile(
            r"(" + re.escape(SOURCES_GROUP) + r" /\* Sources \*/ = \{\s*\n"
            r"\s*isa = PBXGroup;\s*\n"
            r"\s*children = \(\s*\n)"
        )
        if not pat_src.search(s):
            sys.exit("找不到 Sources 组的 children 列表")
        s = pat_src.sub(lambda m: m.group(0) + f"\t\t\t\t{gid} /* Benchmark */,\n", s, count=1)

    # 4) 加进主 App target 的 Sources build phase
    build_entries = "".join(
        f"\t\t\t\t{uid('build:' + f)} /* {f} in Sources */,\n" for f in files
    )
    pat_phase = re.compile(
        r"(" + re.escape(APP_SOURCES_PHASE) + r" /\* Sources \*/ = \{\s*\n"
        r"\s*isa = PBXSourcesBuildPhase;\s*\n"
        r"\s*buildActionMask = 2147483647;\s*\n"
        r"\s*files = \(\s*\n)"
    )
    if not pat_phase.search(s):
        sys.exit("找不到主 App 的 Sources build phase")
    s = pat_phase.sub(lambda m: m.group(0) + build_entries, s, count=1)

    # 自检：组的 UUID 必须只出现两次（定义一次 + 父组引用一次）
    occurrences = s.count(f"{gid} /* Benchmark */")
    if occurrences != 2:
        sys.exit(f"自检失败：Benchmark 组引用出现 {occurrences} 次，预期 2 次。"
                 f"已备份到 {PBX.with_suffix('.pbxproj.bak').name}，未写入。")

    PBX.write_text(s, encoding="utf-8")
    print(f"已注册 {len(files)} 个文件：")
    for f in files:
        print(f"  - {f}")


if __name__ == "__main__":
    main()
