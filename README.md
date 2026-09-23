# 端口转发一键脚本

全中文菜单，小白跟着提示填就行。基于高性能转发工具 [realm](https://github.com/zhboner/realm)（TCP 和 UDP 一起转）。

**一句话理解转发**：别人访问「这台机器:端口A」→ 自动转到「目标服务器:端口B」。

## 一键运行

```bash
sh -c 'cd /tmp; for pm in "apk add --no-cache" "apt-get install -y" "yum install -y" "dnf install -y"; do b=${pm%% *}; command -v $b >/dev/null 2>&1 || continue; [ $b = apt-get ] && { apt-get update -qq 2>/dev/null || sudo apt-get update -qq 2>/dev/null; }; $pm bash curl wget sudo ca-certificates 2>/dev/null || sudo $pm bash curl wget sudo ca-certificates 2>/dev/null; break; done; ok=""; for u in https://raw.githubusercontent.com/imthnio/vps-zhongzhuan/main/install.sh https://cdn.jsdelivr.net/gh/imthnio/vps-zhongzhuan@main/install.sh; do (wget -qO install.sh "$u" || curl -fsSL -o install.sh "$u") 2>/dev/null && [ -s install.sh ] && head -1 install.sh | grep -q "^#!/bin/bash" && { ok=1; break; }; rm -f install.sh; done; [ -n "$ok" ] || { echo "下载 install.sh 失败，请检查网络"; exit 1; }; sudo bash install.sh 2>/dev/null || bash install.sh'
```

上面这一行会自动识别系统（Debian / Ubuntu / Alpine …），缺 bash、curl、wget 这些基础工具就自己装，下载时 GitHub 和 jsdelivr 两个源自动切换，全程不用你动手。

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
