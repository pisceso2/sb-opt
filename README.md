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
| **系统优化** | BBR + fq（`99-zz` 抢优先级覆盖他处 fq_pie，并用 `tc` 替换已有网卡队列）+ sysctl 调优 + 1G swap + 文件句柄 1048576 |
| **配置调参** | Hysteria2 加 `obfs.salamander`、UDP/443 挪到 24443；REALITY 只做检查（uTLS 指纹是客户端参数，服务端没有该字段） |
| **伪装站测速** | 实测 8 个候选站的 TCP/TLS 握手延迟，挑最快的填 `reality.handshake.server` |
| **生成链接** | 输出 `vless://`、`hysteria2://`、`trojan://`、`tuic://`、`anytls://`、`ss://`，直接粘贴进 v2rayN |
| **启停入站** | `disable <tag>` 精简掉 TUIC / Argo，`enable <tag>` 随时恢复 |
| **流量守护** | vnstat 统计 + 每日超 15GB 提醒（600GB 月配额） |
| **回滚** | 一键恢复最近一次备份 |
| **诊断** | 配置探测失败时输出各来源原始结果（进程/unit/docker/已知路径/find） |
| **文件检查** | 逐个校验 JSON 是否合法、列出每文件的入站与端口、查重复端口/tag |
| **JSONC 兼容** | sing-box 的解析器允许 `//` 注释与尾逗号，jq 不允许；`audit` 会自动规范化后再读，`fixjson` 可原地转成严格 JSON（先备份、先 check、失败回滚） |

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
sbopt doctor           # 配置探测诊断（找不到配置时先跑这个）
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

`<tag|type>` 支持四种写法，`sbopt audit` 会列出序号和 tag：

| 写法 | 例子 | 说明 |
|---|---|---|
| 序号 | `sbopt disable 2` | 对应 audit 输出的 `#` 列，**tag 带 emoji/空格时最省事** |
| tag 精确 | `sbopt disable "my-node"` | 需完整匹配 |
| tag 包含 | `sbopt disable tuic` | 忽略大小写，匹配 `🇭🇰 xxx tuic` 这类长 tag |
| 协议名 | `sbopt port hy2 24443` | 支持 `hy2`/`ss`/`stls` 等别名 |

## 配置探测

不同一键脚本的配置位置差别很大，`v1.1.0` 起按五路探测：

1. 正在运行的 `sing-box`/`xray` 进程命令行里的 `-c` / `--config`
2. systemd 单元 `ExecStart` 里的 `-c` / `--config`
3. docker 容器（自动把容器内路径映射到宿主机路径，重启走 `docker restart`）
4. 内置已知路径（含 mack-a 的 `/etc/v2ray-agent/...`）
5. `/etc`、`/opt`、`/root`、`/usr/local/etc` 下 5 层内的受限 `find`

同时支持两种布局：

| 布局 | 例子 | 处理方式 |
|---|---|---|
| 单文件 | `/etc/sing-box/config.json` | 直接改 |
| 多文件目录 | `/etc/v2ray-agent/sing-box/conf/config/*.json` | 定位到含该入站的文件，在临时副本上 `sing-box check` 通过后才替换 |

还找不到就跑 `sbopt doctor`，把输出整段贴出来。

**`v1.3.0` 起额外做了三件事：**

- 服务名只会是真正的代理单元。`sing-box`、`xray`、`hysteria-server`、`*-sing-box` 之类放行；`argo`、`nginx` 一律拒绝，**不会重启错服务**
- 二进制路径会增加 5 条来源：`/proc/<pid>/exe` → argv[0]（含相对路径还原）→ systemd `ExecStart` → 常见安装位置 → 受限 `find`
- `audit` 会点名列出「名字像 inbound 却解析不出入站」的配置文件（如 `inbounds` 为空数组），并把它和端口监听列表对账
- `restart_svc` 在服务名未探测到时会自动 `detect_svc`（此前 `fixjson` 没调用过 `detect_svc`，导致重启直接返回失败、日志为空）
- 重启改为轮询等待（最多 20 秒 × 3 次尝试），并打印 `journalctl` 真实报错，避免 2C2G 上启动慢被误判为失败
- 写回配置用 `cat` 覆写而非 `install -m 600`，保留原文件权限/属主（sing-box 非 root 运行时不会被锁死）
- 目录态校验改用 `sing-box check -C <dir>`（`-c` 只接受单个文件，传目录会报 `is a directory`）；所有读配置的地方统一走 JSONC 兼容层，改配置前会提示「写回后注释会丢失」

## 下载完整性

脚本末尾有 `# __END_SBOPT__` 标记，`install.sh` 和 `sbopt update` 都会校验它加版本号加行数，**被截断的半截文件不会被安装**（这是 v1.1.1 修的：早期版本因网络中断可能装上只有几十行的残文件，运行后毫无反应）。

手动自查：

```bash
wc -l /root/sb-opt/sb-opt.sh              # 应 >= 500，1.2.0 约 1150
grep -m1 '^# VERSION' /root/sb-opt/sb-opt.sh
tail -1 /root/sb-opt/sb-opt.sh            # 应看到 __END_SBOPT__
```

---

## 下载源

`install.sh` 与 `sbopt update` 会**依次尝试 4 个源**，前一个不通自动换下一个：

```
raw.githubusercontent.com  →  cdn.jsdelivr.net/gh  →  raw.gitmirror.com  →  ghfast.top 加速
```

国内机器上 `raw.githubusercontent.com` 经常不可达，脚本会自动落到 jsdelivr，不需要你手动改。

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