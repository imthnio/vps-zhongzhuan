# 端口转发一键脚本

## 一键运行

```bash
sh -c 'set -e; if [ "$(id -u)" -eq 0 ]; then run=""; elif command -v sudo >/dev/null 2>&1; then run="sudo"; else echo "请用 root 运行，或先安装 sudo" >&2; exit 1; fi; if command -v apk >/dev/null 2>&1; then $run apk add --no-cache bash curl ca-certificates; elif command -v apt-get >/dev/null 2>&1; then $run apt-get update -qq; $run apt-get install -y bash curl ca-certificates; else echo "只支持 Debian、Ubuntu、Alpine" >&2; exit 1; fi; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fsSL https://raw.githubusercontent.com/imthnio/vps-zhongzhuan/main/install.sh -o "$f" || curl -fsSL https://cdn.jsdelivr.net/gh/imthnio/vps-zhongzhuan@main/install.sh -o "$f"; [ -s "$f" ] && head -n 1 "$f" | grep -q "^#!/bin/bash" || { echo "下载的脚本不正确" >&2; exit 1; }; if [ -n "$run" ]; then sudo bash "$f"; else bash "$f"; fi'
```

## 中转 Hysteria2 端口跳跃节点

落地机 A 上的 Hysteria2 开了端口跳跃，想用这台机器 B 中转：

1. 先在 A 上查 hy 的**真实端口**（不是跳跃那一段）：`ss -ulnp | grep -i hy`，比如是 `443`
2. 在 B 上运行脚本 → 菜单 `2` 添加规则：落地机地址填 `A的IP`，节点端口填 `443`，中转端口直接回车（和节点端口一样）
3. 问「要开启端口跳跃吗」时选 `y`，端口段直接回车用默认的 `20000-50000`
4. 去 B 的云服务器控制台「安全组」放行 **UDP 20000-50000**
5. 客户端里服务器地址改成 `B的IP:20000-50000`（Clash Meta 写 `port: 443` 再加 `ports: 20000-50000`），密码、SNI 等其他参数照旧

不想用跳跃也可以：第 3 步选 `n`，客户端填 `B的IP:443` 就行。

## 赞赏支持
如果这个脚本帮到了你，欢迎请我喝杯咖啡 ☕  
微信扫一扫下方赞赏码即可：

![赞赏码](./appreciate.png)
