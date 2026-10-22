#!/bin/bash
# 卸载守护进程(恢复系统默认控制)
set -euo pipefail
cd "$(dirname "$0")"
BIN="$(pwd)/.build/release/fanctl"
if [ ! -x "$BIN" ]; then
    if [ -x "/Library/Application Support/MacFanControl/fanctl" ]; then
        BIN="/Library/Application Support/MacFanControl/fanctl"
    else
        echo "找不到 fanctl"; exit 1
    fi
fi
sudo "$BIN" uninstall
