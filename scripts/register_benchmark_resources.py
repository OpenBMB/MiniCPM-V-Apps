#!/usr/bin/env python3
"""
把 Resources/Benchmark/ 下的内置数据集（cases.jsonl + 图片）注册成 bundle 资源。

为什么要打进 bundle 而不是只放 Documents：
批量测试要求**跨设备、跨会话的数据集完全一致**，靠手工往每台设备的 Documents
拷文件保证不了这一点（拷漏一张图，跑出来的数就不可比）。内置一份 + 允许
Documents 覆盖，既保证基准一致，也留了换数据集的口子。

实现要点（两个坑，都踩过）：
 1. 必须挂在 `MiniCPM-V-demo` 组下，**不是**工程 mainGroup —— mainGroup 的 path
    为空，挂过去会解析成 <工程根>/Resources/...，与实际位置差一层。
 2. 必须用 **folder reference**（`lastKnownFileType = folder`）整目录引入，
    而不是给 13 个文件各建一条 PBXFileReference。后者会被平铺拷到 bundle 根目录：
    PBXGroup 的层级只是 Xcode 导航用的，不会在 bundle 里建子目录。
    平铺后这些名字（"image 6.png"、"cases.jsonl"）会和 App 既有资源混在一起。

产物布局：$App.app/Benchmark/{cases.jsonl, <图片…>}

脚本幂等，改动前自动备份。
"""
import hashlib
import re
import shutil
import sys
from pathlib import Path

PBX = Path(__file__).parent.parent / "MiniCPM-V-demo.xcodeproj" / "project.pbxproj"
RESDIR = Path(__file__).parent.parent / "MiniCPM-V-demo" / "Resources" / "Benchmark"

APP_GROUP = "FA3FA2652C1176E80077F732"           # MiniCPM-V-demo 组（与 Sources 同级）
APP_RESOURCES_PHASE = "FA3FA2612C1176E80077F732"  # 主 App 的 Resources build phase

FOLDER_KEY = "folder:Resources/Benchmark"
GROUP_KEY = "group:Resources"


def uid(key: str) -> str:
    return "BF" + hashlib.md5(key.encode()).hexdigest().upper()[:22]


def insert_before(section: str, block: str, s: str) -> str:
    end = f"/* End {section} section */"
    idx = s.find(end)
    if idx == -1:
        sys.exit(f"找不到 {end}")
    return s[:idx] + block + s[idx:]


def main() -> None:
    files = [p for p in RESDIR.iterdir() if p.is_file() and not p.name.startswith(".")]
    if not files:
        sys.exit(f"{RESDIR} 下没有资源文件，先跑 build_benchmark_dataset.py")

    s = PBX.read_text(encoding="utf-8")

    folder_id = uid(FOLDER_KEY)
    build_id = uid("build:" + FOLDER_KEY)
    group_id = uid(GROUP_KEY)

    marker = f"{folder_id} /* Benchmark */"
    if marker in s:
        print("已注册（folder reference 已存在），跳过")
        return

    shutil.copyfile(PBX, PBX.with_suffix(".pbxproj.bak"))
    print(f"已备份 → {PBX.with_suffix('.pbxproj.bak').name}")

    # 1) 整目录的 folder reference
    s = insert_before(
        "PBXFileReference",
        f"\t\t{folder_id} /* Benchmark */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = folder; path = Benchmark; sourceTree = \"<group>\"; }};\n",
        s,
    )

    # 2) 一条 build file 即可（拷整个目录）
    s = insert_before(
        "PBXBuildFile",
        f"\t\t{build_id} /* Benchmark in Resources */ = {{isa = PBXBuildFile; "
        f"fileRef = {folder_id} /* Benchmark */; }};\n",
        s,
    )

    # 3) Resources 组（path = Resources），folder reference 放里面
    s = insert_before(
        "PBXGroup",
        f"\t\t{group_id} /* Resources */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n"
        f"\t\t\t\t{folder_id} /* Benchmark */,\n"
        f"\t\t\t);\n"
        f"\t\t\tpath = Resources;\n"
        f"\t\t\tsourceTree = \"<group>\";\n"
        f"\t\t}};\n",
        s,
    )

    # 4) Resources 组挂到 MiniCPM-V-demo 组下
    pat = re.compile(
        r"(" + re.escape(APP_GROUP) + r" /\* MiniCPM-V-demo \*/ = \{\s*\n"
        r"\s*isa = PBXGroup;\s*\n\s*children = \(\s*\n)")
    if not pat.search(s):
        sys.exit("找不到 MiniCPM-V-demo 组的 children 列表")
    s = pat.sub(r"\1" + f"\t\t\t\t{group_id} /* Resources */,\n", s, count=1)

    # 5) 加进主 App 的 Resources build phase
    pat2 = re.compile(
        r"(" + re.escape(APP_RESOURCES_PHASE) + r" /\* Resources \*/ = \{\s*\n"
        r"\s*isa = PBXResourcesBuildPhase;\s*\n"
        r"\s*buildActionMask = 2147483647;\s*\n"
        r"\s*files = \(\s*\n)")
    if not pat2.search(s):
        sys.exit("找不到主 App 的 Resources build phase")
    s = pat2.sub(r"\1" + f"\t\t\t\t{build_id} /* Benchmark in Resources */,\n", s, count=1)

    PBX.write_text(s, encoding="utf-8")
    print(f"已注册 folder reference：Resources/Benchmark（{len(files)} 个文件）")
    for f in sorted(p.name for p in files):
        print(f"  - {f}")


if __name__ == "__main__":
    main()
