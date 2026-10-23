<#
    校园网 DNS 修复 - 交互菜单
    ------------------------------------------------------------------
    由 Install.cmd 以管理员身份调用。本文件必须保存为 UTF-8 with BOM,
    否则 Windows PowerShell 5.1 会按 ANSI 读取导致中文乱码/语法错误。
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$DIR       = Split-Path -Parent $MyInvocation.MyCommand.Path
$SETUP     = Join-Path $DIR 'setup_dns.ps1'
$RELAY     = Join-Path $DIR 'doh_dns.py'
$LOG       = Join-Path $DIR 'relay.log'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ==================================================================" -ForegroundColor DarkCyan
    Write-Host "            校园网 DNS 修复工具   (加密 DNS 转发)" -ForegroundColor Cyan
    Write-Host "  ==================================================================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "   现象: 连校园网时, 校内网站(hdu.edu.cn 等)打不开, 换流量/别的" -ForegroundColor Gray
    Write-Host "         WiFi 就正常。" -ForegroundColor Gray
    Write-Host "   原因: 校园网拦截了校内域名的明文 DNS 查询, 域名解析不出来。" -ForegroundColor Gray
    Write-Host "   方案: 本机跑一个加密 DNS(DoH) 转发服务, 绕开拦截。" -ForegroundColor Gray
    Write-Host ""
}

function Show-MenuState {
    $listen53 = [bool](Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue)
    $task     = Get-ScheduledTask -TaskName 'CampusDoHRelay' -ErrorAction SilentlyContinue

    Write-Host "   当前状态: " -NoNewline -ForegroundColor DarkGray
    if ($listen53) { Write-Host "转发服务运行中" -NoNewline -ForegroundColor Green }
    else           { Write-Host "转发服务未运行" -NoNewline -ForegroundColor DarkYellow }
    Write-Host "   |   " -NoNewline -ForegroundColor DarkGray
    if ($task) { Write-Host "已设开机自启" -ForegroundColor Green }
    else       { Write-Host "未设开机自启" -ForegroundColor DarkYellow }
    Write-Host ""
}

function Invoke-Setup {
    param([string]$Action, [switch]$Share)
    if (-not (Test-Path -LiteralPath $SETUP)) {
        Write-Host "  找不到 setup_dns.ps1" -ForegroundColor Red
        return
    }
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SETUP, '-Action', $Action)
    if ($Share) { $psArgs += '-Share' }
    & powershell.exe @psArgs
}

function Show-Log {
    Clear-Host
    Write-Host ""
    Write-Host "  ================ 转发服务日志 (末尾 30 行) ================" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $LOG) {
        Get-Content -LiteralPath $LOG -Tail 30 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "  (暂无日志文件)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  按回车返回菜单..." -ForegroundColor DarkGray
    [void](Read-Host)
}

# ------------------------------------------------------------------ 主循环
if (-not (Test-Admin)) {
    Write-Host ""
    Write-Host "  需要管理员权限。请右键 Install.cmd -> 以管理员身份运行。" -ForegroundColor Red
    Write-Host ""
    [void](Read-Host "  按回车退出")
    exit 1
}

while ($true) {
    Show-Banner
    Show-MenuState

    Write-Host "   [1]  安装并启用修复      (改 DNS, 可随时恢复)" -ForegroundColor White
    Write-Host "   [2]  完全恢复原状        (撤销所有改动)" -ForegroundColor White
    Write-Host "   [3]  查看当前状态与实测解析" -ForegroundColor White
    Write-Host "   [4]  查看服务日志" -ForegroundColor White
    Write-Host "   [5]  安装并允许手机/平板共用 (寝室路由器场景)" -ForegroundColor White
    Write-Host "   [0]  退出" -ForegroundColor White
    Write-Host ""

    $choice = Read-Host "   请选择"
    switch ($choice.Trim()) {
        '1' {
            Clear-Host
            Invoke-Setup -Action Apply
            Write-Host ""
            [void](Read-Host "  按回车返回菜单")
        }
        '2' {
            Clear-Host
            Invoke-Setup -Action Restore
            Write-Host ""
            [void](Read-Host "  按回车返回菜单")
        }
        '3' {
            Clear-Host
            Invoke-Setup -Action Status
            Write-Host ""
            [void](Read-Host "  按回车返回菜单")
        }
        '4' { Show-Log }
        '5' {
            Clear-Host
            Invoke-Setup -Action Apply -Share
            Write-Host ""
            [void](Read-Host "  按回车返回菜单")
        }
        '0' { exit 0 }
        default {
            Write-Host ""
            Write-Host "  无效选择, 请重新输入。" -ForegroundColor Yellow
            Start-Sleep -Milliseconds 900
        }
    }
}
