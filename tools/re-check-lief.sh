#!/bin/bash
# 开发辅助：确保 WSL 的 python3 有 LIEF（objcdump.py 依赖）。
set -u
if python3 -c 'import lief, sys; print("lief", lief.__version__)' 2>/dev/null; then
  exit 0
fi
echo "lief missing, installing..."
pip3 install --quiet --user lief || pip3 install --quiet --break-system-packages lief
python3 -c 'import lief, sys; print("lief", lief.__version__)'
