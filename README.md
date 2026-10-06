# 端口转发一键脚本

## 一键运行

```bash
sh -c 'set -e; if [ "$(id -u)" -eq 0 ]; then run=""; elif command -v sudo >/dev/null 2>&1; then run="sudo"; else echo "请用 root 运行，或先安装 sudo" >&2; exit 1; fi; if command -v apk >/dev/null 2>&1; then $run apk add --no-cache bash curl ca-certificates; elif command -v apt-get >/dev/null 2>&1; then $run apt-get update -qq; $run apt-get install -y bash curl ca-certificates; else echo "只支持 Debian、Ubuntu、Alpine" >&2; exit 1; fi; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fsSL https://raw.githubusercontent.com/imthnio/vps-zhongzhuan/main/install.sh -o "$f" || curl -fsSL https://cdn.jsdelivr.net/gh/imthnio/vps-zhongzhuan@main/install.sh -o "$f"; [ -s "$f" ] && head -n 1 "$f" | grep -q "^#!/bin/bash" || { echo "下载的脚本不正确" >&2; exit 1; }; if [ -n "$run" ]; then sudo bash "$f"; else bash "$f"; fi'
```

## 赞赏支持
如果这个脚本帮到了你，欢迎请我喝杯咖啡 ☕  
微信扫一扫下方赞赏码即可：

![赞赏码](./appreciate.png)
