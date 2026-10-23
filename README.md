# 校园网 DNS 修复工具

> **症状：连校园网时打不开学校的任何网站（官网、统一身份认证、教务系统……），
> 但用流量或其他 WiFi 就一切正常。能上网，就是上不了学校网站。**

这个工具专门解决这类问题。原理很直接：**校园网拦截了「校内域名的明文 DNS 查询」**，
本工具在本机跑一个加密 DNS（DoH）转发，绕开拦截。

- ✅ **无需安装任何第三方软件**，只依赖系统自带的 Python 3
- ✅ **不需要管理员权限也能运行服务**（只有改系统 DNS 那一步需要）
- ✅ **有自检保护**，自检不通过就完全不碰你的网络
- ✅ **一键恢复**原状
- ✅ 约 600 行，纯标准库，代码透明可审计

---

## 目录

- [典型症状](#典型症状)
- [根因](#根因)
- [快速开始](#快速开始)
- [验证是否生效](#验证是否生效)
- [恢复原状](#恢复原状)
- [换成你自己学校的域名](#换成你自己学校的域名)
- [更省事的替代方案](#更省事的替代方案)
- [常见问题](#常见问题)
- [原理详解](#原理详解)
- [案例研究：某高校实测数据](#案例研究某高校实测数据)
- [文件说明](#文件说明)
- [免责声明](#免责声明)

---

## 典型症状

满足以下几条，基本就是这个病：

| 现象 | 说明 |
|---|---|
| 校园网能上网，但学校网站打不开 | 公网正常，只有 `.edu.cn` 之类打不开 |
| 换流量 / 手机热点就正常 | 说明**你电脑没问题** |
| 学校登录页一直转圈或报 DNS 错误 | 常见于 `sso.xxx.edu.cn` / `cas.xxx.edu.cn` |
| `ping` 学校服务器 IP 能通 | 线路正常，只是域名解析不出来 |
| 换公共 DNS（223.5.5.5 / 8.8.8.8）也没用 | 拦截发生在网络侧，不在你本机 |

## 根因

正常的 DNS 查询是**明文 UDP 53 端口**，中间设备能看清你查的是哪个域名，
于是可以针对性地把这个包丢掉。丢弃方式通常是：

- 对特定域名（如校内域名）的 UDP 查询**直接不回应**（表现为超时）
- 但 **TCP 53 端口和加密 DNS 不受影响**

于是出现了「能上网、但上不了学校网站」这种特别迷惑的现象。

## 快速开始

### 前置条件

- Windows 10 / 11
- Python 3（已经装了就跳过；没有的话到 [python.org](https://www.python.org/downloads/) 下载，
  安装时**勾选 Add Python to PATH**）

### 安装

1. **双击 `Install.cmd`**
2. 弹出 UAC 时点「**是**」（改系统 DNS 需要管理员权限）
3. 菜单里输入 **`1`** 回车

脚本会自动完成：

| 步骤 | 说明 |
|---|---|
| 环境检查 | 找 Python、自动识别正在上网的网卡 |
| 配置开机自启 | 在「启动」文件夹放快捷方式，并写注册表 Run 项兜底 |
| 启动转发服务 | `pythonw` 无窗口运行，输出写 `relay.log` |
| **先自检再改 DNS** | 自检不通过就**不动你的网络**，避免把你弄断网 |
| 备份原 DNS | 存到 `dns_backup.txt` |
| 切换系统 DNS | 指向 `127.0.0.1` |
| 最终验证 | 实测校内域名 + 公网域名 |

## 验证是否生效

装完后浏览器可能还缓存着解析失败的结果，**先按 `Ctrl + Shift + R` 强制刷新**，或关掉重开。

命令行验证：

```powershell
# 查看状态(不需要管理员)
powershell -ExecutionPolicy Bypass -File .\setup_dns.ps1 -Action Status

# 直接测解析(不指定 DNS 服务器, 走系统设置)
Resolve-DnsName sso.hdu.edu.cn

# 测本地转发服务
python .\check_dns.py sso.hdu.edu.cn www.hdu.edu.cn

# 看服务日志
Get-Content .\relay.log -Tail 40 -Encoding UTF8
```

## 恢复原状

**双击 `Install.cmd` → 输入 `2` 回车。**

会删掉快捷方式、注册表项、停止服务、把 DNS 还原成原来的设置（有备份就按备份还原，
没有就恢复为 DHCP 自动获取）。

## 换成你自己学校的域名

自检默认用杭州电子科技大学（`www.hdu.edu.cn`）做示例，**你需要换成自己学校的域名**，
否则自检结果没有意义。

### 方法一：配置文件（推荐）

```powershell
Copy-Item config.example.json config.json
notepad config.json
```

改成你的域名，例如：

```json
{
  "probeDomain": "www.example.edu.cn",
  "interfaceAlias": ""
}
```

`config.json` 已被 `.gitignore` 忽略，不会被提交。之后正常双击 `Install.cmd` 即可。

### 方法二：命令行参数

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_dns.ps1 -Action Apply -ProbeDomain www.example.edu.cn
```

### 方法三：改代码

编辑 `doh_dns.py` 顶部的 `PROBE_DOMAINS` 列表。

> 不知道学校域名？打开学校官网看一眼地址栏就行，一般是 `www.xxx.edu.cn`。

## 更省事的替代方案

安装前不妨先看这几条，有些比装工具更省事：

1. **直接用流量 / 手机热点** —— 临时查个东西最快
2. **学校 WebVPN / 校园 VPN** —— 走它访问校内资源通常不受这个 DNS 问题影响
   （但如果认证服务器本身在被拦的域名下，VPN 客户端也可能连不上）
3. **在路由器上配加密 DNS** —— 有自己路由器的话最省事，手机平板电脑全部一起修好。
   把路由器 DNS 设为 `223.5.5.5` 并开启 DoH，或刷 OpenWrt 配置 DoH
4. **本工具** —— 适合只修当前这台电脑

## 常见问题

<details>
<summary><b>为什么用启动文件夹而不是计划任务？</b></summary>

早期版本用过 SYSTEM 身份的计划任务，结果发现两个问题：

- 以 SYSTEM 注册的任务，**非管理员连查询都会被拒绝**（`Access is denied`），出问题极难排查
- 绑定 53 端口**本来就不需要管理员权限**，没必要为了它上 SYSTEM

启动文件夹快捷方式直观可见，自己就能删，调试也方便。
</details>

<details>
<summary><b>会把我网络弄断吗？</b></summary>

不会，有两道保护：

1. 安装脚本**先自检**，解析不出校内域名就**完全不碰系统 DNS**
2. 即使服务以后意外停了，系统查 `127.0.0.1` 失败后会回落到 DHCP 下发的校园 DNS，
   上网不受影响（只是校内网站会重新打不开）
</details>

<details>
<summary><b>53 端口不需要管理员权限？</b></summary>

**不需要。** 这点和 Linux 不同——Windows 上绑定低位端口没有特权限制。
所以转发服务能以普通用户身份运行。

真正需要管理员的是**修改系统 DNS 设置**（`Set-DnsClientServerAddress`），
所以 `Install.cmd` 还是要提权。
</details>

<details>
<summary><b>DoH 服务器为什么用 IP 直连，不用域名？</b></summary>

因为校园网会按域名（SNI）**连带阻断 DoH 服务域名**。
实测 `https://dns.alidns.com/dns-query` 连不上，但 `https://223.5.5.5/dns-query` 完全正常。
所以本工具一律 IP 直连，不解析 DoH 域名。
</details>

<details>
<summary><b>日志里中文乱码？</b></summary>

`relay.log` 是 UTF-8 编码。PowerShell 5.1 的 `Get-Content` 默认按 ANSI 解码会乱码，
读取时加 `-Encoding UTF8` 即可：

```powershell
Get-Content .\relay.log -Tail 40 -Encoding UTF8
```
</details>

<details>
<summary><b>手机上也想用？</b></summary>

双击 `Install.cmd` → 选 **`5`**（安装时允许局域网共用）。
然后手机 WiFi 设置里把 DNS 改成**你电脑的局域网 IP**（`ipconfig` 里看 IPv4 地址）。

前提：手机和电脑在同一局域网（比如都在你自己的寝室内路由器下）。
</details>

<details>
<summary><b>换到别的网络（家里 WiFi）会有影响吗？</b></summary>

转发服务照常运行，只是用不上了。如果你的家用网络有认证门户（酒店、机场那种），
登录页可能因为 DNS 被指向本地而弹不出来——这时选 `2` 恢复一下即可。
</details>

## 原理详解

```
浏览器 → 系统 DNS (127.0.0.1) → 本工具 → HTTPS 加密 → 公共 DoH → 拿到真实 IP
                                    ↑
                          校园网在这里拦不住
```

具体做的事：

1. 在本机 **53 端口**提供一个普通 UDP DNS 服务（系统 DNS 只能指向 53 端口）
2. 收到查询后，把原始 DNS 报文**塞进 HTTPS（443 端口）加密通道**发给公共 DoH 服务器
   —— 中间设备看不到内容，也无法按域名选择性丢弃
3. 把返回结果转成标准 DNS 响应还给系统
4. 带缓存（默认 60 秒），多上游容错（阿里 / 腾讯），全失败时回落到校园 DNS
5. 用开机自启保证它一直在跑

### 为什么能解开

| 通道 | 校园网能否识别域名 | 实测 |
|---|---|---|
| 明文 UDP 53 | ✅ 能 → 可拦截 | ❌ 超时 |
| 明文 TCP 53 | ✅ 能 → 可拦截 | ✅ 有时可用 |
| **HTTPS 443 加密 DNS** | ❌ 看不到 | ✅ **正常** |

## 案例研究：某高校实测数据

> 下面的数据来自真实排查，可作为「如何确认自己也是这个问题」的参考。
> 学校域名已用 `example.edu.cn` 替代。

### 底层链路全部正常

| 测试项 | 结果 |
|---|---|
| ping 网关 | 通，2ms |
| ping 校园 DNS | 通，9ms |
| ping 公网 DNS | 通，9ms |
| 访问公网网站 | 正常 |

### 只有「校内域名 + 明文 UDP DNS」这一个组合失败

| DNS 服务器 | 明文 UDP | TCP |
|---|---|---|
| 校园 DNS 1 | ❌ 超时 | — |
| 校园 DNS 2 | ❌ 超时 | — |
| 223.5.5.5（阿里） | ❌ 超时 | ✅ 正常 |
| 114.114.114.114 | ❌ 超时 | — |
| 8.8.8.8（谷歌） | ❌ 超时 | — |

**对照组**（同一台 `223.5.5.5`，同样查法）：

| 域名 | 明文 UDP |
|---|---|
| `www.baidu.com` | ✅ 正常 |
| `www.sina.com.cn` | ✅ 正常 |
| `www.163.com` | ✅ 正常 |
| `sso.example.edu.cn` | ❌ 超时 |
| `cas.example.edu.cn` | ❌ 超时 |
| `example.edu.cn` | ❌ 超时 |

### 决定性证据

绕开 DNS、直接用 IP 访问学校统一身份认证页面：

```
HTTP=200  TLS验证=0(证书有效)  耗时=0.195s  页面标题「统一身份认证平台」
```

**线路完全畅通，唯一卡住的就是域名解析这一步。**

### 完整因果链

```
https://cas.example.edu.cn/cas/login?service=...
        ↓ 服务器返回 302 重定向
https://sso.example.edu.cn/login?service=...
        ↓
   ❌ Could not resolve host: sso.example.edu.cn   ← 浏览器就卡死在这里
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `Install.cmd` | **入口**，双击运行（自动请求管理员权限） |
| `menu.ps1` | 交互菜单界面 |
| `setup_dns.ps1` | 安装 / 恢复 / 状态检查的核心逻辑 |
| `doh_dns.py` | 加密 DNS 转发服务本体（仅用 Python 标准库） |
| `run_relay.py` | 无窗口启动器：拉起服务并把输出写进 `relay.log`（含日志轮转） |
| `check_dns.py` | 小工具：测试本地转发服务的解析结果 |
| `config.example.json` | 配置模板，复制为 `config.json` 后填写你的学校域名 |
| `_fix-ps1-encoding.ps1` | 维护用：给 `.ps1` 补 UTF-8 BOM（防止中文乱码） |
| `relay.log` | 服务日志（运行后生成，已忽略） |
| `dns_backup.txt` | 原 DNS 备份（安装后生成，含本机网络信息，已忽略） |

## 技术细节

<details>
<summary><b>DoH 实现方式</b></summary>

优先使用 RFC 8484 的 wire 格式（`POST /dns-query`，`Content-Type: application/dns-message`），
失败则退回 JSON 接口（`/resolve?name=...&type=A`）。

由于 DoH 服务器用 IP 直连时证书的 SAN 可能不含该 IP，
先尝试严格校验，失败再降级（传输本身仍在 TLS 内）。
</details>

<details>
<summary><b>支持的查询类型</b></summary>

A / AAAA / CNAME 走完整转换；其他类型（MX / TXT / NS / SOA / SRV 等）在 JSON 回退路径下尽力转换，
wire 路径则原样透传，完整支持。
</details>

<details>
<summary><b>安全考虑</b></summary>

- 默认只响应**本机与私有网段**的查询，避免被当作开放解析器滥用
- 上游只用公共 DoH，不经过任何第三方中转服务器
- 代码无外部依赖，纯 Python 标准库，可直接审计
</details>

## 免责声明

- 本工具**只绕过 DNS 解析这一层**，不改变、不绕过学校的任何其他网络限制（带宽、访问控制、认证等）。
- 严格来说，绕过校园网 DNS 过滤**可能不符合学校的网络管理规定**。是否使用请自行判断，
  并自行承担相应责任。
- 使用本工具意味着你的域名查询会发给公共 DNS 服务商（阿里 / 腾讯）。
  如果你的学校或单位对这点有要求，请勿使用。
- 本项目仅供学习与个人网络排障使用。

## License

MIT
