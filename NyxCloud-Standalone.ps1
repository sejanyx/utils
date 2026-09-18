

$WallpaperUrls = @(
    'https://raw.githubusercontent.com/sejanyx/utils/refs/heads/main/a.png',
    'https://raw.githubusercontent.com/sejanyx/utils/refs/heads/main/b.png',
    'https://raw.githubusercontent.com/sejanyx/utils/refs/heads/main/c.png',
    'https://raw.githubusercontent.com/sejanyx/utils/refs/heads/main/d.png',
    'https://raw.githubusercontent.com/sejanyx/utils/refs/heads/main/f.png',
    'https://raw.githubusercontent.com/sejanyx/utils/refs/heads/main/g.png',
    'https://raw.githubusercontent.com/sejanyx/utils/refs/heads/main/h.png'
)
$SkipTailscaleEnrollment = $false
$SkipRestart = $false

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Version = '0.4.2-standalone'
$LocalUserName = 'nyx'
$LocalUserPassword = 'nyxcloud'
$ApolloDisplayName = 'nyxcloud'
$ApolloUsername = 'nyx'
$ApolloPassword = 'nyxcloud'
$script:TailscaleHostname = $null
$script:TailscaleSecureKey = $null

$NyxRoot = Join-Path $env:ProgramData 'Nyx'
$LogRoot = Join-Path $NyxRoot 'Logs'
$ToolRoot = Join-Path $NyxRoot 'Tools'
$WallpaperRoot = Join-Path $NyxRoot 'Wallpapers'
$UserStateRoot = Join-Path $NyxRoot 'UserState'
$StatePath = Join-Path $NyxRoot 'provisioning-state.json'
$LogPath = Join-Path $LogRoot 'provisioning.log'

function Initialize-NyxDirectories {
    foreach ($path in @($NyxRoot, $LogRoot, $ToolRoot, $WallpaperRoot, $UserStateRoot)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
}

function Write-NyxLog {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
    )
    $line = '{0:o} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Set-NyxState {
    param(
        [Parameter(Mandatory)] [string]$Status,
        [string]$Detail
    )
    [ordered]@{
        schemaVersion = 1
        provisionerVersion = $Version
        status = $Status
        detail = $Detail
        computerName = $env:COMPUTERNAME
        localUser = $LocalUserName
        apolloDisplayName = $ApolloDisplayName
        tailscaleHostname = $script:TailscaleHostname
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Assert-Environment {
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw 'PowerShell 5.1 ou superior é necessário.'
    }

    if (-not [Environment]::Is64BitProcess) {
        throw 'Abra o PowerShell 64-bit como Administrador e execute o script novamente.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Este script precisa ser executado em um PowerShell elevado (Executar como administrador).'
    }

    $script:Winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
    if (-not $script:Winget) {
        throw 'WinGet não foi encontrado. Instale/atualize o App Installer da Microsoft antes de executar este script.'
    }

}

function Ensure-NyxUser {
    $securePassword = ConvertTo-SecureString -String $LocalUserPassword -AsPlainText -Force
    $user = Get-LocalUser -Name $LocalUserName -ErrorAction SilentlyContinue

    if (-not $user) {
        New-LocalUser `
            -Name $LocalUserName `
            -Password $securePassword `
            -AccountNeverExpires `
            -PasswordNeverExpires `
            -UserMayNotChangePassword `
            -Description 'Nyx Cloud Gaming' | Out-Null
        Write-NyxLog 'Usuário local nyx criado.'
    }
    else {
        if (-not $user.Enabled) {
            Enable-LocalUser -Name $LocalUserName
        }
        Set-LocalUser -Name $LocalUserName -Password $securePassword -PasswordNeverExpires $true
        Write-NyxLog 'Usuário local nyx já existia; senha e estado foram normalizados.'
    }

    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    Add-LocalGroupMember -Group $admins.Name -Member $LocalUserName -ErrorAction SilentlyContinue
    Write-NyxLog 'Usuário nyx confirmado como administrador local.'
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)] [string]$Id,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string[]]$DetectionPaths
    )

    if ($DetectionPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) {
        Write-NyxLog "$Name já está instalado."
        return
    }

    Write-NyxLog "Instalando $Name via WinGet..."
    $args = @(
        'install', '--id', $Id, '--exact', '--silent',
        '--accept-source-agreements', '--accept-package-agreements',
        '--disable-interactivity', '--source', 'winget'
    )
    $process = Start-Process -FilePath $script:Winget -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "$Name falhou no WinGet com exit code $($process.ExitCode)."
    }

    Start-Sleep -Seconds 2
    if (-not ($DetectionPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) {
        throw "$Name terminou a instalação, mas o executável esperado não foi encontrado."
    }
    Write-NyxLog "$Name instalado."
}

function Install-Applications {
    Install-WingetPackage -Id 'Valve.Steam' -Name 'Steam' -DetectionPaths @(
        (Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe')
    )

    Install-WingetPackage -Id 'Brave.Brave' -Name 'Brave' -DetectionPaths @(
        (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'BraveSoftware\Brave-Browser\Application\brave.exe')
    )

    Install-WingetPackage -Id 'Tailscale.Tailscale' -Name 'Tailscale' -DetectionPaths @(
        (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe')
    )

    Install-WingetPackage -Id 'ClassicOldSong.Apollo' -Name 'Apollo' -DetectionPaths @(
        (Join-Path $env:ProgramFiles 'Apollo\sunshine.exe')
    )
}

function Install-AndConfigureAutologon {
    $zipPath = Join-Path $ToolRoot 'Autologon.zip'
    $extractPath = Join-Path $ToolRoot 'Autologon'
    $exePath = Join-Path $extractPath 'Autologon64.exe'

    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        Write-NyxLog 'Baixando Sysinternals Autologon...'
        Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/AutoLogon.zip' -OutFile $zipPath -UseBasicParsing
        Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    }

    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw 'Autologon64.exe não foi encontrado após a extração.'
    }

    $signature = Get-AuthenticodeSignature -FilePath $exePath
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
        throw 'Assinatura do Sysinternals Autologon inválida ou inesperada.'
    }

    $process = Start-Process -FilePath $exePath -ArgumentList @(
        $LocalUserName,
        $env:COMPUTERNAME,
        $LocalUserPassword,
        '/accepteula'
    ) -Wait -PassThru -WindowStyle Hidden

    if ($process.ExitCode -ne 0) {
        throw "Sysinternals Autologon falhou com exit code $($process.ExitCode)."
    }
    Write-NyxLog 'Autologon do usuário nyx configurado por segredo LSA.'
}

function Set-SystemBrandingAndLogon {
    $oemPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'
    New-Item -Path $oemPath -Force | Out-Null
    Set-ItemProperty -Path $oemPath -Name 'Model' -Value 'Nyx cloud' -Force

    $systemPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    New-Item -Path $systemPolicy -Force | Out-Null
    New-ItemProperty -Path $systemPolicy -Name 'dontdisplaylastusername' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $systemPolicy -Name 'DontDisplayLockedUserId' -PropertyType DWord -Value 3 -Force | Out-Null
    New-ItemProperty -Path $systemPolicy -Name 'HideFastUserSwitching' -PropertyType DWord -Value 1 -Force | Out-Null

    $shellPath = Join-Path $env:SystemDrive 'Users\Default\AppData\Local\Microsoft\Windows\Shell'
    New-Item -Path $shellPath -ItemType Directory -Force | Out-Null
    $layoutPath = Join-Path $shellPath 'LayoutModification.xml'
@'
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList />
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
'@ | Set-Content -LiteralPath $layoutPath -Encoding UTF8
}

function Download-Wallpapers {
    if (-not $WallpaperUrls -or $WallpaperUrls.Count -eq 0) {
        Write-NyxLog 'Nenhum wallpaper configurado; etapa ignorada.' 'WARN'
        return
    }

    $downloaded = 0
    foreach ($url in $WallpaperUrls) {
        $destination = $null
        try {
            $uri = [Uri]$url
            $fileName = [IO.Path]::GetFileName($uri.AbsolutePath)
            if (-not $fileName) {
                throw 'URL de wallpaper sem nome de arquivo válido'
            }

            $destination = Join-Path $WallpaperRoot $fileName
            Write-NyxLog "Baixando wallpaper $fileName..."
            Invoke-WebRequest -Uri $url -OutFile $destination -UseBasicParsing
            if ((Get-Item -LiteralPath $destination).Length -lt 1024) {
                throw 'arquivo recebido é pequeno demais para ser o wallpaper esperado'
            }
            $downloaded++
        }
        catch {
            if ($destination) {
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            }
            Write-NyxLog "Falha ao baixar wallpaper $url : $($_.Exception.Message)" 'WARN'
        }
    }

    if ($downloaded -eq 0) {
        Write-NyxLog 'Nenhum wallpaper pôde ser baixado.' 'WARN'
    }
    else {
        Write-NyxLog "$downloaded wallpaper(s) preparado(s)."
    }
}

function Configure-Apollo {
    $apolloExecutable = Join-Path $env:ProgramFiles 'Apollo\sunshine.exe'
    $configPath = Join-Path $env:ProgramFiles 'Apollo\config\sunshine.conf'
    if (-not (Test-Path -LiteralPath $apolloExecutable -PathType Leaf)) {
        throw 'Apollo não foi encontrado após a instalação.'
    }

    $apolloServices = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -match '\\Apollo\\sunshine\.exe' })
    foreach ($service in $apolloServices) {
        if ($service.State -eq 'Running') {
            Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
        }
    }

    $configDir = Split-Path -Parent $configPath
    New-Item -Path $configDir -ItemType Directory -Force | Out-Null

    $existing = if (Test-Path -LiteralPath $configPath) { @(Get-Content -LiteralPath $configPath) } else { @() }
    $managed = [ordered]@{
        sunshine_name = $ApolloDisplayName
        upnp = 'disabled'
        headless_mode = 'enabled'
        origin_web_ui_allowed = 'wan'
    }
    $remaining = @($existing | Where-Object {
        $line = $_
        -not ($managed.Keys | Where-Object { $line -match "^\s*$([regex]::Escape($_))\s*=" })
    })
    $configLines = @($remaining) + @($managed.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" })
    $configLines | Set-Content -LiteralPath $configPath -Encoding UTF8

    & $apolloExecutable --creds $ApolloUsername $ApolloPassword *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'Não foi possível configurar as credenciais do Apollo.'
    }

    foreach ($service in $apolloServices) {
        Set-Service -Name $service.Name -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $service.Name -ErrorAction SilentlyContinue
    }
    Write-NyxLog 'Apollo configurado como nyxcloud com credenciais nyx / nyxcloud.'
}

function Read-TailscaleEnrollmentInput {
    do {
        $hostnameInput = (Read-Host 'Tailscale hostname').Trim()
        if (-not $hostnameInput) {
            $hostnameInput = $env:COMPUTERNAME.ToLowerInvariant()
        }
        if ($hostnameInput -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') {
            Write-Host 'Hostname inválido. Use apenas letras, números e hífen.' -ForegroundColor Yellow
            $hostnameInput = $null
        }
    } while (-not $hostnameInput)

    $script:TailscaleHostname = $hostnameInput.ToLowerInvariant()
    $script:TailscaleSecureKey = Read-Host 'Tailscale auth key' -AsSecureString
    if ($script:TailscaleSecureKey.Length -eq 0) {
        throw 'A auth key do Tailscale não pode ficar vazia.'
    }
}

function Connect-Tailscale {
    if ($SkipTailscaleEnrollment) {
        Write-NyxLog 'Registro do Tailscale ignorado.' 'WARN'
        return
    }

    $tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path -LiteralPath $tailscale -PathType Leaf)) {
        throw 'Tailscale não foi encontrado após a instalação.'
    }

    $registered = $false
    try {
        $statusJson = & $tailscale status --json 2>$null
        if ($LASTEXITCODE -eq 0 -and $statusJson) {
            $status = $statusJson | ConvertFrom-Json
            $registered = $status.BackendState -eq 'Running'
        }
    }
    catch {
        $registered = $false
    }

    if ($registered) {
        & $tailscale set "--hostname=$script:TailscaleHostname" *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'Não foi possível atualizar o hostname do Tailscale.'
        }
        $script:TailscaleSecureKey = $null
        Write-NyxLog 'Tailscale já estava registrado; hostname atualizado.'
        return
    }

    if (-not $script:TailscaleSecureKey -or $script:TailscaleSecureKey.Length -eq 0) {
        throw 'A auth key do Tailscale não foi informada.'
    }

    $keyFile = Join-Path $env:TEMP ("nyx-ts-{0}.key" -f ([guid]::NewGuid().ToString('N')))
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:TailscaleSecureKey)
        $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        Set-Content -LiteralPath $keyFile -Value $plainKey -NoNewline -Encoding Ascii
        Remove-Variable plainKey -ErrorAction SilentlyContinue

        & $tailscale up "--auth-key=file:$keyFile" "--hostname=$script:TailscaleHostname" '--unattended=true' '--accept-routes=false' *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'Falha ao registrar a máquina no Tailscale.'
        }
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $script:TailscaleSecureKey = $null
        Remove-Item -LiteralPath $keyFile -Force -ErrorAction SilentlyContinue
    }

    Write-NyxLog 'Tailscale registrado e configurado em modo unattended.'
}

function Register-NyxUserConfiguration {
    $configScript = Join-Path $NyxRoot 'Configure-NyxUser.ps1'
    $cleanupScript = Join-Path $NyxRoot 'Cleanup-NyxUserTask.ps1'
    $markerPath = Join-Path $UserStateRoot 'user-profile-ready.json'

    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue

@'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedUser = 'nyx'
if ($env:USERNAME -ine $expectedUser) { exit 0 }

$nyxRoot = Join-Path $env:ProgramData 'Nyx'
$wallpaperRoot = Join-Path $nyxRoot 'Wallpapers'
$userStateRoot = Join-Path $nyxRoot 'UserState'
$markerPath = Join-Path $userStateRoot 'user-profile-ready.json'
$logPath = Join-Path $userStateRoot 'user-configuration.log'

function Write-UserLog([string]$Message) {
    Add-Content -LiteralPath $logPath -Value ('{0:o} {1}' -f (Get-Date), $Message) -Encoding UTF8
}

try {
    $wallpaperName = $null
    $sourceWallpapers = @()
    if (Test-Path -LiteralPath $wallpaperRoot -PathType Container) {
        $sourceWallpapers = @(Get-ChildItem -LiteralPath $wallpaperRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.png','.jpg','.jpeg','.bmp') })
    }

    if ($sourceWallpapers.Count -gt 0) {
        $pictures = [Environment]::GetFolderPath('MyPictures')
        if (-not $pictures) { $pictures = Join-Path $env:USERPROFILE 'Pictures' }
        $wallpaperDir = Join-Path $pictures 'Nyx Wallpapers'
        New-Item -Path $wallpaperDir -ItemType Directory -Force | Out-Null

        foreach ($source in $sourceWallpapers) {
            Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $wallpaperDir $source.Name) -Force
        }

        $selected = $sourceWallpapers | Get-Random
        $userWallpaper = Join-Path $wallpaperDir $selected.Name

        $desktopKey = 'HKCU:\Control Panel\Desktop'
        Set-ItemProperty -Path $desktopKey -Name WallpaperStyle -Value '10'
        Set-ItemProperty -Path $desktopKey -Name TileWallpaper -Value '0'

        Add-Type @"
using System.Runtime.InteropServices;
public static class NyxWallpaper {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfo(int action, int param, string value, int flags);
}
"@
        if (-not [NyxWallpaper]::SystemParametersInfo(20, 0, $userWallpaper, 3)) {
            throw 'O Windows não aceitou o wallpaper.'
        }
        $wallpaperName = $selected.Name
    }
    else {
        Write-UserLog 'Nenhum wallpaper foi encontrado; personalização continuará sem ele.'
    }

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop -and (Test-Path -LiteralPath $desktop)) {
        Get-ChildItem -LiteralPath $desktop -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.lnk','.url') } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $layoutRoot = Join-Path $env:LOCALAPPDATA 'Nyx'
    New-Item -Path $layoutRoot -ItemType Directory -Force | Out-Null
    $layoutPath = Join-Path $layoutRoot 'taskbar-layout.xml'
@"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList />
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@ | Set-Content -LiteralPath $layoutPath -Encoding UTF8

    $explorerPolicy = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
    New-Item -Path $explorerPolicy -Force | Out-Null
    New-ItemProperty -Path $explorerPolicy -Name 'StartLayoutFile' -PropertyType String -Value $layoutPath -Force | Out-Null

    [ordered]@{
        status = 'READY'
        wallpaper = $wallpaperName
        configuredAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding UTF8

    Write-UserLog 'Perfil nyx configurado.'
    exit 0
}
catch {
    Write-UserLog "Falha: $($_.Exception.Message)"
    exit 1
}
'@ | Set-Content -LiteralPath $configScript -Encoding UTF8

@'
$markerPath = Join-Path $env:ProgramData 'Nyx\UserState\user-profile-ready.json'
if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { exit 0 }
try {
    $state = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ($state.status -ne 'READY') { exit 0 }
    Unregister-ScheduledTask -TaskName 'Nyx-ConfigureUser' -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'Nyx-CleanupUserTask' -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}
catch { exit 1 }
'@ | Set-Content -LiteralPath $cleanupScript -Encoding UTF8

    $user = Get-LocalUser -Name $LocalUserName
    & icacls.exe $UserStateRoot /grant "*$($user.SID.Value):(OI)(CI)M" /T /C /Q | Out-Null

    $userAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$configScript`""
    $userTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user.SID.Value
    $userPrincipal = New-ScheduledTaskPrincipal -UserId $user.SID.Value -LogonType Interactive -RunLevel Limited
    $userSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable
    Register-ScheduledTask -TaskName 'Nyx-ConfigureUser' -Action $userAction -Trigger $userTrigger -Principal $userPrincipal -Settings $userSettings -Force | Out-Null

    $cleanupAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$cleanupScript`""
    $cleanupTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user.SID.Value
    $cleanupTrigger.Delay = 'PT2M'
    $cleanupPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $cleanupSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
    Register-ScheduledTask -TaskName 'Nyx-CleanupUserTask' -Action $cleanupAction -Trigger $cleanupTrigger -Principal $cleanupPrincipal -Settings $cleanupSettings -Force | Out-Null

    Write-NyxLog 'Personalização do primeiro logon do nyx registrada.'
}

function Clear-PublicDesktopShortcuts {
    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if ($publicDesktop -and (Test-Path -LiteralPath $publicDesktop)) {
        Get-ChildItem -LiteralPath $publicDesktop -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.lnk','.url') } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

Initialize-NyxDirectories

try {
    Set-NyxState -Status 'BOOTSTRAP_STARTED'
    Write-NyxLog "Nyx Cloud standalone $Version iniciado."

    Assert-Environment
    Read-TailscaleEnrollmentInput
    Set-SystemBrandingAndLogon
    Ensure-NyxUser
    Download-Wallpapers
    Install-AndConfigureAutologon

    Install-Applications
    Set-NyxState -Status 'SOFTWARE_INSTALLED'

    Configure-Apollo
    Connect-Tailscale
    Register-NyxUserConfiguration
    Clear-PublicDesktopShortcuts

    Set-NyxState -Status 'AWAITING_USER_PROFILE'
    Write-NyxLog 'Etapa administrativa concluída. O usuário nyx será configurado no próximo logon.'

    if (-not $SkipRestart) {
        Write-NyxLog 'Reiniciando a máquina em 30 segundos.'
        shutdown.exe /r /t 30 /c 'Provisionamento Nyx concluído. Reiniciando para finalizar o perfil.' /d p:4:1 | Out-Null
    }
    else {
        Write-NyxLog 'Reinício automático ignorado por -SkipRestart.' 'WARN'
    }

    Write-Host ''
    Write-Host 'Nyx Cloud: etapa administrativa concluída.'
    Write-Host 'Usuário local: nyx'
    Write-Host 'Senha: nyxcloud'
    if ($SkipRestart) {
        Write-Host 'Reinicie a máquina manualmente para concluir o autologon e o wallpaper.'
    }
    exit 0
}
catch {
    $script:TailscaleSecureKey = $null
    $safeMessage = $_.Exception.Message -replace 'tskey-[A-Za-z0-9_-]+', '[REDACTED]'
    try { Set-NyxState -Status 'FAILED' -Detail $safeMessage } catch {}
    try { Write-NyxLog $safeMessage 'ERROR' } catch { Write-Error $safeMessage }
    exit 1
}
