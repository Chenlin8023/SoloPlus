#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rewrite_control.py — 用 JSON 规格重写 deb 的 DEBIAN/control。

用法：
    python3 tools/rewrite_control.py <control 路径> <spec.json>

规则：
  * spec 里出现的键一律覆盖；值为空字符串 = 从 control 删除该字段；
  * 未在 spec 里出现的原有字段原样保留（顺序不变）；
  * 已知字段按 CANON 顺序排在最前，Description 永远放最后；
  * 多行值除首行外一律加一个前导空格，输出 UTF-8 + LF。
"""

import json
import sys

CANON = [
    "Package", "Name", "Version", "Architecture", "Section", "Priority",
    "Maintainer", "Author", "Depends", "Pre-Depends", "Conflicts",
    "Replaces", "Provides", "Installed-Size",
]


def parse(text):
    fields = []
    for line in text.replace("\r\n", "\n").split("\n"):
        if not line.strip():
            continue
        if line[0] in " \t":
            if not fields:
                raise SystemExit("!! control 续行没有归属字段")
            fields[-1][1].append(line[1:].rstrip())
        else:
            key, _, value = line.partition(":")
            fields.append([key.strip(), [value.strip()]])
    return fields


def render(fields):
    out = []
    for key, values in fields:
        out.append("%s: %s" % (key, values[0]))
        for cont in values[1:]:
            out.append(" " + cont if cont else " ")
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    control_path, spec_path = sys.argv[1], sys.argv[2]

    with open(spec_path, "r", encoding="utf-8") as fp:
        spec = json.load(fp)
    with open(control_path, "r", encoding="utf-8") as fp:
        fields = parse(fp.read())

    order = [k for k, _ in fields]
    table = dict((k, v) for k, v in fields)

    for key, value in spec.items():
        text = "" if value is None else str(value)
        if text == "":
            table.pop(key, None)
            continue
        lines = text.replace("\r\n", "\n").split("\n")
        table[key] = lines
        if key not in order:
            order.append(key)

    head = [k for k in CANON if k in table]
    tail = [k for k in order if k not in CANON and k != "Description" and k in table]
    final = [[k, table[k]] for k in head + tail]
    if "Description" in table:
        final.append(["Description", table["Description"]])

    with open(control_path, "w", encoding="utf-8", newline="\n") as fp:
        fp.write(render(final))
    print(render(final))


if __name__ == "__main__":
    main()
