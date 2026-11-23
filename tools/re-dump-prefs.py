# -*- coding: utf-8 -*-
"""开发辅助：把 Solo 面板 plist 展开成可读的条目列表。"""
import plistlib
import sys
import os

base = r"D:\WorkBudy\iOS-Tweaks\analysis\solo\prefs\var\jb\Library\PreferenceBundles\SoloPrefs.bundle"
files = sys.argv[1:] or ["Root.plist", "HomeScreen.plist", "Clock.plist"]

for name in files:
    path = os.path.join(base, name)
    print("===== %s =====" % name)
    with open(path, "rb") as fp:
        data = plistlib.load(fp)
    for item in data.get("items") or []:
        cell = item.get("cell", "?")
        label = item.get("label", "")
        key = item.get("key", "")
        footer = (item.get("footerText") or "").replace("\n", " ")
        print("  [%s] %s%s%s" % (cell, label,
                                 (" key=" + key) if key else "",
                                 ("  # " + footer) if footer else ""))
    print()
