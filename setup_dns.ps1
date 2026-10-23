<#
    校园网 DNS 修复工具  (配置 / 恢复 / 状态)
    =====================================================================
    问题: 校园网对校内域名(hdu.edu.cn 等)的明文 DNS(UDP/53) 查询做了拦截,
          导致校内网站域名解析失败、网页打不开; 但网络链路本身完全正常。
    方案: 本机运行一个加密 DNS(DoH) 转发服务, 把系统 DNS 指向它, 绕开拦截。

    用法(需管理员):
        .\setup_dns.ps1 -Action Apply      安装并启用
        .\setup_dns.ps1 -Action Restore    完全恢复原状
        .\setup_dns.ps1 -Action Status     查看当前状态(无需管理员)
        .\setup_dns.ps1 -Action Apply -Share   同时允许手机/平板使用(寝室路由器场景)
#>

[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Restore', 'Status')]
    [string]$Action = 'Status',

    # 允许局域网内其它设备(手机/平板)把 DNS 指向本机
    [switch]$Share,

    # 可选: 手动指定网卡名, 默认自动检测有默认网关的网卡
    [string]$InterfaceAlias = '',

    # 可选: 自检用的校内域名, 默认杭州电子科技大学。
    # 换成你自己学校的域名(如 www.xxx.edu.cn), 自检才有意义。
    [string]$ProbeDomain = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ----------------------------------------------------------------- 常量
$RELAY_DIR     = Split-Path -Parent $MyInvocation.MyCommand.Path
$RELAY_SCRIPT  = Join-Path $RELAY_DIR 'doh_dns.py'
$LAUNCHER      = Join-Path $RELAY_DIR 'run_relay.py'
$CONFIG_FILE   = Join-Path $RELAY_DIR 'config.json'
$LOG_FILE      = Join-Path $RELAY_DIR 'relay.log'
$BACKUP_FILE   = Join-Path $RELAY_DIR 'dns_backup.txt'
$PORT          = 53         # 系统 DNS 只能指向 53 端口
$FALLBACK_PORT = 5399

# 读取 config.json (若存在), 让用户不用改脚本代码就能换学校域名
if (Test-Path -LiteralPath $CONFIG_FILE) {
    try {
        $cfg = Get-Content -LiteralPath $CONFIG_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $ProbeDomain -and $cfg.probeDomain) { $ProbeDomain = [string]$cfg.probeDomain }
        if (-not $InterfaceAlias -and $cfg.interfaceAlias) { $InterfaceAlias = [string]$cfg.interfaceAlias }
    } catch {
        Write-Host "  [注意] config.json 解析失败, 已忽略: $($_.Exception.Message.Split([char]10)[0])" -ForegroundColor Yellow
    }
}
# 兜底默认值(杭州电子科技大学)
if (-not $ProbeDomain) { $ProbeDomain = 'www.hdu.edu.cn' }

# 开机自启用「启动文件夹快捷方式」而不是计划任务:
#   - 计划任务以 SYSTEM 运行时, 非管理员连查询都会被拒绝, 排查困难
#   - 绑定 53 端口本来就不需要管理员权限
#   - 快捷方式直观可见, 用户自己就能删
$STARTUP_DIR   = [Environment]::GetFolderPath('Startup')
$LNK_NAME      = '校园网DNS修复(加密DNS转发).lnk'
$RUN_KEY       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RUN_VALUE     = 'CampusDohRelay'

# 历史遗留(旧版本用过), 安装/恢复时一并清理
$OLD_TASK_NAME = 'CampusDoHRelay'
$OLD_VBS       = Join-Path $RELAY_DIR 'run_relay.vbs'

# ----------------------------------------------------------------- 输出
function Write-Head($t) {
    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
}
function Write-Step($t) { Write-Host "  -  $t" -ForegroundColor Gray }
function Write-Ok($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Warn($t) { Write-Host "  [注意] $t" -ForegroundColor Yellow }
function Write-Err($t)  { Write-Host "  [失败] $t" -ForegroundColor Red }
function Write-Info($t) { Write-Host "         $t" -ForegroundColor DarkGray }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ----------------------------------------------------------------- 网卡检测
# 自动找出承载默认路由的网卡(即真正在上网的那块), 避免硬编码网卡名
function Get-TargetInterface {
    param([string]$Override = '')

    if ($Override) {
        $i = Get-NetAdapter -Name $Override -ErrorAction SilentlyContinue
        if (-not $i) { $i = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*$Override*" } | Select-Object -First 1 }
        if ($i) { return $i }
        Write-Warn "指定的网卡 '$Override' 不存在, 改为自动检测"
    }

    # 1) 有 IPv4 默认路由的网卡(按路由优先级)
    $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
              Sort-Object RouteMetric, InterfaceMetric
    foreach ($r in $routes) {
        $a = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue
        if ($a -and $a.Status -eq 'Up') { return $a }
    }

    # 2) 退路: 任意已连接且非虚拟的网卡
    $a = Get-NetAdapter -ErrorAction SilentlyContinue |
         Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Teredo|Bluetooth|Wi-Fi Direct' } |
         Select-Object -First 1
    return $a
}

# ----------------------------------------------------------------- 工具
function Get-PythonExe {
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cands = @(
        "$env:LOCALAPPDATA\Programs\Python\Python314\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:ProgramFiles\Python314\python.exe",
        "$env:ProgramFiles\Python313\python.exe",
        "$env:ProgramFiles\Python312\python.exe"
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Test-RelayListening([int]$port) {
    [bool](Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue)
}

# 直接用 UDP 报文查询指定端口的 DNS —— Resolve-DnsName 不支持自定义端口
function Invoke-UdpDnsQuery {
    param([string]$Name, [int]$Port = 53, [int]$TimeoutMs = 6000)

    $q = New-Object System.Collections.Generic.List[byte]
    $q.AddRange([byte[]]@(0x12,0x34, 0x01,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00))
    foreach ($lab in $Name.Split('.')) {
        $b = [Text.Encoding]::ASCII.GetBytes($lab)
        $q.Add([byte]$b.Length); $q.AddRange($b)
    }
    $q.AddRange([byte[]]@(0x00, 0x00,0x01, 0x00,0x01))   # 结束 + QTYPE=A + QCLASS=IN

    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect('127.0.0.1', $Port)
        $bytes = $q.ToArray()
        [void]$udp.Send($bytes, $bytes.Length)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        if ($resp.Length -lt 12) { return $null }

        $rcode   = $resp[3] -band 0x0F
        $ancount = ([int]$resp[6] -shl 8) + [int]$resp[7]
        $ips = @()

        # 跳过问题段的 QNAME
        $i = 12
        while ($i -lt $resp.Length -and $resp[$i] -ne 0) {
            if ($resp[$i] -band 0xC0) { $i += 2; break }
            $i += 1 + $resp[$i]
        }
        if ($i -lt $resp.Length -and $resp[$i] -eq 0) { $i += 1 }
        $i += 4    # QTYPE + QCLASS

        # 遍历应答段, 提取 A 记录
        while ($i -gt 0 -and $i -lt ($resp.Length - 12)) {
            if ($resp[$i] -band 0xC0) { $i += 2 }
            else {
                while ($i -lt $resp.Length -and $resp[$i] -ne 0) { $i += 1 + $resp[$i] }
                $i += 1
            }
            if (($i + 10) -gt $resp.Length) { break }
            $t     = ([int]$resp[$i] -shl 8) + [int]$resp[$i+1]
            $rdlen = ([int]$resp[$i+8] -shl 8) + [int]$resp[$i+9]
            $i += 10
            if ($t -eq 1 -and $rdlen -eq 4 -and (($i + 4) -le $resp.Length)) {
                $ips += ("{0}.{1}.{2}.{3}" -f $resp[$i],$resp[$i+1],$resp[$i+2],$resp[$i+3])
            }
            $i += $rdlen
        }

        return [pscustomobject]@{ Rcode = $rcode; Answers = $ancount; IPs = @($ips | Select-Object -Unique) }
    } catch {
        return $null
    } finally { $udp.Close() }
}

function Get-PythonwExe {
    $py = Get-PythonExe
    if (-not $py) { return $null }
    $pyw = Join-Path (Split-Path -Parent $py) 'pythonw.exe'
    if (Test-Path -LiteralPath $pyw) { return $pyw }
    return $py
}

# 在「启动」文件夹创建快捷方式(登录时自动运行, 无需管理员, 用户可见可删)
function New-StartupShortcut {
    param([string]$PythonwExe, [switch]$ShareNet, [string]$Probe = '')

    $target = Join-Path $STARTUP_DIR $LNK_NAME
    if (-not (Test-Path -LiteralPath $STARTUP_DIR)) { New-Item -ItemType Directory -Path $STARTUP_DIR -Force | Out-Null }

    $argLine = "`"$LAUNCHER`""
    if ($ShareNet) { $argLine += ' --share' }
    if ($Probe)    { $argLine += " --probe `"$Probe`"" }

    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($target)
    $lnk.TargetPath       = $PythonwExe
    $lnk.Arguments        = $argLine
    $lnk.WorkingDirectory = $RELAY_DIR
    $lnk.Description      = '校园网加密DNS转发: 修复校内网站打不开'
    $lnk.IconLocation     = "$PythonwExe,0"
    $lnk.Save()
    return $target
}

# 兜底: 注册表 Run 键(快捷方式被误删时仍能自启)
function Set-RunEntry {
    param([string]$PythonwExe, [switch]$ShareNet, [string]$Probe = '')
    $argLine = "`"$LAUNCHER`""
    if ($ShareNet) { $argLine += ' --share' }
    if ($Probe)    { $argLine += " --probe `"$Probe`"" }
    $val = "`"$PythonwExe`" $argLine"
    New-ItemProperty -Path $RUN_KEY -Name $RUN_VALUE -Value $val -PropertyType String -Force | Out-Null
    return $val
}

function Remove-Autostart {
    # 1) 启动文件夹快捷方式
    $lnk = Join-Path $STARTUP_DIR $LNK_NAME
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
    # 2) 注册表 Run 键
    try { Remove-ItemProperty -Path $RUN_KEY -Name $RUN_VALUE -Force -ErrorAction Stop } catch {}
    # 3) 历史遗留的计划任务(旧版本用过 SYSTEM 计划任务)与旧 VBS
    #    注意: 即使任务存在, 非管理员查询也可能报"拒绝访问", 所以这里额外用 schtasks 兜底
    try { Unregister-ScheduledTask -TaskName $OLD_TASK_NAME -Confirm:$false -ErrorAction Stop } catch {}
    try {
        $null = schtasks.exe /query /tn $OLD_TASK_NAME 2>&1
        if ($LASTEXITCODE -eq 0) {
            $null = schtasks.exe /delete /tn $OLD_TASK_NAME /f 2>&1
        }
    } catch {}
    if (Test-Path -LiteralPath $OLD_VBS) { Remove-Item -LiteralPath $OLD_VBS -Force -ErrorAction SilentlyContinue }
}

function Test-Autostart {
    $lnk = Join-Path $STARTUP_DIR $LNK_NAME
    $hasLnk = Test-Path -LiteralPath $lnk
    $hasRun = $false
    try { $hasRun = [bool](Get-ItemProperty -Path $RUN_KEY -Name $RUN_VALUE -ErrorAction Stop) } catch {}
    return [pscustomobject]@{ Shortcut = $hasLnk; RunKey = $hasRun }
}

function Stop-RelayProcess {
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*doh_dns.py*' -or $_.CommandLine -like '*run_relay.py*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

function Show-RelayLog {
    if (Test-Path -LiteralPath $LOG_FILE) {
        Write-Info "服务日志末尾:"
        # 必须指定 -Encoding UTF8, 否则 PowerShell 5.1 按 ANSI 解码导致中文乱码
        Get-Content -LiteralPath $LOG_FILE -Tail 12 -Encoding UTF8 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Info $_ }
    }
}

# ----------------------------------------------------------------- 状态
function Show-Status {
    Write-Head "加密DNS转发 - 当前状态"

    $py = Get-PythonExe
    if ($py) { Write-Ok "Python: $py" } else { Write-Err "未找到 Python" }

    foreach ($p in $PORT, $FALLBACK_PORT) {
        if (Test-RelayListening $p) { Write-Ok "转发服务正在监听 0.0.0.0:$p" }
        else { Write-Step "端口 $p : 未监听" }
    }

    $nic = Get-TargetInterface -Override $InterfaceAlias
    if ($nic) {
        $dns = @()
        try { $dns = (Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).ServerAddresses } catch {}
        Write-Step ("网卡[{0}] DNS: {1}" -f $nic.Name, $(if ($dns) { $dns -join ', ' } else { '(未设置)' }))
        if ($dns -contains '127.0.0.1') { Write-Ok "系统已使用本地加密DNS" }
        else { Write-Warn "系统尚未指向本地加密DNS, 校内域名可能仍解析失败" }
    }

    $as = Test-Autostart
    $parts = @()
    if ($as.Shortcut) { $parts += '启动文件夹快捷方式' }
    if ($as.RunKey)   { $parts += '注册表Run项' }
    if ($parts.Count) { Write-Ok ("开机自启: " + ($parts -join ' + ')) }
    else              { Write-Warn "开机自启: 未配置(重启后需手动启动)" }
    Write-Info ("启动文件夹: " + $STARTUP_DIR)

    Write-Host ""
    Write-Step "实测解析(通过本地服务):"
    $any = $false
    foreach ($p in $PORT, $FALLBACK_PORT) {
        if (Test-RelayListening $p) {
            $any = $true
            $r = Invoke-UdpDnsQuery -Name $ProbeDomain -Port $p
            if ($r -and $r.Answers -gt 0) {
                Write-Ok ("  端口 {0}: {1} -> {2}" -f $p, $ProbeDomain, ($r.IPs -join ', '))
            } elseif ($r) {
                Write-Warn ("  端口 {0}: rcode={1}, 应答数={2}" -f $p, $r.Rcode, $r.Answers)
            } else {
                Write-Err ("  端口 {0}: 无响应" -f $p)
            }
        }
    }
    if (-not $any) { Write-Warn "服务未运行, 无法实测。请先执行 -Action Apply" }
}

# ----------------------------------------------------------------- 安装
function Invoke-Apply {
    if (-not (Test-Admin)) {
        Write-Err "需要管理员权限。请右键『以管理员身份运行』。"
        return 1
    }
    Write-Head "校园网 DNS 修复 - 开始安装"

    # 1. 环境检查
    if (-not (Test-Path -LiteralPath $RELAY_SCRIPT)) { Write-Err "找不到 $RELAY_SCRIPT"; return 1 }
    $py = Get-PythonExe
    if (-not $py) { Write-Err "未找到 Python, 请先安装 Python 3"; return 1 }
    Write-Ok "Python: $py"

    $nic = Get-TargetInterface -Override $InterfaceAlias
    if (-not $nic) { Write-Err "未找到可用网卡"; return 1 }
    Write-Ok "目标网卡: $($nic.Name)  ($($nic.InterfaceDescription))"

    # 2. 清理旧实例与历史遗留
    Write-Step "停止可能存在的旧服务实例..."
    Stop-RelayProcess
    Remove-Autostart          # 同时清掉旧版本留下的 SYSTEM 计划任务

    # 3. 配置开机自启(启动文件夹快捷方式 + 注册表 Run 兜底)
    Write-Step "配置开机自启(启动文件夹快捷方式)..."
    $pyw = Get-PythonwExe
    if (-not $pyw) { Write-Err "未找到 pythonw.exe"; return 1 }
    try {
        $lnk = New-StartupShortcut -PythonwExe $pyw -ShareNet:$Share -Probe $ProbeDomain
        Write-Ok "已创建快捷方式: $lnk"
    } catch {
        Write-Warn "创建快捷方式失败: $($_.Exception.Message.Split([char]10)[0])"
    }
    try {
        [void](Set-RunEntry -PythonwExe $pyw -ShareNet:$Share -Probe $ProbeDomain)
        Write-Ok "已写入注册表自启项(兜底)"
    } catch {
        Write-Warn "写入注册表自启项失败: $($_.Exception.Message.Split([char]10)[0])"
    }
    if (-not (Test-Path -LiteralPath $LAUNCHER)) { Write-Err "找不到 $LAUNCHER"; return 1 }

    # 4. 立即启动服务
    Write-Step "启动转发服务..."
    Start-Process -FilePath $pyw -ArgumentList "`"$LAUNCHER`"" -WorkingDirectory $RELAY_DIR -WindowStyle Hidden
    $up = $false
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 700
        if (Test-RelayListening $PORT) { $up = $true; break }
    }
    if (-not $up) {
        Write-Err "服务未能在 $PORT 端口监听。"
        Show-RelayLog
        Write-Warn "DNS 未被修改, 你的网络保持原样。"
        return 1
    }
    Write-Ok "服务已监听 0.0.0.0:$PORT"

    # 5. 自检 —— 必须通过才动系统 DNS, 避免把网弄断
    Write-Step "自检: 解析校内域名 $ProbeDomain ..."
    $probe = $null
    for ($i = 0; $i -lt 4; $i++) {
        $probe = Invoke-UdpDnsQuery -Name $ProbeDomain -Port $PORT
        if ($probe -and $probe.Answers -gt 0) { break }
        Start-Sleep -Milliseconds 900
    }
    if (-not $probe -or $probe.Answers -eq 0) {
        Write-Err "自检失败: 本地服务无法解析校内域名。"
        Show-RelayLog
        Write-Warn "DNS 未被修改, 你的网络保持原样。"
        return 1
    }
    Write-Ok "解析成功 -> $($probe.IPs -join ', ')"

    # 6. 备份原 DNS 设置
    $old = @()
    try { $old = (Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).ServerAddresses } catch {}
    @(
        "Interface=$($nic.Name)",
        "InterfaceIndex=$($nic.ifIndex)",
        "ServerAddresses=$($old -join ',')",
        "SavedAt=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    ) | Set-Content -LiteralPath $BACKUP_FILE -Encoding UTF8
    Write-Ok "原 DNS 已备份: $(if ($old) { $old -join ', ' } else { '(DHCP自动获取)' })"

    # 7. 切换系统 DNS 到本地服务(IPv4 + IPv6 回环, 覆盖 A 与 AAAA 查询)
    Write-Step "把网卡[$($nic.Name)] DNS 切换为 127.0.0.1 ..."
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @('127.0.0.1','::1')
    Clear-DnsClientCache
    Write-Ok "DNS 已切换"

    # 8. 最终验证
    Write-Head "验证结果"
    Clear-DnsClientCache
    $pass = 0
    # 从 ProbeDomain 推导基础域名, 自动覆盖常见的认证域名
    $baseDomain = $ProbeDomain -replace '^(www|sso|cas|mail|my)\.', ''
    $checkList = @($ProbeDomain, $baseDomain, "sso.$baseDomain", "cas.$baseDomain", 'www.baidu.com') |
                 Select-Object -Unique
    foreach ($d in $checkList) {
        try {
            $r = Resolve-DnsName -Name $d -DnsOnly -QuickTimeout -ErrorAction Stop
            $ips = ($r | Where-Object { $_.IPAddress } | Select-Object -First 2 -ExpandProperty IPAddress) -join ', '
            if ($ips) { Write-Ok ("{0,-20} -> {1}" -f $d, $ips); $pass++ }
            else { Write-Warn ("{0,-20} -> 无 A 记录" -f $d) }
        } catch {
            Write-Err ("{0,-20} -> 解析失败" -f $d)
        }
    }

    Write-Host ""
    if ($pass -ge ($checkList.Count - 1)) {
        Write-Host "  安装完成! 现在打开浏览器访问校内网站验证。" -ForegroundColor Green
    } else {
        Write-Warn "部分域名解析异常, 请查看 $LOG_FILE"
    }
    Write-Host "  撤销全部改动:  双击 Install.cmd 选 2" -ForegroundColor DarkGray
    Write-Host "  查看状态:      .\setup_dns.ps1 -Action Status" -ForegroundColor DarkGray
    Write-Host "  换学校域名:    .\setup_dns.ps1 -Action Apply -ProbeDomain www.你的学校.edu.cn" -ForegroundColor DarkGray
    if ($Share) {
        $lip = ($nic | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Select-Object -First 1).IPAddress
        Write-Host "  手机/平板:     把 DNS 设为 $lip" -ForegroundColor DarkGray
    }
    return 0
}

# ----------------------------------------------------------------- 恢复
function Invoke-Restore {
    if (-not (Test-Admin)) {
        Write-Err "需要管理员权限。请右键『以管理员身份运行』。"
        return 1
    }
    Write-Head "恢复原始网络设置"

    # 1. 删除开机自启(快捷方式 + 注册表项 + 历史计划任务)
    Remove-Autostart
    Write-Ok "开机自启已移除(快捷方式 / 注册表项 / 历史计划任务)"

    # 2. 停止服务
    Stop-RelayProcess
    Write-Ok "转发服务已停止"

    # 3. 还原 DNS
    $nic = Get-TargetInterface -Override $InterfaceAlias
    $done = $false
    if (Test-Path -LiteralPath $BACKUP_FILE) {
        $txt = Get-Content -LiteralPath $BACKUP_FILE -Raw
        if ($txt -match 'ServerAddresses=([^\r\n]*)') {
            $srv = @(($Matches[1].Trim() -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($srv.Count -gt 0 -and $nic) {
                Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $srv
                Write-Ok "已还原备份的 DNS: $($srv -join ', ')"
                $done = $true
            }
        }
    }
    if (-not $done -and $nic) {
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ResetServerAddresses
        Write-Ok "已恢复为自动获取(DHCP 下发的校园 DNS)"
    }
    Clear-DnsClientCache

    Write-Host ""
    Write-Host "  已完全恢复原状。" -ForegroundColor Green
    return 0
}

# ----------------------------------------------------------------- 入口
switch ($Action) {
    'Apply'   { exit (Invoke-Apply) }
    'Restore' { exit (Invoke-Restore) }
    'Status'  { Show-Status; exit 0 }
}
