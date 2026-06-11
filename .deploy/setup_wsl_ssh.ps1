# Windows PowerShell 脚本: 自动配置 WSL Ubuntu SSH 并允许局域网连接
# 请在 Windows 机器上以“管理员身份”运行此脚本。

$ErrorActionPreference = "Stop"

# 1. 检查管理员权限
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "请以管理员权限运行此 PowerShell 窗口！"
    Exit
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "开始配置 WSL Ubuntu 局域网 SSH 访问..." -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 2. 检查 WSL 是否运行
$wslStatus = wsl --list --running
if ($null -eq $wslStatus) {
    Write-Host "正在启动 WSL Ubuntu..." -ForegroundColor Yellow
    wsl -d Ubuntu -e true
}

# 3. 在 WSL 内部安装并配置 SSH
Write-Host "[1/4] 正在 WSL 内部安装 openssh-server 并开启密码登录..." -ForegroundColor Green
$wslCmd = @"
apt-get update && \
apt-get install -y openssh-server && \
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak && \
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
sed -i 's/PasswordAuthentication no/PasswordAuthentication no/' /etc/ssh/sshd_config && \
service ssh restart
"@

try {
    wsl -u root -e bash -c $wslCmd
    Write-Host "WSL 内的 SSH 服务配置成功！" -ForegroundColor Green
} catch {
    Write-Error "配置 WSL 内部 SSH 失败，请检查 WSL 是否正常运行。"
    Exit
}

# 4. 判断系统版本以决定网络模式
# 获取 Windows 主版本号
$osVersion = [System.Environment]::OSVersion.Version
$isWin11 = $osVersion.Build -ge 22000

if ($isWin11) {
    Write-Host "[2/4] 检测到 Windows 11，推荐使用【镜像网络模式】(Mirrored)..." -ForegroundColor Green
    
    # 写入 .wslconfig
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    $configContent = @"
[wsl2]
networkingMode=mirrored
"@
    
    if (Test-Path $wslConfigPath) {
        $existing = Get-Content $wslConfigPath
        if ($existing -notmatch "networkingMode=mirrored") {
            Add-Content -Path $wslConfigPath -Value "`nnetworkingMode=mirrored"
            Write-Host "已向 $wslConfigPath 追加镜像网络配置。" -ForegroundColor Yellow
        } else {
            Write-Host "$wslConfigPath 已配置镜像网络模式。" -ForegroundColor Gray
        }
    } else {
        Set-Content -Path $wslConfigPath -Value $configContent
        Write-Host "已创建 $wslConfigPath 并配置镜像网络模式。" -ForegroundColor Green
    }
    
    # 重启 WSL 使配置生效
    Write-Host "正在重启 WSL 以应用镜像网络配置..." -ForegroundColor Yellow
    wsl --shutdown
    Start-Sleep -Seconds 3
    wsl -d Ubuntu -e service ssh start
    
    # 开放 Windows 防火墙 22 端口
    Write-Host "[3/4] 开放 Windows 防火墙 22 端口..." -ForegroundColor Green
    Remove-NetFirewallRule -DisplayName "WSL2 SSH Access" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "WSL2 SSH Access" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22
    
    # 获取本机局域网 IP
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "172.*" -and $_.InterfaceAlias -notlike "*Loopback*" }).IPAddress | Select-Object -First 1
    
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "配置完成！【镜像网络模式】已启用。" -ForegroundColor Gold
    Write-Host "现在您可以在局域网的其他电脑上连接了：" -ForegroundColor Gold
    Write-Host "命令: ssh yeeco@$ip -p 22" -ForegroundColor Yellow
    Write-Host "==============================================" -ForegroundColor Cyan

} else {
    Write-Host "[2/4] 检测到 Windows 10，使用【端口转发模式】(Port Proxy)..." -ForegroundColor Green
    
    # 获取 WSL 的内部 IP
    $wslIp = wsl -u root -e hostname -I
    $wslIp = $wslIp.Trim().Split(' ')[0]
    
    if (-not $wslIp) {
        Write-Error "无法获取 WSL IP 地址。"
        Exit
    }
    Write-Host "WSL 内部 IP 为: $wslIp" -ForegroundColor Gray
    
    # 设置端口转发：将 Windows 端口 2222 转发到 WSL 端口 22
    Write-Host "设置端口代理: Windows:2222 -> WSL:$wslIp:22" -ForegroundColor Yellow
    netsh interface portproxy delete v4tov4 listenport=2222 listenaddress=0.0.0.0 | Out-Null
    netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=22 connectaddress=$wslIp
    
    # 开放 Windows 防火墙 2222 端口
    Write-Host "[3/4] 开放 Windows 防火墙 2222 端口..." -ForegroundColor Green
    Remove-NetFirewallRule -DisplayName "WSL2 SSH Proxy" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "WSL2 SSH Proxy" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2222
    
    # 获取 Windows 局域网 IP
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "172.*" -and $_.InterfaceAlias -notlike "*Loopback*" }).IPAddress | Select-Object -First 1
    
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "配置完成！【端口转发模式】已启用。" -ForegroundColor Gold
    Write-Host "注意：如果 Windows 重启，WSL 的内部 IP 可能会变。您需要重新运行此脚本来更新端口转发。" -ForegroundColor Yellow
    Write-Host "现在您可以在局域网的其他电脑上连接了：" -ForegroundColor Gold
    Write-Host "命令: ssh yeeco@$ip -p 2222" -ForegroundColor Yellow
    Write-Host "==============================================" -ForegroundColor Cyan
}
