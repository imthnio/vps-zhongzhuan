# 端口转发一键脚本

全中文菜单，小白跟着提示填就行。基于高性能转发工具 [realm](https://github.com/zhboner/realm)（TCP 和 UDP 一起转）。

**一句话理解转发**：别人访问「这台机器:端口A」→ 自动转到「目标服务器:端口B」。

## 一键运行

```bash
sh -c 'set -e; if [ "$(id -u)" -eq 0 ]; then run=""; elif command -v sudo >/dev/null 2>&1; then run="sudo"; else echo "请用 root 运行，或先安装 sudo" >&2; exit 1; fi; if command -v apk >/dev/null 2>&1; then $run apk add --no-cache bash curl ca-certificates; elif command -v apt-get >/dev/null 2>&1; then $run apt-get update -qq; $run apt-get install -y bash curl ca-certificates; else echo "只支持 Debian、Ubuntu、Alpine" >&2; exit 1; fi; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fsSL https://raw.githubusercontent.com/imthnio/vps-zhongzhuan/main/install.sh -o "$f" || curl -fsSL https://cdn.jsdelivr.net/gh/imthnio/vps-zhongzhuan@main/install.sh -o "$f"; [ -s "$f" ] && head -n 1 "$f" | grep -q "^#!/bin/bash" || { echo "下载的脚本不正确" >&2; exit 1; }; if [ -n "$run" ]; then sudo bash "$f"; else bash "$f"; fi'
```

上面这一行支持 Debian、Ubuntu、Alpine，会安装缺少的 bash、curl 和证书，并在 GitHub 下载失败时尝试 jsDelivr。需要 root 权限；普通用户需有 sudo。脚本运行中出错时会直接报错，不会重复运行。

装好后，以后直接在终端输入 `zhuanfa` 就能打开管理菜单。

## 菜单长这样

```
========== 端口转发管理菜单 ==========
  realm 状态：运行中

  1. 安装 / 更新 realm（第一次用先选这个）
  2. 添加转发规则
  3. 查看转发规则
  4. 删除转发规则
  5. 重启 realm 服务
  6. 查看运行状态
  7. 卸载（删除 realm 和所有规则）
  0. 退出
======================================
```

添加规则时是四步向导，每一步都有中文说明：填本机监听端口 → 填目标地址 → 填目标端口 → 写备注（可选），最后跟你确认一遍，还会顺手测一下目标通不通。

脚本只会在删除规则或卸载时回收它自己新建并记录的防火墙放行。旧版本创建的规则没有归属记录，升级后请手动检查这些端口是否仍需放行。外部访问还需检查云安全组和 NAT 映射。

## 赞赏支持
如果这个脚本帮到了你，欢迎请我喝杯咖啡 ☕  
微信扫一扫下方赞赏码即可：

![赞赏码](./appreciate.png)
