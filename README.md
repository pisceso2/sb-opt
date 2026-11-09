# sb-opt

sing-box / Xray 一体机（香港 2C2G 小机）**性能优化 · 体检 · 排障** 工具箱。

专为「野草云 HK-Intel-MF-2C2G + sing-box 四合一（Reality / Hysteria2 / TUIC / Argo）」这类场景设计：**不换协议，只把参数调到这台机器该有的样子。**

---

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/pisceso2/sb-opt/main/install.sh | bash
```

装完直接运行：

```bash
sbopt
```

---

## 它做什么

| 功能 | 说明 |
|---|---|
| **体检** | 内核 / BBR / 内存 / swap / 入站清单 / 端口 / 防火墙 / 流量，一眼看清现状 |
| **系统优化** | BBR + fq + sysctl 调优 + 1G swap + 文件句柄 1048576（收益最大的一步） |
| **配置调参** | REALITY 补 `utls: chrome`、Hysteria2 加 `obfs.salamander`、UDP/443 挪到 24443 |
| **伪装站测速** | 实测 8 个候选站的 TCP/TLS 握手延迟，挑最快的填 `reality.handshake.server` |
| **生成链接** | 输出 `vless://` 与 `hysteria2://`，直接粘贴进 v2rayN |
| **启停入站** | `disable <tag>` 精简掉 TUIC / Argo，`enable <tag>` 随时恢复 |
| **流量守护** | vnstat 统计 + 每日超 15GB 提醒（600GB 月配额） |
| **回滚** | 一键恢复最近一次备份 |

### 安全设计

改配置的每一步都是：**备份 → 修改 → `sing-box check` 校验 → 重启 → 失败自动回滚**。

- 备份目录：`/root/sb-opt/backups/`（保留最近 15 份）
- 失败的新配置另存为 `/root/sb-opt/last-failed.json` 供排查
- 幂等：反复执行不会重复叠加
- 只改 `inbounds` 相关字段，不碰路由与出站

---

## 命令速查

```bash
sbopt                  # 交互菜单
sbopt audit            # 只体检，只读，不改任何东西
sbopt sys              # 系统层优化（BBR / sysctl / swap / 句柄）
sbopt tune             # 配置层调参（逐项确认）
sbopt dest             # REALITY 伪装站测速选优
sbopt links            # 生成客户端链接
sbopt traffic          # 流量统计 + 每日提醒
sbopt update           # 从 GitHub 拉取最新版
sbopt rollback         # 回滚到最近一次备份

sbopt port <tag> <n>   # 改某入站端口，如：sbopt port hy2 24443
sbopt disable <tag>    # 停用某入站，如：sbopt disable argo
sbopt enable <tag>     # 恢复被停用的入站
```

`<tag>` 是配置里 `inbounds[].tag` 的名字，`sbopt audit` 会列出来。

---

## 升级

三种方式任选：

```bash
# 1) 重跑安装命令
curl -fsSL https://raw.githubusercontent.com/pisceso2/sb-opt/main/install.sh | bash

# 2) 用内置命令
sbopt update

# 3) 用 git（想本地改代码时用）
git clone https://github.com/pisceso2/sb-opt.git
cd sb-opt && ./sb-opt.sh audit
```

`sbopt update` 会先做 `bash -n` 语法校验，通过才替换；旧版备份为 `/root/sb-opt/sb-opt.sh.old`。

---

## 使用顺序建议

```
1. sbopt audit      # 先看清现状，别盲目调
2. sbopt sys        # 开 BBR，收益最大
3. sbopt tune       # 按提示逐项改（每项都会问你要不要改）
4. sbopt links      # 拿新链接导入客户端
5. sbopt traffic    # 挂上流量提醒
```

> 精简入站放在 `tune` 之后做：先 `sbopt audit` 看清单，再 `sbopt disable tuic` 之类逐个关掉不用的。

---

## 预期效果

香港 200Mbps 小机，优化后合理区间：

| 指标 | 预期 |
|---|---|
| 延迟 | 45–60 ms |
| 白天吞吐 | 100–150 Mbps |
| 晚高峰 | 40–70 Mbps |

如果裸测（不走代理）就只有 10–20Mbps 且全天如此，那是宿主机超售或国际出口拥塞，**配置优化救不回来**，应联系商家换宿主机。

---

## 不适用的情况

- **内核 < 4.9**（CentOS 7 常见）：`sys` 会拒绝执行并提示重装 Debian 12 / Ubuntu 22.04
- **非 sing-box / Xray 配置**：找不到标准 `.inbounds` 结构时会跳过深层分析
- **Windows**：这是给 Linux 服务器用的，客户端侧请用 v2rayN

---

## 免责

脚本只改本机配置文件，操作前均自动备份。仍建议先在测试机验证；因误用造成的服务中断，请用 `sbopt rollback` 恢复。

## License

MIT