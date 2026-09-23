# 端口转发一键脚本（基于 realm）

全中文菜单，小白跟着提示填就行。基于高性能转发工具 [realm](https://github.com/zhboner/realm)（TCP 和 UDP 一起转）。

**一句话理解转发**：别人访问「这台机器:端口A」→ 自动转到「目标服务器:端口B」。

## 一键运行

```bash
# 先下载，再运行（这样才能进交互菜单）
wget -qO install.sh https://raw.githubusercontent.com/imthnio/duankouzhuanfa/main/install.sh && sudo bash install.sh
```

- Alpine 用户先装基础工具：`apk update && apk add bash curl wget sudo`
- 如果上面那行下载慢/失败，换 jsdelivr 镜像：
  ```bash
  wget -qO install.sh https://cdn.jsdelivr.net/gh/imthnio/duankouzhuanfa@main/install.sh && sudo bash install.sh
  ```

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

## 脚本会自动做的事

- 按顺序试多个下载源（GitHub 直连 + 加速镜像），哪个能下用哪个
- 检测系统：Debian/Ubuntu 用 systemd，Alpine 用 OpenRC，服务文件自己生成
- realm 设为开机自启，崩溃自动重启
- 自动放行系统防火墙端口（ufw / firewalld / iptables）
- 加完规则自动重启服务，并确认端口真的在监听

## 支持的环境

- 系统：Debian / Ubuntu / Alpine
- 架构：x86_64、aarch64、armv7、armv6（自动识别）

## 转发不通？按顺序查

1. 菜单 6 看服务是不是"运行中"
2. 云厂商的安全组/防火墙有没有放行监听端口（脚本只管系统防火墙，云控制台那个要自己去开）
3. 目标地址:端口现在通不通（添加规则时脚本会顺手测一次）
4. 监听端口是不是被别的程序占了（添加时会提醒）

## 非交互用法（给老手写脚本调用）

```bash
sudo ACTION=add LISTEN_PORT=10000 TARGET_ADDR=1.2.3.4 TARGET_PORT=443 NOTE="备注" bash install.sh
sudo ACTION=del LISTEN_PORT=10000 bash install.sh
sudo bash install.sh list
sudo bash install.sh status
sudo UNINSTALL_CONFIRM=yes bash install.sh uninstall
```

## 卸载

菜单选 7，或 `sudo bash install.sh uninstall`，程序、服务、规则一次清干净。
