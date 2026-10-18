<#
    TweakHub - Windows gaming tweaks and debloat in one window.
    Pick a strength (Light / Balanced / Max) or tick items yourself, then press Run Tweaks.
    Every registry, service, task, power and network change is backed up and can be undone.

    One-line start (any PowerShell window):
        irm https://raw.githubusercontent.com/NRBalpha/tweakhub/main/TweakHub.ps1 | iex
    Or double-click TweakHub.bat.

    Test switches (no admin, nothing is changed):
        -DryRun            log what would happen instead of changing anything
        -Snapshot <png>    render the window to an image and exit
#>
param(
    [switch]$DryRun,
    [string]$Snapshot,
    [switch]$SelfTest,  # dry run: tick everything, apply then undo, then close
    [string]$FakeBrand, # testing only: pretend to be another laptop brand
    [string]$StartTab   # testing only: open on this tab
)

$ErrorActionPreference = 'Continue'
$AppName = 'TweakHub'
$AppVersion = '1.1'

# ---------------------------------------------------------------- startup checks
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Snapshot -or $SelfTest) { $DryRun = $true }

# Where the one-line installer downloads TweakHub from. Change this if the GitHub repo moves.
$RawUrl = 'https://raw.githubusercontent.com/NRBalpha/tweakhub/main/TweakHub.ps1'

if (-not $PSCommandPath -and -not $isAdmin -and -not $DryRun) {
    # Started with "irm <url> | iex" in a normal window: reopen the same one-liner as administrator.
    try {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm '$RawUrl' | iex`""
        Write-Host 'TweakHub is opening in a new window.' -ForegroundColor Cyan
    } catch { Write-Host 'TweakHub needs administrator rights. Click Yes on the prompt, or open PowerShell as administrator.' -ForegroundColor Red }
    return
}

$wrongHost = ($PSVersionTable.PSVersion.Major -ge 6) -or ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA')
if ((-not $isAdmin -and -not $DryRun) -or $wrongHost) {
    # Relaunch in Windows PowerShell 5.1 (STA, needed for the window), as administrator unless this is a dry run.
    if ($PSCommandPath) {
        $argList = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($DryRun) { $argList += ' -DryRun' }
    } else { $argList = "-NoProfile -STA -ExecutionPolicy Bypass -Command `"irm '$RawUrl' | iex`"" }
    try {
        if ($DryRun) { Start-Process powershell.exe -ArgumentList $argList }
        else { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $argList }
    } catch { Write-Host 'TweakHub needs administrator rights. Click Yes on the prompt, or run PowerShell as administrator.' -ForegroundColor Red; Start-Sleep 6 }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

if ($DryRun) { $DataDir = Join-Path $env:TEMP "$AppName-dryrun" } else { $DataDir = Join-Path $env:ProgramData $AppName }
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$BackupFile = Join-Path $DataDir 'backup.json'
$LogFile = Join-Path $DataDir ('log-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
$Inv = [Globalization.CultureInfo]::InvariantCulture

if (-not ('TweakHubNative11' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TweakHubNative11 {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint action, uint uiParam, int[] pvParam, uint winIni);
    [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfo")]
    public static extern bool SystemParametersInfoPtr(uint action, uint uiParam, IntPtr pvParam, uint winIni);
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
'@
}

# ---------------------------------------------------------------- logging + UI pump
$script:Window = $null
$script:LogBox = $null
$script:Running = $false

function Update-UI {
    if ($script:Window) {
        $script:Window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Background)
    }
}

function Log([string]$Message, [string]$Level = 'info') {
    $prefix = switch ($Level) { 'warn' { '! ' } 'error' { 'X ' } default { '' } }
    $line = '[{0:HH:mm:ss}] {1}{2}' -f (Get-Date), $prefix, $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop } catch {}
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + "`r`n")
        $script:LogBox.ScrollToEnd()
        Update-UI
    } else { Write-Host $line }
}

# ---------------------------------------------------------------- backup store
# Backup layout: tweak id -> list of "original value" entries, recorded the first time a value is touched.
$script:Backup = @{}
$script:CurrentId = $null
$script:NicsToRestart = @{}

function Import-Backup {
    if (-not (Test-Path $BackupFile)) { return }
    try {
        $obj = Get-Content -LiteralPath $BackupFile -Raw | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) {
            $list = New-Object System.Collections.ArrayList
            foreach ($e in @($p.Value)) {
                $h = @{}
                foreach ($q in $e.PSObject.Properties) { $h[$q.Name] = $q.Value }
                [void]$list.Add($h)
            }
            $script:Backup[$p.Name] = $list
        }
    } catch { Log "Could not read the backup file: $($_.Exception.Message)" 'warn' }
}

function Save-Backup {
    try { $script:Backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackupFile -Encoding UTF8 }
    catch { Log "Could not write the backup file: $($_.Exception.Message)" 'warn' }
}

function Save-Original([hashtable]$Entry) {
    $id = $script:CurrentId
    if (-not $id) { return }
    if (-not $script:Backup.ContainsKey($id)) { $script:Backup[$id] = New-Object System.Collections.ArrayList }
    foreach ($e in $script:Backup[$id]) { if ($e.key -eq $Entry.key) { return } }   # keep the very first original
    [void]$script:Backup[$id].Add($Entry)
}

# ---------------------------------------------------------------- change helpers (all record originals)
function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    $orig = @{ kind = 'reg'; key = "reg|$Path|$Name"; path = $Path; name = $Name; existed = $false }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        if ($item.GetValueNames() -contains $Name) {
            $orig.existed = $true
            $orig.type = $item.GetValueKind($Name).ToString()
            $orig.value = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        }
    }
    Save-Original $orig
    if ($DryRun) { Log "   [dry] $Path\$Name = $Value"; return }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    } catch { Log "   could not set $Path\$Name ($($_.Exception.Message))" 'warn' }
}

function Set-Policies([string]$Path, [hashtable]$Values) {
    foreach ($k in ($Values.Keys | Sort-Object)) { Set-Reg $Path $k $Values[$k] }
}

function Invoke-Cmd([string]$Exe, [string[]]$Arguments) {
    Log "   > $Exe $($Arguments -join ' ')"
    if ($DryRun) { return }
    $out = & $Exe @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and $out.Trim()) { Log "     $($out.Trim())" 'warn' }
}

function Set-Svc([string]$Name, [string]$Start) {
    # $Start is an sc.exe value: disabled | demand | auto
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Log "   service $Name not on this PC, skipped"; return }
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    $startVal = (Get-ItemProperty -LiteralPath $k -Name Start -ErrorAction SilentlyContinue).Start
    $delayed = (Get-ItemProperty -LiteralPath $k -Name DelayedAutostart -ErrorAction SilentlyContinue).DelayedAutostart
    $orig = switch ($startVal) { 2 { if ($delayed -eq 1) { 'delayed-auto' } else { 'auto' } } 3 { 'demand' } 4 { 'disabled' } default { 'demand' } }
    Save-Original @{ kind = 'svc'; key = "svc|$Name"; name = $Name; start = $orig }
    Log "   service $Name -> $Start"
    if ($DryRun) { return }
    $out = & sc.exe config $Name start= $Start 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Log "   could not change $Name ($($out.Trim()))" 'warn' }
    if ($Start -eq 'disabled') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
}

function Set-TaskOff([string]$TaskPath, [string]$TaskName) {
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return }
    Save-Original @{ kind = 'task'; key = "task|$TaskPath$TaskName"; path = $TaskPath; name = $TaskName; enabled = ($t.State -ne 'Disabled') }
    Log "   task $TaskPath$TaskName -> disabled"
    if ($DryRun) { return }
    try { Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null }
    catch { Log "   could not disable task $TaskName ($($_.Exception.Message))" 'warn' }
}

function Get-PowerIndex([string]$Sub, [string]$Setting) {
    $o = powercfg /q SCHEME_CURRENT $Sub $Setting 2>$null | Out-String
    $m = [regex]::Matches($o, '0x([0-9a-fA-F]{8})')
    if ($m.Count -lt 2) { return $null }
    return @([Convert]::ToInt32($m[$m.Count - 2].Groups[1].Value, 16), [Convert]::ToInt32($m[$m.Count - 1].Groups[1].Value, 16))
}

function Set-PowerValue([string]$Sub, [string]$Setting, [int]$Ac, [int]$Dc = -1) {
    if (-not $DryRun) { powercfg -attributes $Sub $Setting -ATTRIB_HIDE 2>$null | Out-Null }
    $cur = Get-PowerIndex $Sub $Setting
    if ($null -eq $cur) { Log "   power setting $Setting not available on this PC, skipped"; return }
    Save-Original @{ kind = 'power'; key = "power|$Sub|$Setting"; sub = $Sub; setting = $Setting; ac = $cur[0]; dc = $cur[1] }
    Invoke-Cmd 'powercfg' @('/setacvalueindex', 'SCHEME_CURRENT', $Sub, $Setting, "$Ac")
    if ($Dc -ge 0) { Invoke-Cmd 'powercfg' @('/setdcvalueindex', 'SCHEME_CURRENT', $Sub, $Setting, "$Dc") }
    Invoke-Cmd 'powercfg' @('/setactive', 'SCHEME_CURRENT')
}

function Get-ActiveScheme {
    $o = powercfg /getactivescheme | Out-String
    if ($o -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $matches[1] }
    return $null
}

function Get-PhysicalNics([string]$Kind = 'all') {
    $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    switch ($Kind) {
        'wifi' { return @($nics | Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' }) }
        'ethernet' { return @($nics | Where-Object { $_.PhysicalMediaType -match '802\.3' -and $_.InterfaceDescription -notmatch 'Wi-?Fi|Wireless|WLAN' }) }
        default { return $nics }
    }
}

# Sets every advanced driver property whose name matches $NamePattern to the first allowed value matching $Prefer.
# Property names differ per vendor (Intel, Realtek, MediaTek, Qualcomm/Killer, Broadcom), so patterns list all known spellings.
function Set-NicProp($Adapter, [string]$NamePattern, [string[]]$Prefer) {
    $props = @(Get-NetAdapterAdvancedProperty -Name $Adapter.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $NamePattern })
    foreach ($p in $props) {
        if (-not $p.ValidDisplayValues) { continue }
        $target = $null
        foreach ($rx in $Prefer) {
            $target = $p.ValidDisplayValues | Where-Object { $_ -match $rx } | Select-Object -First 1
            if ($target) { break }
        }
        if (-not $target) { continue }
        if ($p.DisplayValue -eq $target) { Log "   $($Adapter.Name): $($p.DisplayName) already '$target'"; continue }
        Save-Original @{ kind = 'nic'; key = "nic|$($Adapter.InterfaceDescription)|$($p.RegistryKeyword)"; adapter = $Adapter.Name
            keyword = $p.RegistryKeyword; value = @($p.RegistryValue); display = $p.DisplayValue }
        Log "   $($Adapter.Name): $($p.DisplayName) '$($p.DisplayValue)' -> '$target'"
        if ($DryRun) { continue }
        try {
            Set-NetAdapterAdvancedProperty -Name $Adapter.Name -RegistryKeyword $p.RegistryKeyword -DisplayValue $target -NoRestart -ErrorAction Stop
            $script:NicsToRestart[$Adapter.Name] = $true
        } catch { Log "   could not set $($p.DisplayName) ($($_.Exception.Message))" 'warn' }
    }
}

function Disable-DevicePowerOff([string[]]$InstanceIds) {
    # Unticks "Allow the computer to turn off this device to save power".
    $all = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue)
    $n = 0
    foreach ($w in $all) {
        foreach ($id in $InstanceIds) {
            if ($w.InstanceName -like ([Management.Automation.WildcardPattern]::Escape($id) + '*')) {
                if ($w.Enable) {
                    Save-Original @{ kind = 'devpower'; key = "devpower|$($w.InstanceName)"; instance = $w.InstanceName }
                    if (-not $DryRun) { Set-CimInstance -InputObject $w -Property @{ Enable = $false } -ErrorAction SilentlyContinue }
                    $n++
                }
                break
            }
        }
    }
    Log "   'allow turn off to save power' unticked on $n device(s)"
}

function Remove-App([string]$Pattern) {
    $pk = @()
    try { $pk = @(Get-AppxPackage -AllUsers -Name $Pattern -ErrorAction Stop) } catch {}
    if (-not $pk) { try { $pk = @(Get-AppxPackage -Name $Pattern -ErrorAction Stop) } catch {} }
    if (-not $pk) { Log "   $Pattern is not installed" }
    foreach ($p in $pk) {
        Log "   removing $($p.Name)"
        if ($DryRun) { continue }
        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
        catch {
            try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop }
            catch { Log "   could not remove $($p.Name): $($_.Exception.Message)" 'warn' }
        }
        Update-UI
    }
    $prov = @()
    try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -like $Pattern }) }
    catch { Log "   could not check provisioned copies ($($_.Exception.Message))" 'warn' }
    foreach ($p in $prov) {
        Log '   removing provisioned copy so new accounts do not get it'
        if (-not $DryRun) { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue | Out-Null }
    }
}

# Runs a desktop program's own uninstaller. MSI installs run silently; others may show their own window.
function Invoke-Uninstall($App) {
    $cmd = "$($App.QuietUninstallString)"; $quiet = $true
    if (-not $cmd) { $cmd = "$($App.UninstallString)"; $quiet = $false }
    if (-not $cmd) { throw "No uninstaller registered for $($App.DisplayName)." }
    $exe = $null; $uArgs = ''
    if ($cmd -match '(?i)msiexec(\.exe)?\s.*?(\{[0-9A-F-]{36}\})') { $exe = 'msiexec.exe'; $uArgs = "/x $($matches[2]) /qn /norestart"; $quiet = $true }
    elseif ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $matches[1]; $uArgs = $matches[2] }
    elseif ($cmd -match '^\s*(.+?\.exe)\s*(.*)$') { $exe = $matches[1]; $uArgs = $matches[2] }
    else { throw "Cannot read the uninstaller for $($App.DisplayName)." }
    if ($uArgs -match '--uninstall' -and $uArgs -notmatch '--force-uninstall') { $uArgs += ' --force-uninstall'; $quiet = $true }   # Chromium browsers
    if ($exe -match '(?i)\\uninstall\\helper\.exe$' -and $uArgs -notmatch '/S') { $uArgs = ($uArgs + ' /S').Trim(); $quiet = $true }  # Firefox
    Log "   uninstalling $($App.DisplayName)"
    if (-not $quiet) { Log '   if an uninstall window opens, follow it to finish' }
    if ($DryRun) { Log "   [dry] $exe $uArgs"; return }
    if ($uArgs) { $p = Start-Process -FilePath $exe -ArgumentList $uArgs -PassThru } else { $p = Start-Process -FilePath $exe -PassThru }
    $deadline = (Get-Date).AddMinutes(15)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Update-UI; Start-Sleep -Milliseconds 200 }
    if ($p.HasExited) { Log "   uninstaller finished (exit code $($p.ExitCode))" } else { Log '   uninstaller is still open; finish it in its window' 'warn' }
}

function Restore-Entry([hashtable]$e) {
    switch ($e.kind) {
        'reg' {
            if ($DryRun) { Log "   [dry] restore $($e.path)\$($e.name)"; return }
            if ($e.existed) {
                $v = $e.value
                if ($e.type -eq 'Binary') { $v = [byte[]]@($v) }
                elseif ($e.type -eq 'MultiString') { $v = [string[]]@($v) }
                if (-not (Test-Path -LiteralPath $e.path)) { New-Item -Path $e.path -Force | Out-Null }
                New-ItemProperty -LiteralPath $e.path -Name $e.name -Value $v -PropertyType $e.type -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $e.path -Name $e.name -ErrorAction SilentlyContinue
            }
        }
        'svc' {
            Log "   service $($e.name) -> $($e.start)"
            if (-not $DryRun) { & sc.exe config $e.name start= $e.start | Out-Null }
        }
        'task' {
            if ($e.enabled -and -not $DryRun) { Enable-ScheduledTask -TaskPath $e.path -TaskName $e.name -ErrorAction SilentlyContinue | Out-Null }
        }
        'power' {
            Invoke-Cmd 'powercfg' @('/setacvalueindex', 'SCHEME_CURRENT', $e.sub, $e.setting, "$($e.ac)")
            Invoke-Cmd 'powercfg' @('/setdcvalueindex', 'SCHEME_CURRENT', $e.sub, $e.setting, "$($e.dc)")
            Invoke-Cmd 'powercfg' @('/setactive', 'SCHEME_CURRENT')
        }
        'scheme' { Invoke-Cmd 'powercfg' @('/setactive', $e.guid) }
        'nic' {
            Log "   $($e.adapter): $($e.keyword) -> '$($e.display)'"
            if ($DryRun) { return }
            Set-NetAdapterAdvancedProperty -Name $e.adapter -RegistryKeyword $e.keyword -RegistryValue ([string[]]@($e.value)) -NoRestart -ErrorAction SilentlyContinue
            $script:NicsToRestart[$e.adapter] = $true
        }
        'devpower' {
            if ($DryRun) { return }
            Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceName -eq $e.instance } |
                ForEach-Object { Set-CimInstance -InputObject $_ -Property @{ Enable = $true } -ErrorAction SilentlyContinue }
        }
        'feature' {
            Log "   re-enabling Windows feature $($e.name)"
            if (-not $DryRun) { Enable-WindowsOptionalFeature -Online -FeatureName $e.name -All -NoRestart -ErrorAction SilentlyContinue | Out-Null }
        }
        'file' {
            Log "   restoring $($e.path)"
            if (-not $DryRun -and (Test-Path -LiteralPath $e.backup)) { Copy-Item -LiteralPath $e.backup -Destination $e.path -Force }
        }
        'asus' { Set-AsusDev ([uint32]$e.id) ([uint32]$e.value) }
        'legion' {
            if ($DryRun) { return }
            $gz = Get-WmiObject -Namespace root\WMI -Class LENOVO_GAMEZONE_DATA -ErrorAction SilentlyContinue
            if ($gz) {
                if ($e.what -eq 'fan') { $gz.SetSmartFanMode([int]$e.value) | Out-Null }
                if ($e.what -eq 'mux') { $gz.SetGSyncStatus([int]$e.value) | Out-Null }
            }
        }
    }
}

# ---------------------------------------------------------------- icons
function Get-ExePath([string]$Cmd) {
    if (-not $Cmd) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($Cmd.Trim())
    if ($c -match '^"([^"]+)"') { return $matches[1] }
    if ($c -match '^(.+?\.(exe|lnk|ico|png))(\s|,|$)') { return $matches[1] }
    return ($c -split ',')[0]
}

function Get-IconImage([string]$PathText) {
    $p = Get-ExePath $PathText
    if (-not $p) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        if ($p -match '(?i)\.(png|jpg|jpeg|bmp|ico)$') {
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit(); $bi.UriSource = New-Object Uri $p; $bi.DecodePixelWidth = 64; $bi.CacheOption = 'OnLoad'; $bi.EndInit(); $bi.Freeze()
            return $bi
        }
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($p)
        if (-not $ico) { return $null }
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $src.Freeze(); $ico.Dispose()
        return $src
    } catch { return $null }
}

function Get-ProgramIconPath($App) {
    $p = Get-ExePath "$($App.DisplayIcon)"
    if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return "$($App.DisplayIcon)" }
    $loc = "$($App.InstallLocation)".Trim().Trim('"')
    if ($loc -and (Test-Path -LiteralPath $loc)) {
        $exes = @(Get-ChildItem -LiteralPath $loc -Filter *.exe -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '(?i)unins|setup|crash|helper|update' })
        $key = ("$($App.DisplayName)" -replace '[^A-Za-z]', '').ToLower()
        $pick = $null
        if ($key) {
            $pick = $exes | Where-Object { $b = ($_.BaseName -replace '[^A-Za-z]', '').ToLower(); $b -and ($key.StartsWith($b) -or $b.StartsWith($key.Substring(0, [Math]::Min(4, $key.Length)))) } | Select-Object -First 1
        }
        if (-not $pick) { $pick = $exes | Sort-Object Length -Descending | Select-Object -First 1 }
        if ($pick) { return $pick.FullName }
        $upd = Join-Path $loc 'Update.exe'      # Squirrel apps such as Discord
        if (Test-Path -LiteralPath $upd) { return $upd }
    }
    return $null
}

function Get-AppxLogo($Pkg) {
    try {
        $dir = $Pkg.InstallLocation
        if (-not $dir) { return $null }
        $mf = Join-Path $dir 'AppxManifest.xml'
        if (-not (Test-Path -LiteralPath $mf)) { return $null }
        [xml]$x = Get-Content -LiteralPath $mf -Raw
        $rel = "$($x.Package.Properties.Logo)"
        if (-not $rel) { return $null }
        $full = Join-Path $dir $rel
        if (Test-Path -LiteralPath $full) { return $full }
        $folder = Split-Path $full
        $base = [IO.Path]::GetFileNameWithoutExtension($full)
        $cands = @(Get-ChildItem -LiteralPath $folder -Filter "$base*.png" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'contrast' })
        foreach ($rx in 'scale-100', 'scale-200', 'scale-150', '.') {
            $pick = $cands | Where-Object { $_.Name -match $rx } | Select-Object -First 1
            if ($pick) { return $pick.FullName }
        }
    } catch {}
    return $null
}

function Get-AppxDisplayName($Pkg) {
    try {
        $mf = Join-Path $Pkg.InstallLocation 'AppxManifest.xml'
        [xml]$x = Get-Content -LiteralPath $mf -Raw
        $n = "$($x.Package.Properties.DisplayName)"
        if ($n -and $n -notmatch '^ms-resource') { return $n }
    } catch {}
    return (($Pkg.Name -split '\.')[-1] -creplace '([a-z])([A-Z])', '$1 $2')
}

# ---------------------------------------------------------------- tweak catalog
# Level: 1 = Light (safe for everyone), 2 = Balanced (gaming), 3 = Max (aggressive), 0 = manual only (never auto-ticked)
$script:Tweaks = New-Object System.Collections.ArrayList
function Add-Tweak {
    param([string]$Id, [string]$Tab, [string]$Name, [string]$Desc, [int]$Level,
        [scriptblock]$Apply, [scriptblock]$Undo, [switch]$Reboot, [switch]$NoUndo, [switch]$Guide, [string]$Warn, $Data,
        [string]$Icon, [string]$Sub, [string]$Group)
    [void]$script:Tweaks.Add([pscustomobject]@{
            Id = $Id; Tab = $Tab; Name = $Name; Desc = $Desc; Level = $Level; Apply = $Apply; Undo = $Undo
            Reboot = [bool]$Reboot; NoUndo = [bool]$NoUndo; Guide = [bool]$Guide; Warn = $Warn; Data = $Data
            Icon = $Icon; Sub = $Sub; Group = $Group
            CheckBox = $null; Element = $null; Container = $null; IsTile = $false; AppliedBadge = $null
        })
}

$MMKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$SUB_USB = '2a737441-1930-4402-8d77-b2bebba308a3'
$USB_SUSPEND = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$DisabledBytes = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

# ===== Performance ==========================================================
Add-Tweak -Id 'power-ultimate' -Tab 'Performance' -Level 1 -Name 'Ultimate Performance power plan' `
    -Desc 'Adds and switches to the hidden Ultimate Performance plan so the CPU never drops into deep idle states mid-game. Uses more battery when unplugged.' `
    -Apply {
    $before = Get-ActiveScheme
    $list = powercfg /list | Out-String
    $guid = $null
    if ($list -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})\s+\(Ultimate Performance') { $guid = $matches[1] }
    if (-not $guid -and -not $DryRun) {
        $dup = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1 | Out-String
        if ($dup -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { $guid = $matches[1] }
    }
    if (-not $guid -and $list -match '(8c5e7fda-e8bf-4a96-9a85-cf4e1d7d4a5d)') { $guid = $matches[1]; Log '   Ultimate is blocked on this PC, using High Performance instead' 'warn' }
    if (-not $guid) { if ($DryRun) { Log '   [dry] would create Ultimate Performance'; return }; throw 'This PC does not allow Ultimate or High Performance plans (Modern Standby).' }
    Save-Original @{ kind = 'scheme'; key = 'scheme'; guid = $before }
    Invoke-Cmd 'powercfg' @('/setactive', $guid)
}

Add-Tweak -Id 'cpu-boost' -Tab 'Performance' -Level 2 -Name 'Aggressive CPU boost, no core parking' `
    -Desc 'On the charger the CPU boosts to max clocks right away and keeps every core awake. Raises temperatures a little.' `
    -Apply {
    Set-PowerValue 'SUB_PROCESSOR' 'PERFBOOSTMODE' 2
    Set-PowerValue 'SUB_PROCESSOR' 'CPMINCORES' 100
}

Add-Tweak -Id 'power-throttling' -Tab 'Performance' -Level 2 -Reboot -Name 'Turn off power throttling' `
    -Desc 'Stops Windows from slowing down background processes (voice chat, overlays, launchers) to save power.' `
    -Apply { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1 }

Add-Tweak -Id 'hags' -Tab 'Performance' -Level 1 -Reboot -Name 'Hardware-accelerated GPU scheduling' `
    -Desc 'Lets the graphics card manage its own frame queue. Lower latency on GTX 1000 / RX 5000 and newer. Needed for DLSS Frame Generation.' `
    -Apply { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 }

Add-Tweak -Id 'mmcss-games' -Tab 'Performance' -Level 1 -Name 'Top scheduler priority for games' `
    -Desc 'Sets the Windows multimedia scheduler (MMCSS) "Games" profile to the highest CPU and GPU priority.' `
    -Apply {
    $g = "$MMKey\Tasks\Games"
    Set-Reg $g 'GPU Priority' 8
    Set-Reg $g 'Priority' 6
    Set-Reg $g 'Scheduling Category' 'High' 'String'
    Set-Reg $g 'SFIO Priority' 'High' 'String'
}

Add-Tweak -Id 'net-throttle' -Tab 'Performance' -Level 2 -Name 'No network throttling, full responsiveness' `
    -Desc 'Stops Windows from throttling network packets while audio or video plays and reserves no CPU for background media tasks.' `
    -Apply {
    Set-Reg $MMKey 'NetworkThrottlingIndex' 0xffffffff
    Set-Reg $MMKey 'SystemResponsiveness' 0
}

Add-Tweak -Id 'priority-sep' -Tab 'Performance' -Level 2 -Name 'Favor the game window (foreground boost)' `
    -Desc 'Sets Win32PrioritySeparation to 38: short, variable CPU time slices with a 3x boost for the window you are using.' `
    -Apply { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38 }

$TimerResSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class TimerRes {
    [DllImport("ntdll.dll")] static extern int NtSetTimerResolution(uint want, bool set, out uint cur);
    [DllImport("ntdll.dll")] static extern int NtQueryTimerResolution(out uint min, out uint max, out uint cur);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool SetProcessInformation(IntPtr h, int cls, ref PowerThrottling info, int size);
    [StructLayout(LayoutKind.Sequential)] struct PowerThrottling { public uint Version; public uint ControlMask; public uint StateMask; }
    static Mutex single;

    // Windows 11 may ignore timer requests from background processes; opt out of that.
    static void KeepTimerRequest() {
        try { var s = new PowerThrottling { Version = 1, ControlMask = 4, StateMask = 0 }; SetProcessInformation(GetCurrentProcess(), 4, ref s, Marshal.SizeOf(typeof(PowerThrottling))); } catch { }
    }

    // How many ms later than asked Sleep(1) wakes up: average and spread.
    static void Measure(uint res, int samples, out double avg, out double sd) {
        uint c; NtSetTimerResolution(res, true, out c);
        Thread.Sleep(20);
        for (int i = 0; i < 5; i++) Thread.Sleep(1);
        var d = new double[samples];
        for (int i = 0; i < samples; i++) {
            long t0 = Stopwatch.GetTimestamp();
            Thread.Sleep(1);
            d[i] = (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency - 1.0;
        }
        NtSetTimerResolution(res, false, out c);
        avg = 0; foreach (var x in d) avg += x; avg /= samples;
        double v = 0; foreach (var x in d) v += (x - avg) * (x - avg); sd = Math.Sqrt(v / samples);
    }

    static int Main(string[] a) {
        KeepTimerRequest();
        uint min, max, cur; NtQueryTimerResolution(out min, out max, out cur);
        var inv = CultureInfo.InvariantCulture;

        if (a.Length >= 2 && a[0] == "--bench") {
            // Pass 1: every value from 0.500 to 0.600 ms. Pass 2: re-test the 5 best three more times and average.
            try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.High; } catch { }
            Thread.CurrentThread.Priority = ThreadPriority.Highest;
            var res = new List<double>(); var dl = new List<double>(); var sdl = new List<double>();
            for (int i = 0; i <= 50; i++) {
                double r = 0.5 + i * 0.002;
                uint want = (uint)Math.Round(r * 10000);
                if (want < max) continue;
                double avg, sd; Measure(want, 100, out avg, out sd);
                res.Add(r); dl.Add(avg); sdl.Add(sd);
            }
            int m = res.Count;
            var keys = new double[m]; var idx = new int[m];
            for (int i = 0; i < m; i++) { keys[i] = dl[i] + sdl[i]; idx[i] = i; }
            Array.Sort(keys, idx);
            int top = Math.Min(5, m);
            var refined = new double[m]; for (int i = 0; i < m; i++) refined[i] = double.NaN;
            var acc = new double[top];
            for (int round = 0; round < 3; round++) {
                for (int k = 0; k < top; k++) {
                    double avg, sd; Measure((uint)Math.Round(res[idx[k]] * 10000), 150, out avg, out sd);
                    acc[k] += avg + sd;
                }
            }
            for (int k = 0; k < top; k++) refined[idx[k]] = acc[k] / 3;
            var sb = new StringBuilder("ResolutionMs,DeltaMs,StdevMs,RefinedScore\r\n");
            for (int i = 0; i < m; i++) {
                sb.AppendFormat(inv, "{0:F4},{1:F4},{2:F4},{3}\r\n", res[i], dl[i], sdl[i], double.IsNaN(refined[i]) ? "" : refined[i].ToString("F4", inv));
            }
            File.WriteAllText(a[1], sb.ToString());
            return 0;
        }

        // Hold mode: TimerRes.exe <resolution in 100 ns units>, started at logon.
        bool created; single = new Mutex(true, "Global\\TweakHubTimerRes", out created);
        if (!created) return 0;
        uint hold = 5040; if (a.Length > 0) uint.TryParse(a[0], out hold);
        if (hold < max) hold = max;
        uint c2; NtSetTimerResolution(hold, true, out c2);
        Thread.Sleep(Timeout.Infinite);
        return 0;
    }
}
'@

function Get-TimerResults([string]$Csv) {
    if (-not (Test-Path -LiteralPath $Csv)) { return @() }
    return @(Import-Csv -LiteralPath $Csv | ForEach-Object {
            $ref = $null; if ($_.RefinedScore) { $ref = [double]$_.RefinedScore }
            [pscustomobject]@{ Res = [double]$_.ResolutionMs; Delta = [double]$_.DeltaMs; Sd = [double]$_.StdevMs; Refined = $ref }
        })
}
function Get-TimerBest($Rows) {
    $ref = @($Rows | Where-Object { $null -ne $_.Refined } | Sort-Object Refined)
    if ($ref) { return $ref[0] }
    return ($Rows | Sort-Object { $_.Delta + $_.Sd } | Select-Object -First 1)
}
$TimerCsv = Join-Path $DataDir 'timer-benchmark.csv'

Add-Tweak -Id 'timer-bench' -Tab 'Performance' -Level 2 -Reboot -Name 'Best timer resolution for this PC (benchmarked)' `
    -Desc 'Tests every timer value from 0.500 to 0.600 ms on this PC (about 15 seconds), picks the one where Windows wakes up most accurately and steadily, and keeps it running from startup. The lowest value is often not the best one. Close games before running.' `
    -Apply {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1
    $exe = Join-Path $DataDir 'TimerRes.exe'
    $others = @(Get-Process SetTimerResolution, TimerRes -ErrorAction SilentlyContinue)
    if ($others) {
        if ($DryRun) { Log '   another timer tool is running, so this dry-run benchmark is less accurate' 'warn' }
        else { Log '   stopping other timer tools so they do not skew the test'; $others | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }
    }
    Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    Add-Type -TypeDefinition $TimerResSource -OutputAssembly $exe -OutputType WindowsApplication -ErrorAction Stop
    Log '   benchmarking timer values 0.500 - 0.600 ms (about 15 seconds, leave the PC alone)'
    $p = Start-Process -FilePath $exe -ArgumentList "--bench `"$TimerCsv`"" -PassThru -WindowStyle Hidden
    while (-not $p.HasExited) { Update-UI; Start-Sleep -Milliseconds 100 }
    $rows = Get-TimerResults $TimerCsv
    if (-not $rows) { throw 'The timer benchmark did not produce results.' }
    $best = Get-TimerBest $rows
    $lowest = $rows | Sort-Object Res | Select-Object -First 1
    Log ('   best for this PC: {0} ms ({1} ms late on average, jitter {2} ms)' -f $best.Res.ToString('0.000', $Inv), $best.Delta.ToString('0.000', $Inv), $best.Sd.ToString('0.000', $Inv))
    Log ('   lowest value {0} ms was {1} ms late, jitter {2} ms' -f $lowest.Res.ToString('0.000', $Inv), $lowest.Delta.ToString('0.000', $Inv), $lowest.Sd.ToString('0.000', $Inv))
    Show-TimerChart

    foreach ($s in (Get-StartupEntries | Where-Object { "$($_.Name) $($_.Command)" -match 'SetTimerResolution' -and -not $_.Disabled })) {
        Log "   turning off old startup entry '$($s.Name)' (TweakHub replaces it)"
        Set-Reg $s.Approved $s.Name $DisabledBytes 'Binary'
    }
    $hold = [int][Math]::Round($best.Res * 10000)
    if ($DryRun) { Log "   [dry] would keep $($best.Res.ToString('0.000', $Inv)) ms running from every startup"; return }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $exe -Argument "$hold"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'TweakHub Timer Resolution' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName 'TweakHub Timer Resolution'
    Log "   timer helper running at $($best.Res.ToString('0.000', $Inv)) ms and set to start at every sign-in"
} -Undo {
    Log '   removing timer helper (an old SetTimerResolution startup entry comes back at next sign-in)'
    if ($DryRun) { return }
    Unregister-ScheduledTask -TaskName 'TweakHub Timer Resolution' -Confirm:$false -ErrorAction SilentlyContinue
    Get-Process TimerRes -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    Remove-Item (Join-Path $DataDir 'TimerRes.exe') -Force -ErrorAction SilentlyContinue
}

Add-Tweak -Id 'dynamic-tick' -Tab 'Performance' -Level 3 -Reboot -Name 'Disable dynamic tick' `
    -Desc 'Keeps the kernel timer ticking steadily instead of pausing it when idle. Small latency gain, slightly worse battery life.' `
    -Apply { Invoke-Cmd 'bcdedit' @('/set', 'disabledynamictick', 'yes') } `
    -Undo { Invoke-Cmd 'bcdedit' @('/deletevalue', 'disabledynamictick') }

Add-Tweak -Id 'hpet' -Tab 'Performance' -Level 3 -Reboot -Name 'Stop forcing HPET as the system clock' `
    -Desc 'Removes the "useplatformclock" boot flag so Windows uses its faster default timer. Does nothing if the flag was never set.' `
    -Apply { Invoke-Cmd 'bcdedit' @('/deletevalue', 'useplatformclock') } `
    -Undo { Log '   Windows default restored already; nothing to undo' }

Add-Tweak -Id 'vbs-off' -Tab 'Performance' -Level 3 -Reboot -Name 'Turn off virtualization-based security and the hypervisor' `
    -Desc 'Turns off VBS and the Windows hypervisor, which can cost 5-10% FPS. Also turns off the Virtual Machine Platform and Hyper-V features.' `
    -Warn 'Breaks WSL2, Docker, Android emulators (BlueStacks Hyper-V) and Windows Sandbox, and lowers security. Skip if you use any of them.' `
    -Apply {
    Invoke-Cmd 'bcdedit' @('/set', 'hypervisorlaunchtype', 'off')
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
    foreach ($f in 'VirtualMachinePlatform', 'HypervisorPlatform', 'Microsoft-Hyper-V-All') {
        $feat = $null
        try { $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop }
        catch { Log "   could not check feature $f ($($_.Exception.Message))" 'warn' }
        if ($feat -and $feat.State -eq 'Enabled') {
            Save-Original @{ kind = 'feature'; key = "feature|$f"; name = $f }
            Log "   turning off Windows feature $f"
            if (-not $DryRun) { Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -ErrorAction SilentlyContinue | Out-Null }
        }
        Update-UI
    }
} -Undo { Invoke-Cmd 'bcdedit' @('/set', 'hypervisorlaunchtype', 'auto') }

Add-Tweak -Id 'visual-fx' -Tab 'Performance' -Level 2 -Name 'Lighter visual effects' `
    -Desc 'Turns off transparency, window minimize animations and taskbar animations, and makes menus open faster. Takes effect after signing out.' `
    -Apply {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
    Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '200' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
}

Add-Tweak -Id 'fast-startup' -Tab 'Performance' -Level 2 -Name 'Turn off Fast Startup' `
    -Desc 'Shut down really shuts down, so drivers and the timer start fresh. Fixes many "only works after a restart" problems. Boot takes a few seconds longer.' `
    -Apply { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0 }

# ===== Input ================================================================
Add-Tweak -Id 'mouse-accel' -Tab 'Input' -Level 1 -Name 'Turn off mouse acceleration' `
    -Desc 'Turns off "Enhance pointer precision" so the same hand movement always moves your aim the same distance.' `
    -Apply {
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
    if (-not $DryRun) { [void][TweakHubNative11]::SystemParametersInfo(0x0004, 0, [int[]](0, 0, 0), 3) }
} -Undo {
    if ($DryRun) { return }
    $m = Get-ItemProperty 'HKCU:\Control Panel\Mouse'
    [void][TweakHubNative11]::SystemParametersInfo(0x0004, 0, [int[]]([int]$m.MouseThreshold1, [int]$m.MouseThreshold2, [int]$m.MouseSpeed), 3)
}

Add-Tweak -Id 'kb-repeat' -Tab 'Input' -Level 2 -Name 'Fastest keyboard repeat' `
    -Desc 'Shortest delay before a held key repeats, and the fastest repeat rate.' `
    -Apply {
    Set-Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String'
    if (-not $DryRun) {
        [void][TweakHubNative11]::SystemParametersInfoPtr(0x0017, 0, [IntPtr]::Zero, 3)
        [void][TweakHubNative11]::SystemParametersInfoPtr(0x000B, 31, [IntPtr]::Zero, 3)
    }
}

Add-Tweak -Id 'access-keys' -Tab 'Input' -Level 1 -Name 'No Sticky / Filter / Toggle Keys pop-ups' `
    -Desc 'Stops the accessibility pop-ups that appear when you tap Shift five times or hold it down mid-game.' `
    -Apply {
    Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'
}

Add-Tweak -Id 'lang-hotkeys' -Tab 'Input' -Level 2 -Name 'Turn off Alt+Shift / Ctrl+Shift language switching' `
    -Desc 'Stops the keyboard layout from changing when you press Alt+Shift or Ctrl+Shift while gaming. Win+Space still switches.' `
    -Apply {
    Set-Reg 'HKCU:\Keyboard Layout\Toggle' 'Hotkey' '3' 'String'
    Set-Reg 'HKCU:\Keyboard Layout\Toggle' 'Language Hotkey' '3' 'String'
    Set-Reg 'HKCU:\Keyboard Layout\Toggle' 'Layout Hotkey' '3' 'String'
}

Add-Tweak -Id 'usb-suspend' -Tab 'Input' -Level 1 -Name 'USB selective suspend off' `
    -Desc 'Windows will not put USB ports to sleep, so a wireless mouse receiver never has to wake up mid-fight.' `
    -Apply { Set-PowerValue $SUB_USB $USB_SUSPEND 0 0 }

Add-Tweak -Id 'usb-power' -Tab 'Input' -Level 2 -Reboot -Name 'No power saving on mice, keyboards and USB hubs' `
    -Desc 'Turns off enhanced power management and "allow the computer to turn off this device" for every USB, HID, mouse and keyboard device.' `
    -Apply {
    $devs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Class -in 'USB', 'HIDClass', 'Mouse', 'Keyboard' })
    foreach ($d in $devs) {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)\Device Parameters"
        if (Test-Path -LiteralPath $p) {
            Set-Reg $p 'EnhancedPowerManagementEnabled' 0
            Set-Reg $p 'AllowIdleIrpInD3' 0
            Set-Reg $p 'DeviceSelectiveSuspended' 0
        }
    }
    Log "   checked $($devs.Count) USB and input devices"
    Disable-DevicePowerOff ($devs | ForEach-Object { $_.InstanceId })
}

Add-Tweak -Id 'input-queue' -Tab 'Input' -Level 3 -Reboot -Name 'Smaller mouse and keyboard buffers' `
    -Desc 'Shrinks the mouse and keyboard input queues from 100 to 20 events so input is processed sooner.' `
    -Warn 'Values below 20 can drop inputs. If clicks ever feel missed, undo this one.' `
    -Apply {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' 'MouseDataQueueSize' 20
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters' 'KeyboardDataQueueSize' 20
}

# ===== Network (works for Intel, Realtek, MediaTek, Qualcomm/Killer and Broadcom cards) ======
$Off = @('No SMPS', '^(\d\.\s*)?Disabled?$', '^Off$', 'Maximum Performance')
$WifiCards = @(Get-PhysicalNics 'wifi' | ForEach-Object InterfaceDescription | Select-Object -Unique)

Add-Tweak -Id 'nic-power' -Tab 'Network' -Level 1 -Name 'No power saving on Wi-Fi and Ethernet' `
    -Desc 'Turns off every driver power-saving option (the main cause of random 100-500 ms ping spikes on Wi-Fi): Power Saving, MIMO power save, U-APSD, Minimum Power Consumption, Green/Energy-Efficient Ethernet, plus "allow the computer to turn off this device".' `
    -Apply {
    $nics = Get-PhysicalNics
    foreach ($n in $nics) {
        Set-NicProp $n '^(Power Saving|Power Saving Mode|Power Save Mode|MIMO Power Save Mode|Minimum Power Consumption|U-APSD Support|U-APSD support|Sleep on WoWLAN Disconnect|Selective Suspend|Idle Power Saving|Energy[- ]Efficient Ethernet|Advanced EEE|Green Ethernet|Gigabit Lite|Ultra Low Power Mode|Auto Disable Gigabit|Power Saving Mode for WoWLAN)$' $Off
    }
    Disable-DevicePowerOff ($nics | ForEach-Object { $_.PnPDeviceID })
}

Add-Tweak -Id 'wifi-radio' -Tab 'Network' -Level 1 -Name 'Wi-Fi radio at maximum performance' `
    -Desc 'Sets the power plan Wireless Adapter setting to Maximum Performance on charger and battery.' `
    -Apply { Set-PowerValue '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1' '12bbebe6-58d6-4636-95bb-3217ef867c1a' 0 0 }

Add-Tweak -Id 'wifi-roam' -Tab 'Network' -Level 2 -Name 'Stop Wi-Fi roaming scans' `
    -Desc 'Sets roaming to its lowest setting on any card (Intel Roaming Aggressiveness, Realtek Roaming Sensitivity, Broadcom/Qualcomm Roam Tendency). Scanning for other access points mid-game causes 1-3 second stalls.' `
    -Apply {
    foreach ($n in (Get-PhysicalNics 'wifi')) {
        Set-NicProp $n '^(Roaming Aggressiveness|Roaming Sensitivity Level|Roaming Sensitivity|Roam Tendency|Roaming Preference|Roaming Aggressive)$' @('^(\d\.\s*)?Disabled?$', 'Lowest', 'Conservative', '^(\d\.\s*)?Low$')
    }
}

Add-Tweak -Id 'wifi-scan' -Tab 'Network' -Level 2 -Name 'Block background Wi-Fi scans (Intel)' `
    -Desc 'Intel cards: Global BG Scan Blocking = Always, so the card stops scanning for networks while you are connected. Skipped on other cards.' `
    -Apply { foreach ($n in (Get-PhysicalNics 'wifi')) { Set-NicProp $n '^Global BG Scan [Bb]locking$' @('Always') } }

Add-Tweak -Id 'wifi-coalesce' -Tab 'Network' -Level 2 -Name 'Turn off packet coalescing' `
    -Desc 'The card stops holding small packets back to deliver them in batches. Lower and steadier ping.' `
    -Apply { foreach ($n in (Get-PhysicalNics)) { Set-NicProp $n '^(Packet Coalescing|ARP Offload|NS Offload)$' @('^(\d\.\s*)?Disabled?$') } }

Add-Tweak -Id 'wifi-txpower' -Tab 'Network' -Level 2 -Name 'Maximum Wi-Fi transmit power' `
    -Desc 'Sets Transmit Power to the highest level so the signal to your router stays strong, especially through walls.' `
    -Apply { foreach ($n in (Get-PhysicalNics 'wifi')) { Set-NicProp $n '^(Transmit Power|Transmit Power Level|Transmit power|TX Power|Tx Power Level|Transmit Power Control)$' @('Highest', '^(\d\.\s*)?100\s?%?$', 'Maximum', '^5\.') } }

Add-Tweak -Id 'wifi-band' -Tab 'Network' -Level 2 -Name 'Prefer the 5 GHz band' `
    -Desc '5 GHz has far less interference than 2.4 GHz. Harmless if your router only has 2.4 GHz.' `
    -Apply { foreach ($n in (Get-PhysicalNics 'wifi')) { Set-NicProp $n '^(Preferred Band|Band Preference|Preferred band)$' @('5\s?G') } }

Add-Tweak -Id 'wifi-24-20' -Tab 'Network' -Level 3 -Name '2.4 GHz: 20 MHz channel width only' `
    -Desc 'On busy 2.4 GHz networks (apartments, many routers nearby) a narrow channel is far more stable. Only matters while you are on 2.4 GHz.' `
    -Warn 'Lowers the top download speed on 2.4 GHz.' `
    -Apply { foreach ($n in (Get-PhysicalNics 'wifi')) { Set-NicProp $n '(?i)^(2\.4\s?GHz channel bandwidth|Channel Width for 2\.4\s?GHz|802\.11n Channel Width for band 2\.4\s?GHz|Bandwidth 2\.4G|2\.4G Bandwidth|Channel Width for 2\.4GHz)$' @('20\s?MHz') } }

Add-Tweak -Id 'nic-wake' -Tab 'Network' -Level 2 -Name 'Turn off Wake-on-LAN' `
    -Desc 'Network packets can no longer wake the PC or keep the adapter in a listening mode.' `
    -Apply { foreach ($n in (Get-PhysicalNics)) { Set-NicProp $n '(?i)^wake on' @('^(\d\.\s*)?Disabled?$') } }

Add-Tweak -Id 'nagle' -Tab 'Network' -Level 2 -Name 'Turn off Nagle and delayed ACK' `
    -Desc 'Sends small game packets immediately instead of batching them, on every network interface.' `
    -Apply {
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    foreach ($i in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        Set-Reg "$root\$($i.PSChildName)" 'TcpAckFrequency' 1
        Set-Reg "$root\$($i.PSChildName)" 'TCPNoDelay' 1
    }
}

Add-Tweak -Id 'nic-latency' -Tab 'Network' -Level 3 -Name 'Ethernet: interrupt moderation and flow control off' `
    -Desc 'Each packet is handled right away instead of in batches. Lowest wired latency, a bit more CPU use.' `
    -Apply { foreach ($n in (Get-PhysicalNics 'ethernet')) { Set-NicProp $n '^(Interrupt Moderation|Flow Control)$' @('^(\d\.\s*)?Disabled?$', '^Off$') } }

$hasBeMode = @(Get-PhysicalNics 'wifi' | ForEach-Object { Get-NetAdapterAdvancedProperty -Name $_.Name -ErrorAction SilentlyContinue } | Where-Object { $_.DisplayName -match '^802\.11be/ax' }).Count -gt 0
if ($hasBeMode) {
    Add-Tweak -Id 'wifi-ax' -Tab 'Network' -Level 0 -Name 'Wi-Fi 7 card: use Wi-Fi 6 mode (fixes drops)' `
        -Desc 'Fixes random disconnects on some Wi-Fi 7 drivers. Driver updates can reset this, so run it again after updating.' `
        -Apply { foreach ($n in (Get-PhysicalNics 'wifi')) { Set-NicProp $n '^802\.11be/ax' @('802\.11ax$') } }
}

# ===== Games ================================================================
Add-Tweak -Id 'game-mode' -Tab 'Games' -Level 1 -Name 'Game Mode on' `
    -Desc 'Windows pauses updates and driver installs and gives the game priority while it runs.' `
    -Apply {
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
}

Add-Tweak -Id 'gamedvr' -Tab 'Games' -Level 1 -Name 'Turn off Game DVR background recording' `
    -Desc 'Stops Xbox Game Bar from recording gameplay in the background and from opening with the controller Guide button.' `
    -Apply {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
}

Add-Tweak -Id 'fso' -Tab 'Games' -Level 2 -Name 'Turn off fullscreen optimizations' `
    -Desc 'Makes "Fullscreen" in older DirectX 9-11 games real exclusive fullscreen instead of a borderless window.' `
    -Apply {
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' 2
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
}

Add-Tweak -Id 'windowed-opt' -Tab 'Games' -Level 1 -Name 'Optimizations for windowed games' `
    -Desc 'Borderless and windowed games use the low-latency flip model, almost as fast as fullscreen.' `
    -Apply {
    $k = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $cur = (Get-ItemProperty -LiteralPath $k -Name DirectXUserGlobalSettings -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
    if (-not $cur) { $cur = '' }
    if ($cur -match 'SwapEffectUpgradeEnable=1') { Log '   already on'; return }
    $new = ($cur -replace 'SwapEffectUpgradeEnable=\d;?', '') + 'SwapEffectUpgradeEnable=1;'
    Set-Reg $k 'DirectXUserGlobalSettings' $new 'String'
}

$GameExes = @('FortniteClient-Win64-Shipping.exe', 'VALORANT-Win64-Shipping.exe', 'cs2.exe', 'r5apex.exe', 'r5apex_dx12.exe',
    'RobloxPlayerBeta.exe', 'Minecraft.Windows.exe', 'RainbowSix.exe', 'cod.exe', 'GTA5.exe', 'RocketLeague.exe', 'Overwatch.exe')
Add-Tweak -Id 'game-priority' -Tab 'Games' -Level 2 -Name 'Always start popular games at High CPU priority' `
    -Desc 'Fortnite, Valorant, CS2, Apex, Roblox, Minecraft, Rainbow Six, Call of Duty, GTA V, Rocket League and Overwatch.' `
    -Data $GameExes -Apply {
    param($T)
    foreach ($exe in $T.Data) {
        Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe\PerfOptions" 'CpuPriorityClass' 3
    }
}

$FnIni = Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini'
if (Test-Path -LiteralPath $FnIni) {
    Add-Tweak -Id 'fortnite-config' -Tab 'Games' -Level 1 -Name 'Fortnite: no mouse acceleration, true fullscreen' `
        -Desc 'Edits Fortnite settings: mouse acceleration off, real Fullscreen instead of Windowed Fullscreen, GPU crash debugging off. Fortnite must be closed.' `
        -Apply {
        if (Get-Process FortniteClient-Win64-Shipping -ErrorAction SilentlyContinue) { throw 'Fortnite is running. Close it fully and run this one again.' }
        $bak = Join-Path $DataDir 'GameUserSettings.ini.bak'
        if (-not $script:Backup.ContainsKey('fortnite-config')) { if (-not $DryRun) { Copy-Item -LiteralPath $FnIni -Destination $bak -Force } }
        Save-Original @{ kind = 'file'; key = 'file|fortnite'; path = $FnIni; backup = $bak }
        $text = Get-Content -LiteralPath $FnIni -Raw
        $text = $text -replace '(?m)^bDisableMouseAcceleration=.*$', 'bDisableMouseAcceleration=True'
        $text = $text -replace '(?m)^PreferredFullscreenMode=.*$', 'PreferredFullscreenMode=0'
        $text = $text -replace '(?m)^LastConfirmedFullscreenMode=.*$', 'LastConfirmedFullscreenMode=0'
        $text = $text -replace '(?m)^FullscreenMode=.*$', 'FullscreenMode=0'
        $text = $text -replace '(?m)^bUseGPUCrashDebugging=.*$', 'bUseGPUCrashDebugging=False'
        Log '   GameUserSettings.ini updated'
        if (-not $DryRun) { [IO.File]::WriteAllText($FnIni, $text) }
    }
}

Add-Tweak -Id 'gpu-autostart' -Tab 'Games' -Level 2 -Name 'Stop AMD Adrenalin from autostarting' `
    -Desc 'Disables the AMD Software and ReLive recording autostart tasks. The driver keeps working; open AMD Software yourself when needed.' `
    -Apply {
    foreach ($t in 'StartCN', 'StartDVR', 'StartCNBM') { Set-TaskOff '\' $t }
    if (-not $DryRun) { Stop-Process -Name RadeonSoftware -Force -ErrorAction SilentlyContinue }
}

# ===== Privacy & Background =================================================
Add-Tweak -Id 'telemetry' -Tab 'Privacy & Background' -Level 1 -Name 'Turn off telemetry' `
    -Desc 'Stops the Connected User Experiences (DiagTrack) service and the data-collection scheduled tasks.' `
    -Apply {
    Set-Svc 'DiagTrack' 'disabled'
    Set-Svc 'dmwappushservice' 'disabled'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    Set-TaskOff '\Microsoft\Windows\Application Experience\' 'Microsoft Compatibility Appraiser'
    Set-TaskOff '\Microsoft\Windows\Application Experience\' 'ProgramDataUpdater'
    Set-TaskOff '\Microsoft\Windows\Customer Experience Improvement Program\' 'Consolidator'
    Set-TaskOff '\Microsoft\Windows\Customer Experience Improvement Program\' 'UsbCeip'
    Set-TaskOff '\Microsoft\Windows\DiskDiagnostic\' 'Microsoft-Windows-DiskDiagnosticDataCollector'
    Set-TaskOff '\Microsoft\Windows\Feedback\Siuf\' 'DmClient'
    Set-TaskOff '\Microsoft\Windows\Feedback\Siuf\' 'DmClientOnScenarioDownload'
}

Add-Tweak -Id 'ads' -Tab 'Privacy & Background' -Level 1 -Name 'No ads, suggestions or auto-installed apps' `
    -Desc 'Turns off Start menu suggestions, tips, lock screen ads, the "finish setting up your device" nag, the advertising ID and silent installs of sponsored apps like Candy Crush.' `
    -Apply {
    $c = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'PreInstalledAppsEnabled',
        'OemPreInstalledAppsEnabled', 'RotatingLockScreenOverlayEnabled', 'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled',
        'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled',
        'SubscribedContent-310093Enabled') {
        Set-Reg $c $n 0
    }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
}

Add-Tweak -Id 'bing-search' -Tab 'Privacy & Background' -Level 1 -Name 'No Bing web results in Start search' `
    -Desc 'Start menu search only searches your PC and apps, which also makes it faster. Takes effect after signing out.' `
    -Apply {
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
}

Add-Tweak -Id 'copilot' -Tab 'Privacy & Background' -Level 1 -Name 'Turn off Copilot and Recall' `
    -Desc 'Hides Copilot, stops it starting with Windows and turns off Recall screen snapshots.' `
    -Apply {
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    $run = Get-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    if ($run) {
        foreach ($n in ($run.GetValueNames() | Where-Object { $_ -like 'MicrosoftCopilotAutoLaunch*' })) {
            Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' $n $DisabledBytes 'Binary'
        }
    }
}

Add-Tweak -Id 'widgets' -Tab 'Privacy & Background' -Level 1 -Name 'Turn off Widgets and the news feed' `
    -Desc 'Removes the Widgets button and stops the news feed from running in the background.' `
    -Apply {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
}

Add-Tweak -Id 'activity' -Tab 'Privacy & Background' -Level 1 -Name 'Turn off activity history' `
    -Desc 'Windows stops recording which apps, files and sites you open and stops uploading that history.' `
    -Apply { Set-Policies 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' @{ EnableActivityFeed = 0; PublishUserActivities = 0; UploadUserActivities = 0 } }

Add-Tweak -Id 'do-p2p' -Tab 'Privacy & Background' -Level 1 -Name 'Stop sharing Windows updates with other PCs' `
    -Desc 'Delivery Optimization stops uploading updates to other computers over your internet connection. Updates still download normally.' `
    -Apply { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 }

Add-Tweak -Id 'bg-apps' -Tab 'Privacy & Background' -Level 2 -Name 'Turn off background apps' `
    -Desc 'Microsoft Store apps can no longer run in the background.' `
    -Warn 'Store apps such as WhatsApp or Phone Link will not show notifications while closed.' `
    -Apply {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
}

Add-Tweak -Id 'sysmain' -Tab 'Privacy & Background' -Level 2 -Name 'Turn off SysMain (Superfetch)' `
    -Desc 'Stops Windows preloading apps into RAM and the random disk activity it causes. Best on SSDs.' `
    -Apply { Set-Svc 'SysMain' 'disabled' }

Add-Tweak -Id 'services-misc' -Tab 'Privacy & Background' -Level 2 -Name 'Turn off unneeded services' `
    -Desc 'Fax, Retail Demo, Downloaded Maps Manager, Error Reporting, Geolocation, NVIDIA telemetry and the Cloudflare WARP updater (each only if installed).' `
    -Warn 'Geolocation off means apps and Find My Device cannot see your location.' `
    -Apply {
    foreach ($s in 'Fax', 'RetailDemo', 'MapsBroker', 'WerSvc', 'lfsvc', 'NvTelemetryContainer', 'CloudflareWARPUpdater') { Set-Svc $s 'disabled' }
    Set-TaskOff '\Microsoft\Windows\Maps\' 'MapsUpdateTask'
    Set-TaskOff '\Microsoft\Windows\Maps\' 'MapsToastTask'
}

Add-Tweak -Id 'search-index' -Tab 'Privacy & Background' -Level 3 -Name 'Turn off Windows Search indexing' `
    -Desc 'Stops the indexer from scanning your drives in the background.' `
    -Warn 'Searching files from Start and File Explorer becomes slower. App search still works.' `
    -Apply { Set-Svc 'WSearch' 'disabled' }

Add-Tweak -Id 'xbox-services' -Tab 'Privacy & Background' -Level 3 -Name 'Turn off Xbox services' `
    -Desc 'Xbox Live auth, game saves, networking and accessory services.' `
    -Warn 'Breaks Game Pass, Minecraft Bedrock sign-in, Xbox app and Xbox controller firmware updates.' `
    -Apply { foreach ($s in 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc') { Set-Svc $s 'disabled' } }

Add-Tweak -Id 'spooler' -Tab 'Privacy & Background' -Level 0 -Name 'Turn off printing' `
    -Desc 'Stops the Print Spooler service. Only if you never print or save to PDF.' `
    -Apply { Set-Svc 'Spooler' 'disabled' }

function Remove-FolderContents([string[]]$Dirs) {
    $total = 0
    foreach ($dir in $Dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $DataDir })
        foreach ($i in $items) {
            $size = 0
            if ($i.PSIsContainer) { $size = (Get-ChildItem -LiteralPath $i.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
            else { $size = $i.Length }
            if (-not $DryRun) {
                Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $i.FullName) { continue }
            }
            $total += [double]$size
        }
        Update-UI
    }
    return $total
}

Add-Tweak -Id 'clean-temp' -Tab 'Privacy & Background' -Level 1 -NoUndo -Name 'Clean temporary files' `
    -Desc 'Deletes leftovers in your Temp folder and Windows Temp. Files that are in use are skipped.' `
    -Apply {
    $freed = Remove-FolderContents @($env:TEMP, (Join-Path $env:WINDIR 'Temp'))
    Log ('   freed {0:N0} MB' -f ($freed / 1MB))
}

Add-Tweak -Id 'clean-updates' -Tab 'Privacy & Background' -Level 2 -NoUndo -Name 'Clean Windows Update leftovers' `
    -Desc 'Deletes already-installed update downloads and the Delivery Optimization cache. Often frees several GB.' `
    -Apply {
    $freed = Remove-FolderContents @((Join-Path $env:WINDIR 'SoftwareDistribution\Download'))
    if (-not $DryRun) { try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null } catch { Log "   Delivery Optimization cache: $($_.Exception.Message)" 'warn' } }
    Log ('   freed {0:N0} MB of update downloads' -f ($freed / 1MB))
}

# ===== Installed programs (used by Browsers and Debloat Apps) =================
$AllUninstall = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and ($_.UninstallString -or $_.QuietUninstallString) })

# ===== Browsers ===============================================================
$BrowserDefs = @(
    @{ Key = 'edge'; Name = 'Microsoft Edge'; Match = '^Microsoft Edge$' },
    @{ Key = 'chrome'; Name = 'Google Chrome'; Match = '^Google Chrome$' },
    @{ Key = 'firefox'; Name = 'Mozilla Firefox'; Match = '^Mozilla Firefox' },
    @{ Key = 'brave'; Name = 'Brave'; Match = '^Brave$' },
    @{ Key = 'opera'; Name = 'Opera'; Match = '^Opera Stable' },
    @{ Key = 'operagx'; Name = 'Opera GX'; Match = '^Opera GX' },
    @{ Key = 'vivaldi'; Name = 'Vivaldi'; Match = '^Vivaldi' }
)
$script:InstalledBrowsers = @()
foreach ($b in $BrowserDefs) {
    $entry = $AllUninstall | Where-Object { $_.DisplayName -match $b.Match } | Select-Object -First 1
    if ($entry) { $script:InstalledBrowsers += [pscustomobject]@{ Key = $b.Key; Name = $b.Name; Entry = $entry; Icon = (Get-ProgramIconPath $entry) } }
}
$BrowserNames = ($BrowserDefs | ForEach-Object { $_.Match }) -join '|'
function Get-Browser([string]$Key) { $script:InstalledBrowsers | Where-Object Key -eq $Key | Select-Object -First 1 }
$PolicyNote = ' The browser will say it is "managed by your organization"; that only means these settings are locked in.'

$edge = Get-Browser 'edge'
if ($edge -or (Test-Path "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")) {
    $edgeIcon = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    Add-Tweak -Id 'edge-debloat' -Tab 'Browsers' -Level 1 -Icon $edgeIcon -Name 'Debloat Microsoft Edge' `
        -Desc ('Stops Edge running in the background and preloading at startup, and turns off the Copilot sidebar, shopping pop-ups, Rewards, news feed, "follow creators", Drop, recommendations and telemetry.' + $PolicyNote) `
        -Apply {
        Set-Policies 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' @{
            StartupBoostEnabled = 0; BackgroundModeEnabled = 0; HubsSidebarEnabled = 0; StandaloneHubsSidebarEnabled = 0
            EdgeShoppingAssistantEnabled = 0; PersonalizationReportingEnabled = 0; ShowRecommendationsEnabled = 0; HideFirstRunExperience = 1
            SpotlightExperiencesAndRecommendationsEnabled = 0; DiagnosticData = 0; ShowMicrosoftRewards = 0; EdgeFollowEnabled = 0
            PromotionalTabsEnabled = 0; UserFeedbackAllowed = 0; DefaultBrowserSettingsCampaignEnabled = 0; EdgeEDropEnabled = 0
            WebWidgetAllowed = 0; NewTabPageContentEnabled = 0; Microsoft365CopilotChatIconEnabled = 0
        }
    }
    Add-Tweak -Id 'edge-remove' -Tab 'Browsers' -Level 0 -NoUndo -Icon $edgeIcon -Name 'Remove Microsoft Edge' `
        -Desc 'Runs the Edge uninstaller with Microsoft''s "allow uninstall" switch and blocks the automatic reinstall. Edge WebView2 is kept because many apps (Widgets, Teams, launchers) need it. Needs another browser installed first.' `
        -Warn 'No undo: reinstall from microsoft.com/edge. Some Windows builds still block removal; the log says if it worked. Big Windows updates can bring Edge back.' `
        -Apply {
        $others = @($script:InstalledBrowsers | Where-Object { $_.Key -ne 'edge' })
        if (-not $others) { throw 'Install another browser first (Brave, Chrome, Firefox...), otherwise you will have no way to browse.' }
        Set-Reg 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev' 'AllowUninstall' 1
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium' 1
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate' 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 0
        $setup = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\*\Installer\setup.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if (-not $setup) { throw 'Could not find the Edge uninstaller (setup.exe).' }
        if ($DryRun) { Log "   [dry] $($setup.FullName) --uninstall --system-level --force-uninstall"; return }
        Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $stub = Join-Path $env:SystemRoot 'SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe'
        $madeStub = $false
        if (-not (Test-Path -LiteralPath $stub)) {
            try { New-Item -ItemType Directory -Path (Split-Path $stub) -Force -ErrorAction Stop | Out-Null; New-Item -ItemType File -Path $stub -Force -ErrorAction Stop | Out-Null; $madeStub = $true } catch {}
        }
        $p = Start-Process -FilePath $setup.FullName -ArgumentList '--uninstall --system-level --verbose-logging --force-uninstall' -PassThru -WindowStyle Hidden
        while (-not $p.HasExited) { Update-UI; Start-Sleep -Milliseconds 200 }
        if ($madeStub) { Remove-Item -LiteralPath $stub -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        if (Test-Path "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") { Log '   Windows blocked the uninstall on this build. Edge is still installed; "Debloat Microsoft Edge" still trims it.' 'warn' }
        else { Log '   Microsoft Edge removed. WebView2 was kept.' }
    }
}

$chrome = Get-Browser 'chrome'
if ($chrome) {
    Add-Tweak -Id 'chrome-debloat' -Tab 'Browsers' -Level 1 -Icon $chrome.Icon -Name 'Debloat Google Chrome' `
        -Desc ('Stops Chrome running in the background after you close it, turns on Memory Saver, turns off ad-tracking "Privacy Sandbox", shopping, promotions, usage reports and the multi-GB on-device AI model download.' + $PolicyNote) `
        -Apply {
        Set-Policies 'HKLM:\SOFTWARE\Policies\Google\Chrome' @{
            BackgroundModeEnabled = 0; MetricsReportingEnabled = 0; PrivacySandboxPromptEnabled = 0; PrivacySandboxAdTopicsEnabled = 0
            PrivacySandboxSiteEnabledAdsEnabled = 0; PrivacySandboxAdMeasurementEnabled = 0; ShoppingListEnabled = 0; PromotionsEnabled = 0
            UserFeedbackAllowed = 0; GenAILocalFoundationalModelSettings = 1; HighEfficiencyModeEnabled = 1
        }
    }
}

$firefox = Get-Browser 'firefox'
if ($firefox) {
    Add-Tweak -Id 'firefox-debloat' -Tab 'Browsers' -Level 1 -Icon $firefox.Icon -Name 'Debloat Mozilla Firefox' `
        -Desc ('Turns off telemetry, studies, Pocket, sponsored shortcuts and stories, sponsored search suggestions, feature pop-ups and the Default Browser Agent task.' + $PolicyNote) `
        -Apply {
        $fx = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
        Set-Policies $fx @{ DisableTelemetry = 1; DisableFirefoxStudies = 1; DisablePocket = 1; DontCheckDefaultBrowser = 1; DisableDefaultBrowserAgent = 1 }
        Set-Policies "$fx\FirefoxHome" @{ SponsoredTopSites = 0; SponsoredPocket = 0; Pocket = 0 }
        Set-Policies "$fx\FirefoxSuggest" @{ SponsoredSuggestions = 0; ImproveSuggest = 0 }
        Set-Policies "$fx\UserMessaging" @{ ExtensionRecommendations = 0; FeatureRecommendations = 0; MoreFromMozilla = 0; SkipOnboarding = 1 }
        foreach ($t in @(Get-ScheduledTask -TaskPath '\Mozilla\' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'Firefox Default Browser Agent*' })) { Set-TaskOff $t.TaskPath $t.TaskName }
    }
}

$brave = Get-Browser 'brave'
if ($brave) {
    Add-Tweak -Id 'brave-debloat' -Tab 'Browsers' -Level 1 -Icon $brave.Icon -Name 'Debloat Brave' `
        -Desc ('Turns off Brave Rewards, Wallet, VPN, Leo AI, News, Talk, usage pings and background mode. Shields and ad blocking stay on.' + $PolicyNote) `
        -Apply {
        Set-Policies 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' @{
            BraveRewardsDisabled = 1; BraveWalletDisabled = 1; BraveVPNDisabled = 1; BraveAIChatEnabled = 0; BraveNewsDisabled = 1
            BraveTalkDisabled = 1; BraveP3AEnabled = 0; BraveStatsPingEnabled = 0; BraveWebDiscoveryEnabled = 0
            BackgroundModeEnabled = 0; MetricsReportingEnabled = 0
        }
    }
}

foreach ($ok in 'opera', 'operagx') {
    $op = Get-Browser $ok
    if (-not $op) { continue }
    Add-Tweak -Id "$ok-debloat" -Tab 'Browsers' -Level 1 -Icon $op.Icon -Name "Debloat $($op.Name)" -Data $op `
        -Desc 'Stops the Opera Browser Assistant from starting with Windows and turns off the background auto-update tasks. Opera still updates itself when you open it.' `
        -Apply {
        param($T)
        foreach ($s in (Get-StartupEntries | Where-Object { "$($_.Name) $($_.Command)" -match '(?i)browser_assistant|Browser Assistant' -and -not $_.Disabled })) {
            Set-Reg $s.Approved $s.Name $DisabledBytes 'Binary'
            Log "   startup '$($s.Name)' turned off"
        }
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^Opera( GX)? scheduled' })) { Set-TaskOff $t.TaskPath $t.TaskName }
    }
}

foreach ($b in ($script:InstalledBrowsers | Where-Object Key -ne 'edge')) {
    Add-Tweak -Id "browser-remove|$($b.Key)" -Tab 'Browsers' -Level 0 -NoUndo -Icon $b.Icon -Name "Remove $($b.Name)" -Data $b.Entry `
        -Desc "Runs the $($b.Name) uninstaller. Bookmarks and passwords synced to an account come back when you sign in again." `
        -Apply { param($T) Invoke-Uninstall $T.Data }
}

# ===== Startup apps (built from what is actually on this PC) ================
function Get-StartupEntries {
    $res = @()
    $sources = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
    )
    foreach ($s in $sources) {
        if (-not (Test-Path $s.Run)) { continue }
        $k = Get-Item $s.Run
        foreach ($n in $k.GetValueNames()) { if ($n) { $res += [pscustomobject]@{ Name = $n; Command = [string]$k.GetValue($n); Approved = $s.Approved } } }
    }
    $folders = @(
        @{ Dir = [Environment]::GetFolderPath('Startup'); Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )
    foreach ($f in $folders) {
        if (-not (Test-Path $f.Dir)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $f.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $res += [pscustomobject]@{ Name = $file.Name; Command = $file.FullName; Approved = $f.Approved }
        }
    }
    foreach ($r in $res) {
        $off = $false
        $ak = Get-Item -LiteralPath $r.Approved -ErrorAction SilentlyContinue
        if ($ak -and ($ak.GetValueNames() -contains $r.Name)) { $b = [byte[]]$ak.GetValue($r.Name); if ($b -and ($b[0] -band 1)) { $off = $true } }
        $r | Add-Member -NotePropertyName Disabled -NotePropertyValue $off
    }
    return $res
}

$NeverTouch = 'SecurityHealth|Windows Defender|^ctfmon|TweakHub'
$KeepByDefault = 'RtkAud|Realtek|Nahimic|Dolby|Synaptics|^ETD|Elan|Norton|Avast|AVG|McAfee|Bitdefender|Kaspersky|Malwarebytes|ESET|SetTimerResolution|TimerRes|NVIDIA|nvcpl|igfx|Vanguard|FACEIT|EasyAntiCheat|BattlEye|Logitech|Razer|SteelSeries|Corsair'
$KnownBloat = 'Discord|Spotify|Steam|Epic ?Games|Riot|EADM|EA ?Desktop|Origin|OneDrive|Teams|Copilot|EdgeAutoLaunch|Microsoft\.Lists|Vantage|AMDNoiseSuppression|StartAUEP|CloudflareWARP|CrosshairX|Wallpaper|Opera|Firefox|Brave|Chrome|Battle\.net|Ubisoft|Uplay|GOG|Skype|Zoom|Dropbox|GoogleDrive|iTunesHelper|Adobe|CCleaner|Overwolf|Medal|Outplayed|WhatsApp|Telegram|XMouseButtonControl|Xbox'

foreach ($s in (Get-StartupEntries)) {
    if ($s.Name -match $NeverTouch) { continue }
    $level = 3
    if ("$($s.Name) $($s.Command)" -match $KeepByDefault) { $level = 0 }
    elseif ("$($s.Name) $($s.Command)" -match $KnownBloat) { $level = 2 }
    $group = 'Starts with Windows'
    if ($s.Disabled) { $level = 0; $group = 'Already turned off' }
    $displayName = $s.Name -replace '_[0-9A-F]{32}$', '' -replace '\.lnk$', '' -replace ' - Shortcut$', ''
    $exe = Get-ExePath $s.Command
    $iconPath = $s.Command
    if ($exe -and $s.Command -match '--processStart\s+"?([^"\s]+)') {
        # Squirrel apps (Discord, Teams classic...) start through Update.exe; use the real program for the icon.
        $real = Get-ChildItem -Path (Join-Path (Split-Path $exe) 'app-*') -Filter $matches[1] -Recurse -Depth 1 -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($real) { $exe = $real.FullName; $iconPath = $real.FullName }
    }
    $sub = if ($exe) { Split-Path $exe -Leaf } else { 'Startup entry' }
    Add-Tweak -Id "startup|$($s.Approved)|$($s.Name)" -Tab 'Startup Apps' -Level $level -Name $displayName -Desc $s.Command -Data $s `
        -Icon $iconPath -Sub $sub -Group $group -Apply {
        param($T)
        $ft = [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())
        Set-Reg $T.Data.Approved $T.Data.Name ([byte[]](@(3, 0, 0, 0) + $ft)) 'Binary'
        Log '   will not start with Windows anymore'
    }
}

# ===== Debloat Apps: Microsoft Store apps (only what is installed) ===========
$AppCatalog = @(
    @('Microsoft.BingNews', 'News', 1), @('Microsoft.BingWeather', 'Weather', 1), @('Microsoft.BingFinance', 'Money', 1),
    @('Microsoft.BingSports', 'Sports', 1), @('Microsoft.Getstarted', 'Tips', 1), @('Clipchamp.Clipchamp', 'Clipchamp', 1),
    @('Microsoft.MicrosoftSolitaireCollection', 'Solitaire Collection', 1), @('Microsoft.GetHelp', 'Get Help', 1),
    @('Microsoft.WindowsFeedbackHub', 'Feedback Hub', 1), @('Microsoft.PowerAutomateDesktop', 'Power Automate', 1),
    @('MicrosoftCorporationII.MicrosoftFamily', 'Family Safety', 1), @('Microsoft.Windows.DevHome', 'Dev Home', 1),
    @('Microsoft.MicrosoftJournal', 'Journal', 1), @('Microsoft.Whiteboard', 'Whiteboard', 1), @('Microsoft.WindowsMaps', 'Maps', 1),
    @('Microsoft.People', 'People', 1), @('Microsoft.Microsoft3DViewer', '3D Viewer', 1), @('Microsoft.MixedReality.Portal', 'Mixed Reality Portal', 1),
    @('Microsoft.SkypeApp', 'Skype', 1), @('Microsoft.MicrosoftOfficeHub', 'Microsoft 365 hub', 1), @('Microsoft.549981C3F5F10', 'Cortana', 1),
    @('Microsoft.Copilot', 'Copilot', 1), @('Microsoft.Windows.Ai.Copilot.Provider', 'Copilot provider', 1), @('Microsoft.MicrosoftPCManager', 'PC Manager', 1),
    @('Microsoft.MSPaint', 'Paint 3D', 1), @('Microsoft.Print3D', 'Print 3D', 1), @('Microsoft.Wallet', 'Wallet', 1), @('Microsoft.Messaging', 'Messaging', 1),
    @('Microsoft.OneConnect', 'Mobile Plans', 1), @('Microsoft.Edge.GameAssist', 'Edge Game Assist', 1),
    @('*CandyCrush*', 'Candy Crush', 1), @('*Disney*', 'Disney+', 1), @('*Facebook*', 'Facebook', 1), @('*Instagram*', 'Instagram', 1),
    @('*TikTok*', 'TikTok', 1), @('AmazonVideo.PrimeVideo', 'Prime Video', 1), @('*LinkedIn*', 'LinkedIn', 1),
    @('Microsoft.BingSearch', 'Bing Search', 2), @('Microsoft.Todos', 'Microsoft To Do', 2), @('Microsoft.OutlookForWindows', 'Outlook (new)', 2),
    @('MSTeams', 'Microsoft Teams', 2), @('MicrosoftTeams', 'Teams (personal)', 2), @('MicrosoftCorporationII.QuickAssist', 'Quick Assist', 2),
    @('Microsoft.ZuneVideo', 'Movies & TV', 2), @('Microsoft.OfficePushNotificationUtility', 'Office notifications', 2),
    @('Microsoft.XboxSpeechToTextOverlay', 'Xbox speech-to-text', 2), @('Microsoft.WindowsCommunicationsApps', 'Mail and Calendar', 2),
    @('Microsoft.Office.OneNote', 'OneNote (Store)', 2),
    @('Microsoft.ZuneMusic', 'Media Player', 3), @('Microsoft.WindowsAlarms', 'Clock', 3), @('Microsoft.WindowsSoundRecorder', 'Sound Recorder', 3),
    @('Microsoft.MicrosoftStickyNotes', 'Sticky Notes', 3), @('Microsoft.YourPhone', 'Phone Link', 3),
    @('MicrosoftWindows.CrossDevice', 'Cross Device', 3), @('MicrosoftWindows.Client.WebExperience', 'Widgets', 3),
    @('Microsoft.XboxGamingOverlay', 'Xbox Game Bar', 0)
)
$installed = @()
try { if ($isAdmin) { $installed = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } else { $installed = @(Get-AppxPackage -ErrorAction Stop) } }
catch { try { $installed = @(Get-AppxPackage -ErrorAction Stop) } catch {} }
$installed = @($installed | Sort-Object Name -Unique)
$catalogMatched = @{}
foreach ($a in $AppCatalog) {
    $hit = @($installed | Where-Object { $_.Name -like $a[0] })
    if (-not $hit) { continue }
    foreach ($h in $hit) { $catalogMatched[$h.Name] = $true }
    $warn = $null
    if ($a[0] -eq 'Microsoft.XboxGamingOverlay') { $warn = 'Some games use Game Bar for screenshots and the Xbox party overlay.' }
    Add-Tweak -Id "app|$($a[0])" -Tab 'Debloat Apps' -Group 'Microsoft apps' -Level $a[2] -NoUndo -Name $a[1] -Sub 'Store app' `
        -Icon (Get-AppxLogo $hit[0]) -Desc "Removes $($hit[0].Name). Reinstall it from the Microsoft Store if you miss it." `
        -Warn $warn -Data $a[0] -Apply { param($T) Remove-App $T.Data }
}

# Other Store apps you installed yourself (never ticked by a preset)
$ProtectedAppx = 'WindowsStore|StorePurchase|DesktopAppInstaller|WindowsCalculator|Windows\.Photos|WindowsNotepad|WindowsTerminal|^Microsoft\.Paint$|ScreenSketch|SecHealthUI|Extension|WinAppRuntime|VCLibs|NET\.Native|UI\.Xaml|NVIDIA|AMD|AdvancedMicroDevices|Dolby|Realtek|Intel|Lenovo|LegionLighting|ASUS|AD2F1837|DellInc|XboxIdentityProvider|LanguageExperiencePack|Ink\.Handwriting|Narrator|Winget|ApplicationCompatibility|aimgr|^MicrosoftWindows\.|^Microsoft\.Windows\.|WindowsAppRuntime|Services\.Store|GamingApp|XboxApp'
foreach ($pkg in $installed) {
    if ($catalogMatched.ContainsKey($pkg.Name) -or $pkg.IsFramework -or $pkg.SignatureKind -eq 'System' -or $pkg.Name -match $ProtectedAppx) { continue }
    if ($pkg.SignatureKind -ne 'Store' -and $pkg.SignatureKind -ne 'Developer') { continue }
    $dn = Get-AppxDisplayName $pkg
    Add-Tweak -Id "app|$($pkg.Name)" -Tab 'Debloat Apps' -Group 'Other Store apps' -Level 0 -NoUndo -Name $dn -Sub 'Store app' `
        -Icon (Get-AppxLogo $pkg) -Desc "Removes $($pkg.Name). Reinstall it from the Microsoft Store if you miss it." `
        -Data $pkg.Name -Apply { param($T) Remove-App $T.Data }
}

$OneDriveSetup = @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") + @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\OneDrive\*\OneDriveSetup.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName)
$OneDriveSetup = @($OneDriveSetup | Where-Object { Test-Path $_ })
if ($OneDriveSetup -and (Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe")) {
    Add-Tweak -Id 'app|onedrive' -Tab 'Debloat Apps' -Group 'Microsoft apps' -Level 0 -NoUndo -Name 'OneDrive' -Sub 'Desktop app' -Data $OneDriveSetup[0] `
        -Icon "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe" -Desc 'Uninstalls the OneDrive sync app.' `
        -Warn 'Files that only live in the cloud (cloud icon) stay online and will not open from this PC. Download anything you need first.' `
        -Apply {
        param($T)
        if (-not $DryRun) { Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue }
        Invoke-Cmd $T.Data @('/uninstall')
    }
}

# ===== Debloat Apps: desktop programs downloaded from the web =================
$SkipPrograms = 'Visual C\+\+|\.NET|Redistributable|Runtime|Driver|Chipset|WebView2|SDK|Update Health|Microsoft Update|KB\d{6,}|NVIDIA (Graphics|PhysX|HD Audio|FrameView|USBC|Install|Display|Ansel|Container|Virtual|Telemetry)|^NVIDIA App$|AMD (Software|Chipset|Ryzen|Settings|Install|Display)|Realtek|Intel\(R\)|Dolby|Synaptics|Elan|Bonjour|Microsoft Edge|PowerShell|Python Launcher|PC Health Check|GameInput|Vulkan|Anti-?Cheat|BattlEye|Riot Vanguard|Lenovo (Vantage Service|System Interface|Hotkeys)|ASUS (System Control|Framework)|^HP (System Event|Hotkey)|Windows Subsystem|OneDrive|Teams Machine-Wide|Office 16 Click-to-Run|Microsoft Search in Bing|Windows App Certification|Windows Software Development|Microsoft GameInput|Epic Online Services|Steamworks Common|Maintenance Service|Application Compatibility Fix|SENetFilter'
$Bloat2 = 'WebAdvisor|WildTangent|ExpressVPN|Booking\.com|Driver ?Booster|Driver ?Easy|IObit|Advanced SystemCare|Reimage|Restoro|PC App Store|WinZip|Ask Toolbar|Bing Wallpaper|Dropbox Promotion|Amazon Assistant|Cleanup|TuneUp|CCleaner|Glary|Wise Care|Opera Browser Assistant|Hola|Avast Secure Browser|AVG Secure Browser|ByteFence|Segurazo|Web Companion'
$Bloat3 = 'McAfee|Norton'
$seen = @{}
foreach ($app in ($AllUninstall | Sort-Object DisplayName)) {
    $name = "$($app.DisplayName)".Trim()
    if ($seen.ContainsKey($name)) { continue }
    $seen[$name] = $true
    if ($app.SystemComponent -eq 1 -or $app.ParentKeyName -or "$($app.ReleaseType)" -match 'Update|Hotfix') { continue }
    if ($name -match $SkipPrograms -or $name -match $BrowserNames) { continue }
    $level = 0
    if ($name -match $Bloat2) { $level = 2 } elseif ($name -match $Bloat3) { $level = 3 }
    $warn = $null
    if ($level -eq 3) { $warn = 'Antivirus trial. Windows Defender takes over automatically after it is removed.' }
    $pub = "$($app.Publisher)".Trim(); if (-not $pub) { $pub = 'Desktop program' }
    $size = ''; if ($app.EstimatedSize) { $size = ('  ({0:N0} MB)' -f ($app.EstimatedSize / 1024)) }
    Add-Tweak -Id "w32|$name" -Tab 'Debloat Apps' -Group 'Desktop programs' -Level $level -NoUndo -Name $name -Sub $pub `
        -Icon (Get-ProgramIconPath $app) -Desc "Runs the uninstaller for $name$size. Some programs open their own uninstall window." `
        -Warn $warn -Data $app -Apply { param($T) Invoke-Uninstall $T.Data }
}

# ===== Laptop & GPU ==========================================================
$HwTab = 'Laptop & GPU'
$CS = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$ProductName = "$((Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).Version)"
$Maker = "$($CS.Manufacturer)".Trim()
$ModelName = "$($CS.Model)".Trim()
if ($Maker -match 'Lenovo' -and $ProductName) { $ModelName = $ProductName }   # Lenovo puts the friendly name here
$Brand = 'Other'
$brandText = "$Maker $ModelName"
if ($brandText -match 'Alienware') { $Brand = 'Alienware' }
elseif ($brandText -match 'Lenovo') { $Brand = 'Lenovo' }
elseif ($brandText -match 'ASUS') { $Brand = 'ASUS' }
elseif ($brandText -match 'Dell') { $Brand = 'Dell' }
elseif ($brandText -match 'HP|Hewlett') { $Brand = 'HP' }
elseif ($brandText -match 'Micro-Star|MSI') { $Brand = 'MSI' }
elseif ($brandText -match 'Acer') { $Brand = 'Acer' }
elseif ($brandText -match 'Razer') { $Brand = 'Razer' }
elseif ($brandText -match 'GIGABYTE|AORUS') { $Brand = 'Gigabyte' }
$GpuNames = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object Name)
$IsLaptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
if ($FakeBrand -and $DryRun) { $Brand = $FakeBrand; $Maker = $FakeBrand; $IsLaptop = $true }

function Find-GameExes {
    $roots = New-Object System.Collections.Generic.List[string]
    $man = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-Path $man) {
        foreach ($f in (Get-ChildItem $man -Filter *.item -ErrorAction SilentlyContinue)) {
            try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; if ($j.InstallLocation -and (Test-Path -LiteralPath $j.InstallLocation)) { $roots.Add($j.InstallLocation) } } catch {}
        }
    }
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $libs = @($steam -replace '/', '\')
        $vdf = Join-Path $libs[0] 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) { foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') } }
        foreach ($l in ($libs | Select-Object -Unique)) {
            $c = Join-Path $l 'steamapps\common'
            if (Test-Path $c) { Get-ChildItem -LiteralPath $c -Directory -ErrorAction SilentlyContinue | ForEach-Object { $roots.Add($_.FullName) } }
        }
    }
    foreach ($r in 'C:\Riot Games\VALORANT\live', 'C:\Riot Games\League of Legends\Game') { if (Test-Path $r) { $roots.Add($r) } }
    $skip = 'unins|crash|report|launcher|setup|redist|dxsetup|helper|easyanticheat|eac_launcher|beservice|battleye|cefprocess|webhelper|installer|updater|prereq|dotnet|vcredist|benchmark|^7z|uninstall|overlay'
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -Filter *.exe -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch $skip -and $_.FullName -notmatch '\\Engine\\(Binaries|Extras|Programs)\\|ShaderCompile|TraceServer|XGEControl' } |
            Select-Object -First 15 | ForEach-Object { $found.Add($_.FullName) }
        Update-UI
    }
    $rb = Get-ChildItem "$env:LOCALAPPDATA\Roblox\Versions\*\RobloxPlayerBeta.exe" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($rb) { $found.Add($rb.FullName) }
    return @($found | Select-Object -Unique)
}

if ($GpuNames.Count -ge 2) {
    Add-Tweak -Id 'gpu-pref' -Tab $HwTab -Level 1 -Name 'Run games on the dedicated GPU' `
        -Desc 'Works on every brand (ASUS, Alienware, OMEN, MSI, Acer, Lenovo, desktops with two GPUs). Finds your Steam, Epic, Riot and Roblox games and sets each one to "High performance" in Windows graphics settings. Run it again after installing new games.' `
        -Apply {
        $exes = @(Find-GameExes)
        if (-not $exes) { Log '   no games found in Steam, Epic, Riot or Roblox folders'; return }
        foreach ($e in $exes) {
            Log "   $(Split-Path $e -Leaf) -> high-performance GPU"
            Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $e 'GpuPreference=2;' 'String'
        }
        Log "   $($exes.Count) game file(s) set"
    }
}

# --- ASUS ROG / TUF (ATK WMI, same switches Armoury Crate and G-Helper use)
$Asus = $null
if ($isAdmin -and $Brand -eq 'ASUS') { $Asus = Get-WmiObject -Namespace root\wmi -Class AsusAtkWmi_WMNB -ErrorAction SilentlyContinue | Select-Object -First 1 }
$ASUS_PERF = 0x00120075; $ASUS_MUX = 0x00090016; $ASUS_ECO = 0x00090020
function Get-AsusDev([uint32]$Id) {
    try {
        $w = Get-WmiObject -Namespace root\wmi -Class AsusAtkWmi_WMNB -ErrorAction Stop | Select-Object -First 1
        $s = [uint32]$w.DSTS($Id).device_status
        if (($s -band 0x10000) -and $s -lt 0x01000000) { return [int]($s -band 0xFFFF) }
    } catch {}
    return -1
}
function Set-AsusDev([uint32]$Id, [uint32]$Value) {
    Log ('   ASUS device 0x{0:X8} -> {1}' -f $Id, $Value)
    if ($DryRun) { return }
    $w = Get-WmiObject -Namespace root\wmi -Class AsusAtkWmi_WMNB -ErrorAction Stop | Select-Object -First 1
    [void]$w.DEVS($Id, $Value)
}
if ($Asus) {
    if ((Get-AsusDev $ASUS_PERF) -ge 0) {
        Add-Tweak -Id 'asus-perf' -Tab $HwTab -Level 0 -Name 'ASUS Turbo mode' `
            -Desc 'Same as Turbo in Armoury Crate (or Fn+F5). Full CPU and GPU power, louder fans. Armoury Crate may switch it back when it starts.' `
            -Apply {
            Save-Original @{ kind = 'asus'; key = 'asus|perf'; id = $ASUS_PERF; value = (Get-AsusDev $ASUS_PERF) }
            Set-AsusDev $ASUS_PERF 1
        }
    }
    if ((Get-AsusDev $ASUS_MUX) -ge 0) {
        Add-Tweak -Id 'asus-mux' -Tab $HwTab -Level 0 -Reboot -Name 'ASUS Ultimate GPU mode (MUX, dGPU only)' `
            -Desc 'Same as "Ultimate" GPU mode in Armoury Crate. The NVIDIA or AMD GPU drives the screen directly for the lowest latency and highest FPS. Turns Eco mode off first if it is on.' `
            -Warn 'Battery life drops a lot. Switch back with Undo, Armoury Crate or G-Helper.' `
            -Apply {
            $eco = Get-AsusDev $ASUS_ECO
            Save-Original @{ kind = 'asus'; key = 'asus|mux'; id = $ASUS_MUX; value = (Get-AsusDev $ASUS_MUX) }
            if ($eco -eq 1) {
                Save-Original @{ kind = 'asus'; key = 'asus|eco'; id = $ASUS_ECO; value = 1 }
                Set-AsusDev $ASUS_ECO 0
                if (-not $DryRun) { Start-Sleep -Seconds 3 }
            }
            Set-AsusDev $ASUS_MUX 0
        }
    }
}

# --- Brands without a safe Windows switch: open the right app and show where the setting is
$VendorGuide = @{
    'HP'        = @{ App = 'OMEN Gaming Hub'; Search = 'OMEN'; Steps = 'In OMEN Gaming Hub open Performance Control and set Graphics Switcher (Display Mode) to Discrete, then restart. Victus models use the same app.' }
    'Alienware' = @{ App = 'NVIDIA Control Panel'; Search = 'NVIDIA Control Panel'; Steps = 'In NVIDIA Control Panel go to Display > Manage Display Mode and pick "NVIDIA GPU only", then restart. If it is missing, turn off Hybrid Graphics / Advanced Optimus in the BIOS (press F2 at boot).' }
    'Dell'      = @{ App = 'NVIDIA Control Panel'; Search = 'NVIDIA Control Panel'; Steps = 'Dell G-series: NVIDIA Control Panel > Display > Manage Display Mode > "NVIDIA GPU only" if your model has it, or turn off Hybrid Graphics in the BIOS (F2 at boot).' }
    'MSI'       = @{ App = 'MSI Center'; Search = 'MSI Center'; Steps = 'In MSI Center open Features > General Settings > GPU Switch, pick Discrete Graphics Mode, then restart.' }
    'Acer'      = @{ App = 'PredatorSense / NitroSense'; Search = 'Sense'; Steps = 'Newer Predator and Nitro models: NVIDIA Control Panel > Display > Manage Display Mode > "NVIDIA GPU only". Some models have a GPU mode switch in PredatorSense or in the BIOS (F2 at boot).' }
    'Razer'     = @{ App = 'Razer Synapse'; Search = 'Synapse'; Steps = 'In Razer Synapse open System > Performance and set GPU Mode to Discrete, then restart.' }
    'Gigabyte'  = @{ App = 'GIGABYTE Control Center'; Search = 'Control Center'; Steps = 'In GIGABYTE Control Center look for GPU Switch / Display Mode and pick Discrete (dGPU), then restart. NVIDIA Control Panel > Manage Display Mode works on newer models too.' }
}
if ($IsLaptop -and $VendorGuide.ContainsKey($Brand)) {
    $vg = $VendorGuide[$Brand]
    Add-Tweak -Id 'vendor-mux' -Tab $HwTab -Level 0 -Guide -Data $vg -Name "Discrete GPU only on your $Brand (opens $($vg.App))" `
        -Desc "$($vg.Steps) If you cannot find the option, your laptop has no MUX switch; 'Run games on the dedicated GPU' above still makes games use it." `
        -Apply {
        param($T)
        Log "   $($T.Data.Steps)"
        $app = Get-StartApps -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$($T.Data.Search)*" } | Select-Object -First 1
        if (-not $app) { Log "   $($T.Data.App) is not installed. Get it from your laptop maker's website or the Microsoft Store." 'warn'; return }
        Log "   opening $($app.Name)"
        if (-not $DryRun) { Start-Process "shell:AppsFolder\$($app.AppID)" }
    } -Undo { Log '   switch it back in the same app' }
}

# --- Lenovo Legion / LOQ
$Gz = $null
if ($isAdmin) { $Gz = Get-WmiObject -Namespace root\WMI -Class LENOVO_GAMEZONE_DATA -ErrorAction SilentlyContinue }
if ($Gz) {
    Add-Tweak -Id 'legion-perf' -Tab $HwTab -Level 0 -Name 'Lenovo Performance thermal mode' `
        -Desc 'Same as pressing Fn+Q until the power light is red. Full GPU and CPU power, louder fans.' `
        -Apply {
        $gz = Get-WmiObject -Namespace root\WMI -Class LENOVO_GAMEZONE_DATA
        $cur = $gz.GetSmartFanMode().Data
        Save-Original @{ kind = 'legion'; key = 'legion|fan'; what = 'fan'; value = $cur }
        Log "   thermal mode $cur -> 3"
        if (-not $DryRun) { $gz.SetSmartFanMode(3) | Out-Null }
    }
    Add-Tweak -Id 'legion-dgpu' -Tab $HwTab -Level 0 -Reboot -Name 'Lenovo discrete GPU only (Hybrid mode off)' `
        -Desc 'Flips the MUX switch so the NVIDIA GPU drives the screen directly. Lower latency and higher FPS, but much shorter battery life.' `
        -Apply {
        $gz = Get-WmiObject -Namespace root\WMI -Class LENOVO_GAMEZONE_DATA
        if ($gz.IsSupportGSync().Data -ne 1) { throw 'This model has no MUX switch. Use BIOS > Configuration > Graphics Device instead.' }
        $cur = $gz.GetGSyncStatus().Data
        Save-Original @{ kind = 'legion'; key = 'legion|mux'; what = 'mux'; value = $cur }
        Log "   MUX $cur -> 1 (dGPU only)"
        if (-not $DryRun) { $gz.SetGSyncStatus(1) | Out-Null }
    }
}

# ---------------------------------------------------------------- run engine
function New-RestorePoint {
    Log 'Creating a restore point first (this can take a minute)...'
    if ($DryRun) { Log '   [dry] skipped'; return }
    $job = Start-Job -ScriptBlock {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $old = (Get-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
            Checkpoint-Computer -Description ('TweakHub {0:yyyy-MM-dd HH:mm}' -f (Get-Date)) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            'ok'
        } catch { "fail: $($_.Exception.Message)" }
        finally {
            if ($null -eq $old) { Remove-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
            else { Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value $old -Type DWord }
        }
    }
    while ($job.State -eq 'Running') { Update-UI; Start-Sleep -Milliseconds 150 }
    $r = Receive-Job $job; Remove-Job $job -Force
    if ("$r" -eq 'ok') { Log 'Restore point created.' } else { Log "Restore point could not be created ($r). Continuing; TweakHub's own undo still works." 'warn' }
}

function Restart-ChangedNics {
    foreach ($name in @($script:NicsToRestart.Keys)) {
        Log "Restarting network adapter '$name' (internet drops for a few seconds)"
        if (-not $DryRun) { Restart-NetAdapter -Name $name -Confirm:$false -ErrorAction SilentlyContinue }
    }
    $script:NicsToRestart = @{}
}

function Get-Selected { @($script:Tweaks | Where-Object { $_.CheckBox -and $_.CheckBox.IsChecked }) }

function Invoke-Run([string]$Mode) {
    $sel = @(Get-Selected)
    if (-not $sel) { [void][Windows.MessageBox]::Show($script:Window, 'Tick at least one item first.', $AppName); return }

    if ($Mode -eq 'apply') {
        $noUndo = @($sel | Where-Object NoUndo)
        $msg = "Apply $($sel.Count) tweak(s)?"
        if ($noUndo) { $msg += "`n`n$($noUndo.Count) of them cannot be undone by TweakHub (app removals, cleanups)." }
        if ($script:RestoreBox.IsChecked) { $msg += "`n`nA Windows restore point is created first." }
    } else {
        $msg = "Undo $($sel.Count) tweak(s)? Original values saved by TweakHub will be put back."
    }
    if ($DryRun) { $msg += "`n`nDRY RUN: nothing will actually change." }
    if (-not $SelfTest) {
        if ([Windows.MessageBox]::Show($script:Window, $msg, $AppName, 'YesNo', 'Question') -ne 'Yes') { return }
    }

    $script:Running = $true
    $script:RunBtn.IsEnabled = $false; $script:UndoBtn.IsEnabled = $false
    $script:Progress.Maximum = $sel.Count; $script:Progress.Value = 0; $script:Progress.Visibility = 'Visible'
    $ok = 0; $fail = 0; $reboot = $false
    try {
        if ($Mode -eq 'apply' -and $script:RestoreBox.IsChecked) { New-RestorePoint }
        $list = $sel
        if ($Mode -eq 'undo') { [array]::Reverse($list) }
        $i = 0
        foreach ($t in $list) {
            $i++
            $script:StatusText.Text = "$i / $($list.Count)  $($t.Name)"
            $script:Progress.Value = $i - 1
            Log ("{0} {1}" -f $(if ($Mode -eq 'apply') { '>>' } else { '<<' }), $t.Name)
            $script:CurrentId = $t.Id
            try {
                if ($Mode -eq 'apply') {
                    & $t.Apply $t
                    if ($t.AppliedBadge) { $t.AppliedBadge.Visibility = 'Visible' }
                } else {
                    $entries = $script:Backup[$t.Id]
                    if ($entries) {
                        $arr = @($entries); [array]::Reverse($arr)
                        foreach ($e in $arr) { Restore-Entry $e }
                    }
                    if ($t.Undo) { & $t.Undo $t }
                    if (-not $entries -and -not $t.Undo) {
                        if ($t.NoUndo) { Log '   cannot be undone here' 'warn' } else { Log '   nothing saved for this one (it was not applied by TweakHub)' }
                    }
                    if (-not $DryRun) { [void]$script:Backup.Remove($t.Id) }
                    if ($t.AppliedBadge) { $t.AppliedBadge.Visibility = 'Collapsed' }
                }
                $ok++
                if ($t.Reboot) { $reboot = $true }
            } catch {
                $fail++
                Log "   failed: $($_.Exception.Message)" 'error'
            }
            $script:CurrentId = $null
            Save-Backup
        }
        Restart-ChangedNics
    } finally {
        $script:RunBtn.IsEnabled = $true; $script:UndoBtn.IsEnabled = $true
        $script:Progress.Visibility = 'Hidden'
        $script:Running = $false
    }
    $verb = if ($Mode -eq 'apply') { 'applied' } else { 'undone' }
    $summary = "$ok $verb, $fail failed."
    if ($reboot) { $summary += ' Restart the PC to finish.' }
    Log $summary
    $script:StatusText.Text = $summary
    if ($reboot -and -not $DryRun) {
        if ([Windows.MessageBox]::Show($script:Window, "$summary`n`nRestart now?", $AppName, 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force }
    }
}

# ---------------------------------------------------------------- UI
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TweakHub" Width="1180" Height="800" MinWidth="960" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#0D0F13" Foreground="#E6E8EE"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#1E222B"/>
      <Setter Property="Foreground" Value="#E6E8EE"/>
      <Setter Property="BorderBrush" Value="#343B4A"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="MaxWidth" Value="420"/>
      <Setter Property="ContentTemplate">
        <Setter.Value>
          <DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap"/></DataTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="12"/>
      <Setter Property="MinWidth" Value="12"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="3,4">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border x:Name="t" CornerRadius="3" Background="#2C323E"/>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="#465062"/></Trigger>
                        <Trigger Property="IsDragging" Value="True"><Setter TargetName="t" Property="Background" Value="#566176"/></Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="#1C2029"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#3B82F6" Offset="0"/><GradientStop Color="#8B5CF6" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#A3ABBA"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid>
              <Border x:Name="b" Background="Transparent" CornerRadius="7" Padding="10,9">
                <ContentPresenter/>
              </Border>
              <Border x:Name="bar" Width="3" Height="16" CornerRadius="2" HorizontalAlignment="Left" Background="#3B82F6" Visibility="Hidden"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#171A21"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1B2130"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Tick" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6E8EE"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="#454D5E" Background="#101319" VerticalAlignment="Center">
                <Path x:Name="mark" Data="M3,8.5 L6.5,12 L13,4.5" Stroke="White" StrokeThickness="2.2" Visibility="Collapsed"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
              </Border>
              <ContentPresenter x:Name="cp" Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="Content" Value="{x:Null}"><Setter TargetName="cp" Property="Margin" Value="0"/></Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="#7C8597"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="#3B82F6"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#3B82F6"/>
                <Setter TargetName="mark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E6E8EE"/>
      <Setter Property="Background" Value="#1D212A"/>
      <Setter Property="BorderBrush" Value="#2C3240"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#7AA7F7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,16,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button"><ContentPresenter/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="Root" Background="#0D0F13">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#111318" BorderBrush="#1F232C" BorderThickness="0,0,0,1" Padding="22,16">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Border Width="42" Height="42" CornerRadius="11" Margin="0,0,14,0" VerticalAlignment="Center">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#3B82F6" Offset="0"/><GradientStop Color="#8B5CF6" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <TextBlock Text="&#xE945;" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="TweakHub" FontSize="21" FontWeight="SemiBold"/>
            <TextBlock x:Name="VersionText" Foreground="#5E6678" FontSize="12" VerticalAlignment="Bottom" Margin="8,0,0,4"/>
            <Border x:Name="DryBadge" Visibility="Collapsed" Background="#33260A" CornerRadius="9" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="DRY RUN" Foreground="#F5B841" FontSize="11" FontWeight="SemiBold"/>
            </Border>
          </StackPanel>
          <TextBlock x:Name="SysInfo" Foreground="#7C8597" FontSize="12" Margin="0,4,16,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <StackPanel Grid.Column="2" VerticalAlignment="Center">
          <TextBlock Text="STRENGTH" Foreground="#5E6678" FontSize="10.5" FontWeight="SemiBold" Margin="2,0,0,6"/>
          <StackPanel x:Name="PresetHost" Orientation="Horizontal"/>
        </StackPanel>
      </Grid>
    </Border>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="236"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Background="#0F1116" BorderBrush="#1F232C" BorderThickness="0,0,1,0" Padding="12,14">
        <StackPanel x:Name="NavHost"/>
      </Border>
      <Grid Grid.Column="1">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Border Margin="26,16,26,4" Background="#13161C" BorderBrush="#232833" BorderThickness="1" CornerRadius="9" Height="40">
          <Grid>
            <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#5E6678" VerticalAlignment="Center" Margin="14,0,0,0"/>
            <TextBlock x:Name="SearchHint" Text="Search every tweak and app (mouse, wifi, discord, edge...)" Foreground="#5E6678" VerticalAlignment="Center" Margin="40,0,0,0" IsHitTestVisible="False"/>
            <TextBox x:Name="SearchBox" Background="Transparent" BorderThickness="0" Foreground="#E6E8EE" CaretBrush="#E6E8EE" VerticalAlignment="Center" Margin="36,0,12,0" FontSize="13"/>
          </Grid>
        </Border>
        <ScrollViewer x:Name="Scroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="26,12,22,20"/>
      </Grid>
    </Grid>

    <Border Grid.Row="2" Background="#0A0C10" BorderBrush="#1F232C" BorderThickness="0,1,0,0">
      <TextBox x:Name="LogBox" Height="110" IsReadOnly="True" Background="Transparent" Foreground="#8D9BB3" BorderThickness="0"
               FontFamily="Cascadia Mono, Consolas" FontSize="12" Padding="18,10" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
    </Border>

    <Border Grid.Row="3" Background="#111318" BorderBrush="#1F232C" BorderThickness="0,1,0,0" Padding="22,12">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <CheckBox x:Name="RestoreBox" Style="{StaticResource Tick}" IsChecked="True" VerticalAlignment="Center">
          <TextBlock Text="Create a restore point first" Foreground="#C4CAD6"/>
        </CheckBox>
        <TextBlock x:Name="StatusText" Grid.Column="1" Foreground="#8A93A5" VerticalAlignment="Center" Margin="24,0" TextTrimming="CharacterEllipsis"/>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <Button x:Name="UndoBtn" Style="{StaticResource Btn}" Margin="0,0,10,0" Padding="16,9">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE7A7;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock Text="Undo selected"/>
            </StackPanel>
          </Button>
          <Button x:Name="RunBtn" Style="{StaticResource Btn}" BorderBrush="#4B8DF8" Padding="30,10">
            <Button.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#2563EB" Offset="0"/><GradientStop Color="#7C3AED" Offset="1"/>
              </LinearGradientBrush>
            </Button.Background>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE768;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="White" VerticalAlignment="Center" Margin="0,0,9,0"/>
              <TextBlock Text="Run Tweaks" FontWeight="SemiBold" FontSize="14" Foreground="White"/>
            </StackPanel>
          </Button>
        </StackPanel>
      </Grid>
    </Border>
    <ProgressBar x:Name="Progress" Grid.Row="3" Height="3" VerticalAlignment="Top" Visibility="Hidden" Minimum="0"/>
  </Grid>
</Window>
'@

$script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'SysInfo', 'VersionText', 'DryBadge', 'PresetHost', 'NavHost', 'Scroll', 'LogBox', 'RestoreBox', 'StatusText', 'UndoBtn', 'RunBtn', 'SearchBox', 'SearchHint', 'Progress') {
    Set-Variable -Name $n -Scope Script -Value $script:Window.FindName($n)
}
$script:LogBox = $null   # keep logging to console until the window is ready
$script:Window.Title = "$AppName $AppVersion"
$script:VersionText.Text = "v$AppVersion"
if ($DryRun) { $script:DryBadge.Visibility = 'Visible' }

# Dark title bar on Windows 10 20H1+ and Windows 11
$script:Window.Add_SourceInitialized({
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:Window).Handle
            $v = 1
            if ([TweakHubNative11]::DwmSetWindowAttribute($h, 20, [ref]$v, 4) -ne 0) { [void][TweakHubNative11]::DwmSetWindowAttribute($h, 19, [ref]$v, 4) }
        } catch {}
    })

$Conv = New-Object System.Windows.Media.BrushConverter
$script:BrushCache = @{}
function Brush([string]$hex) {
    if (-not $script:BrushCache.ContainsKey($hex)) { $b = $Conv.ConvertFromString($hex); $b.Freeze(); $script:BrushCache[$hex] = $b }
    return $script:BrushCache[$hex]
}
function Glyph([int]$Code) { return [string][char]$Code }

$LevelInfo = @{
    1 = @{ Label = 'Light'; Fg = '#4ADE80'; Bg = '#11291B' }
    2 = @{ Label = 'Balanced'; Fg = '#FBBF24'; Bg = '#2E240B' }
    3 = @{ Label = 'Max'; Fg = '#F87171'; Bg = '#341515' }
    0 = @{ Label = 'Manual'; Fg = '#94A3B8'; Bg = '#1C222C' }
}

function New-Badge([string]$Text, [string]$Fg, [string]$Bg) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Brush $Bg; $b.CornerRadius = 9; $b.Padding = '8,2,8,2'; $b.Margin = '6,0,0,0'; $b.VerticalAlignment = 'Top'
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.Foreground = Brush $Fg; $t.FontSize = 11; $t.FontWeight = 'SemiBold'
    $b.Child = $t
    return $b
}

function New-IconElement($T, [int]$Size) {
    $img = $null
    if ($T.Icon) { $img = Get-IconImage $T.Icon }
    if ($img) {
        $i = New-Object System.Windows.Controls.Image
        $i.Source = $img; $i.Width = $Size; $i.Height = $Size; $i.VerticalAlignment = 'Center'
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($i, 'HighQuality')
        return $i
    }
    $b = New-Object System.Windows.Controls.Border
    $b.Width = $Size; $b.Height = $Size; $b.CornerRadius = [Math]::Round($Size / 4); $b.Background = Brush '#232935'; $b.VerticalAlignment = 'Center'
    $tb = New-Object System.Windows.Controls.TextBlock
    $letter = ($T.Name -replace '[^A-Za-z0-9]', '')
    if ($letter) { $letter = $letter.Substring(0, 1).ToUpper() } else { $letter = '?' }
    $tb.Text = $letter; $tb.FontWeight = 'SemiBold'; $tb.FontSize = [Math]::Round($Size * 0.45); $tb.Foreground = Brush '#A3ABBA'
    $tb.HorizontalAlignment = 'Center'; $tb.VerticalAlignment = 'Center'
    $b.Child = $tb
    return $b
}

function Set-ItemLook($El) {
    $cb = $El.Tag
    if ($cb.IsChecked) { $El.Background = Brush '#151E33'; $El.BorderBrush = Brush '#2E5BC9' }
    elseif ($El.IsMouseOver) { $El.Background = Brush '#1A1E27'; $El.BorderBrush = Brush '#323948' }
    else { $El.Background = Brush '#15181E'; $El.BorderBrush = Brush '#21252E' }
}

$script:Bulk = $false
$script:NavCounts = @{}
function Update-Count {
    $total = 0
    foreach ($tab in @($script:NavCounts.Keys)) {
        $items = @($script:Tweaks | Where-Object { $_.Tab -eq $tab -and $_.CheckBox })
        $n = @($items | Where-Object { $_.CheckBox.IsChecked }).Count
        $total += $n
        $tb = $script:NavCounts[$tab]
        if ($n) { $tb.Text = "$n/$($items.Count)"; $tb.Foreground = Brush '#7AA7F7' } else { $tb.Text = "$($items.Count)"; $tb.Foreground = Brush '#4E5566' }
    }
    if ($script:StatusText -and -not $script:Running) {
        if ($total) { $script:StatusText.Text = "$total selected" } else { $script:StatusText.Text = 'Pick a strength or tick what you want' }
    }
}

function Connect-Item($T, $El, $Cb) {
    $El.Tag = $Cb; $Cb.Tag = $El
    $T.CheckBox = $Cb; $T.Element = $El
    $Cb.Add_Checked({ param($s, $e) Set-ItemLook $s.Tag; if (-not $script:Bulk) { Update-Count } })
    $Cb.Add_Unchecked({ param($s, $e) Set-ItemLook $s.Tag; if (-not $script:Bulk) { Update-Count } })
    $El.Add_MouseEnter({ param($s, $e) Set-ItemLook $s })
    $El.Add_MouseLeave({ param($s, $e) Set-ItemLook $s })
    $El.Add_MouseLeftButtonUp({ param($s, $e) $s.Tag.IsChecked = -not $s.Tag.IsChecked })
    Set-ItemLook $El
}

function New-Card($T) {
    $card = New-Object System.Windows.Controls.Border
    $card.BorderThickness = 1; $card.CornerRadius = 10; $card.Padding = '16,13,16,13'; $card.Margin = '0,0,0,8'; $card.Cursor = 'Hand'

    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

    $left = New-Object System.Windows.Controls.StackPanel
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $script:Window.FindResource('Tick')
    $titleRow = New-Object System.Windows.Controls.StackPanel; $titleRow.Orientation = 'Horizontal'
    if ($T.Icon) { $ic = New-IconElement $T 20; $ic.Margin = '0,0,9,0'; [void]$titleRow.Children.Add($ic) }
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $T.Name; $title.FontWeight = 'SemiBold'; $title.FontSize = 14; $title.TextWrapping = 'Wrap'; $title.VerticalAlignment = 'Center'
    [void]$titleRow.Children.Add($title)
    $cb.Content = $titleRow
    [void]$left.Children.Add($cb)

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = $T.Desc; $desc.Foreground = Brush '#8590A3'; $desc.TextWrapping = 'Wrap'; $desc.Margin = '28,5,0,0'; $desc.LineHeight = 19
    [void]$left.Children.Add($desc)
    if ($T.Warn) {
        $wrow = New-Object System.Windows.Controls.StackPanel; $wrow.Orientation = 'Horizontal'; $wrow.Margin = '28,7,0,0'
        $wi = New-Object System.Windows.Controls.TextBlock; $wi.Text = Glyph 0xE7BA; $wi.FontFamily = 'Segoe MDL2 Assets'; $wi.Foreground = Brush '#F5B841'; $wi.FontSize = 12; $wi.Margin = '0,2,7,0'; $wi.VerticalAlignment = 'Top'
        $w = New-Object System.Windows.Controls.TextBlock; $w.Text = $T.Warn; $w.Foreground = Brush '#E9B759'; $w.TextWrapping = 'Wrap'; $w.FontSize = 12; $w.MaxWidth = 720
        [void]$wrow.Children.Add($wi); [void]$wrow.Children.Add($w)
        [void]$left.Children.Add($wrow)
    }
    if ($T.Id -eq 'timer-bench') {
        $script:TimerChartHost = New-Object System.Windows.Controls.StackPanel
        $script:TimerChartHost.Margin = '28,12,0,0'
        [void]$left.Children.Add($script:TimerChartHost)
    }
    [void]$grid.Children.Add($left)

    $tags = New-Object System.Windows.Controls.StackPanel
    $tags.Orientation = 'Horizontal'; $tags.VerticalAlignment = 'Top'; $tags.Margin = '12,0,0,0'
    [System.Windows.Controls.Grid]::SetColumn($tags, 1)
    $applied = New-Badge 'Applied' '#4ADE80' '#0F2418'
    if (-not $script:Backup.ContainsKey($T.Id)) { $applied.Visibility = 'Collapsed' }
    $T.AppliedBadge = $applied
    [void]$tags.Children.Add($applied)
    $li = $LevelInfo[$T.Level]
    [void]$tags.Children.Add((New-Badge $li.Label $li.Fg $li.Bg))
    if ($T.Reboot) { [void]$tags.Children.Add((New-Badge 'Restart' '#93C5FD' '#142036')) }
    if ($T.NoUndo) { [void]$tags.Children.Add((New-Badge 'No undo' '#C4B5FD' '#211A35')) }
    if ($T.Guide) { [void]$tags.Children.Add((New-Badge 'Opens app' '#67E8F9' '#0C262C')) }
    [void]$grid.Children.Add($tags)

    $card.Child = $grid
    Connect-Item $T $card $cb
    return $card
}

function New-Tile($T) {
    $tile = New-Object System.Windows.Controls.Border
    $tile.Width = 244; $tile.Height = 60; $tile.BorderThickness = 1; $tile.CornerRadius = 10; $tile.Padding = '12,0,12,0'
    $tile.Margin = '0,0,10,10'; $tile.Cursor = 'Hand'
    $tip = $T.Desc
    if ($T.Warn) { $tip += "`n`nHeads up: $($T.Warn)" }
    $tip += "`n`nPreset level: $($LevelInfo[$T.Level].Label)"
    $tile.ToolTip = $tip

    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $w; $grid.ColumnDefinitions.Add($cd) }
    $icon = New-IconElement $T 30
    [void]$grid.Children.Add($icon)

    $texts = New-Object System.Windows.Controls.StackPanel
    $texts.Margin = '11,0,8,0'; $texts.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($texts, 1)
    $nm = New-Object System.Windows.Controls.TextBlock
    $nm.Text = $T.Name; $nm.FontWeight = 'SemiBold'; $nm.FontSize = 13; $nm.TextTrimming = 'CharacterEllipsis'
    $subRow = New-Object System.Windows.Controls.StackPanel; $subRow.Orientation = 'Horizontal'; $subRow.Margin = '0,2,0,0'
    $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 6; $dot.Height = 6; $dot.Fill = Brush $LevelInfo[$T.Level].Fg; $dot.Margin = '0,0,6,0'; $dot.VerticalAlignment = 'Center'
    $sb = New-Object System.Windows.Controls.TextBlock
    $sb.Text = $T.Sub; $sb.Foreground = Brush '#737D90'; $sb.FontSize = 11.5; $sb.TextTrimming = 'CharacterEllipsis'; $sb.MaxWidth = 150
    [void]$subRow.Children.Add($dot); [void]$subRow.Children.Add($sb)
    if ($T.Warn) {
        $wi = New-Object System.Windows.Controls.TextBlock; $wi.Text = Glyph 0xE7BA; $wi.FontFamily = 'Segoe MDL2 Assets'; $wi.Foreground = Brush '#F5B841'; $wi.FontSize = 10; $wi.Margin = '6,1,0,0'
        [void]$subRow.Children.Add($wi)
    }
    [void]$texts.Children.Add($nm); [void]$texts.Children.Add($subRow)
    [void]$grid.Children.Add($texts)

    $right = New-Object System.Windows.Controls.StackPanel; $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($right, 2)
    $done = New-Object System.Windows.Controls.TextBlock; $done.Text = Glyph 0xE73E; $done.FontFamily = 'Segoe MDL2 Assets'; $done.Foreground = Brush '#4ADE80'; $done.FontSize = 12; $done.Margin = '0,0,8,0'; $done.VerticalAlignment = 'Center'
    if (-not $script:Backup.ContainsKey($T.Id)) { $done.Visibility = 'Collapsed' }
    $T.AppliedBadge = $done
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $script:Window.FindResource('Tick'); $cb.VerticalAlignment = 'Center'
    [void]$right.Children.Add($done); [void]$right.Children.Add($cb)
    [void]$grid.Children.Add($right)

    $tile.Child = $grid
    $T.IsTile = $true
    Connect-Item $T $tile $cb
    return $tile
}

# ---- timer benchmark chart (single series, lower is better, best value labelled)
$script:TimerChartHost = $null
function Show-TimerChart {
    $box = $script:TimerChartHost
    if (-not $box) { return }
    $rows = @(Get-TimerResults $TimerCsv | Sort-Object Res)
    if ($rows.Count -lt 2) { return }
    $best = Get-TimerBest $rows
    $box.Children.Clear()

    $frame = New-Object System.Windows.Controls.Border
    $frame.Background = Brush '#0F1217'; $frame.BorderBrush = Brush '#21252E'; $frame.BorderThickness = 1; $frame.CornerRadius = 9; $frame.Padding = '14,12,14,10'
    $sp = New-Object System.Windows.Controls.StackPanel
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = "Best timer for this PC: $($best.Res.ToString('0.000', $Inv)) ms"; $t1.FontWeight = 'SemiBold'; $t1.FontSize = 13
    $t2 = New-Object System.Windows.Controls.TextBlock
    $low = $rows[0]
    $t2.Text = ('How late Windows wakes from a 1 ms sleep at each timer value (lower is better). Best: {0} ms late. Lowest value {1} ms: {2} ms late. Hover the line for details.' -f `
            $best.Delta.ToString('0.00', $Inv), $low.Res.ToString('0.000', $Inv), $low.Delta.ToString('0.00', $Inv))
    $t2.Foreground = Brush '#7C8597'; $t2.FontSize = 11.5; $t2.TextWrapping = 'Wrap'; $t2.Margin = '0,3,0,10'
    [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)

    $cW = 500.0; $cH = 128.0; $padL = 40.0; $padR = 12.0; $padT = 24.0; $padB = 20.0
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $cW; $cv.Height = $cH; $cv.HorizontalAlignment = 'Left'
    [double]$minX = $rows[0].Res; [double]$maxX = $rows[$rows.Count - 1].Res
    [double]$maxD = ($rows | Measure-Object Delta -Maximum).Maximum
    $step = 0.1; foreach ($s in 0.1, 0.2, 0.25, 0.5, 1, 2, 5) { if ($maxD / $s -le 4) { $step = $s; break } }
    $maxY = [Math]::Ceiling(($maxD * 1.05) / $step) * $step
    if ($maxY -le 0) { $maxY = $step }
    $xOf = { param([double]$v) $padL + ($v - $minX) / ($maxX - $minX) * ($cW - $padL - $padR) }
    $yOf = { param([double]$v) $padT + (1 - [Math]::Max(0.0, $v) / $maxY) * ($cH - $padT - $padB) }

    for ($g = 0.0; $g -le $maxY + 1e-9; $g += $step) {
        $y = & $yOf $g
        $ln = New-Object System.Windows.Shapes.Line
        $ln.X1 = $padL; $ln.X2 = $cW - $padR; $ln.Y1 = $y; $ln.Y2 = $y; $ln.Stroke = Brush '#1E232C'; $ln.StrokeThickness = 1
        [void]$cv.Children.Add($ln)
        $lb = New-Object System.Windows.Controls.TextBlock
        $lb.Text = $g.ToString('0.##', $Inv); $lb.Foreground = Brush '#5E6678'; $lb.FontSize = 10.5; $lb.Width = $padL - 8; $lb.TextAlignment = 'Right'
        [System.Windows.Controls.Canvas]::SetLeft($lb, 0); [System.Windows.Controls.Canvas]::SetTop($lb, $y - 8)
        [void]$cv.Children.Add($lb)
    }
    foreach ($side in 'Left', 'Right') {
        [double]$xv = $minX; if ($side -eq 'Right') { $xv = $maxX }
        $xl = New-Object System.Windows.Controls.TextBlock
        $xl.Text = "$($xv.ToString('0.000', $Inv)) ms"; $xl.Foreground = Brush '#5E6678'; $xl.FontSize = 10.5
        $xl.Width = 70; $xl.TextAlignment = $side
        [double]$xpos = & $xOf $xv
        if ($side -eq 'Left') { [System.Windows.Controls.Canvas]::SetLeft($xl, $xpos) } else { [System.Windows.Controls.Canvas]::SetLeft($xl, $xpos - 70) }
        [System.Windows.Controls.Canvas]::SetTop($xl, $cH - $padB + 4)
        [void]$cv.Children.Add($xl)
    }

    $pl = New-Object System.Windows.Shapes.Polyline
    $pl.Stroke = Brush '#60A5FA'; $pl.StrokeThickness = 2; $pl.StrokeLineJoin = 'Round'
    foreach ($r in $rows) { $pl.Points.Add((New-Object System.Windows.Point (& $xOf $r.Res), (& $yOf $r.Delta))) }
    [void]$cv.Children.Add($pl)

    $bx = & $xOf $best.Res; $by = & $yOf $best.Delta
    $guide = New-Object System.Windows.Shapes.Line
    $guide.X1 = $bx; $guide.X2 = $bx; $guide.Y1 = 14; $guide.Y2 = $cH - $padB; $guide.Stroke = Brush '#3A4252'; $guide.StrokeThickness = 1
    $guide.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('3 3')
    [void]$cv.Children.Add($guide)
    $mk = New-Object System.Windows.Shapes.Ellipse
    $mk.Width = 11; $mk.Height = 11; $mk.Fill = Brush '#60A5FA'; $mk.Stroke = Brush '#0F1217'; $mk.StrokeThickness = 2
    [System.Windows.Controls.Canvas]::SetLeft($mk, $bx - 5.5); [System.Windows.Controls.Canvas]::SetTop($mk, $by - 5.5)
    [void]$cv.Children.Add($mk)
    $bl = New-Object System.Windows.Controls.TextBlock
    $bl.Text = "$($best.Res.ToString('0.000', $Inv)) ms"; $bl.FontSize = 11; $bl.FontWeight = 'SemiBold'; $bl.Foreground = Brush '#E6E8EE'
    $bl.Width = 70; $bl.TextAlignment = 'Center'
    [System.Windows.Controls.Canvas]::SetLeft($bl, [Math]::Min([Math]::Max($bx - 35, $padL), $cW - $padR - 70)); [System.Windows.Controls.Canvas]::SetTop($bl, -4)
    [void]$cv.Children.Add($bl)

    $colW = ($cW - $padL - $padR) / [Math]::Max(1, $rows.Count - 1)
    foreach ($r in $rows) {
        $hit = New-Object System.Windows.Shapes.Rectangle
        $hit.Width = [Math]::Max(6, $colW); $hit.Height = $cH - $padB - $padT + 8; $hit.Fill = Brush '#01000000'
        $hit.ToolTip = ('{0} ms timer: wakes {1} ms late, jitter {2} ms' -f $r.Res.ToString('0.000', $Inv), $r.Delta.ToString('0.000', $Inv), $r.Sd.ToString('0.000', $Inv))
        [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($hit, 0)
        [System.Windows.Controls.Canvas]::SetLeft($hit, (& $xOf $r.Res) - $hit.Width / 2); [System.Windows.Controls.Canvas]::SetTop($hit, $padT - 8)
        [void]$cv.Children.Add($hit)
    }
    [void]$sp.Children.Add($cv)
    $frame.Child = $sp
    [void]$box.Children.Add($frame)
}

# ---- pages, navigation, search
$WifiText = if ($WifiCards) { "Wi-Fi card: $($WifiCards -join ', '). " } else { '' }
$TabInfo = [ordered]@{
    'Performance'          = @{ Icon = 0xE945; Desc = 'Power plan, CPU and GPU scheduling, timer resolution and visual effects.' }
    'Input'                = @{ Icon = 0xE962; Desc = 'Mouse, keyboard and USB latency.' }
    'Network'              = @{ Icon = 0xE701; Desc = "${WifiText}Every setting is matched by name for Intel, Realtek, MediaTek, Qualcomm/Killer and Broadcom cards, and skipped if your card does not have it. Adapters restart once at the end." }
    'Games'                = @{ Icon = 0xE7FC; Desc = 'Game Mode, recording, fullscreen behaviour and per-game priority.' }
    'Browsers'             = @{ Icon = 0xE774; Desc = 'Debloat or remove the browsers installed on this PC.' }
    'Privacy & Background' = @{ Icon = 0xEA18; Desc = 'Telemetry, ads, search, background apps, services and cleanup.' }
    'Startup Apps'         = @{ Icon = 0xE7E8; Desc = 'Apps that start with Windows. Tick one to stop it starting; it stays installed. Hover for the full command.' }
    'Debloat Apps'         = @{ Icon = 0xE74D; Desc = 'Everything installed on this PC: Microsoft apps, Store apps and programs downloaded from the web. Removal cannot be undone by TweakHub. Hover a tile for details.' }
    'Laptop & GPU'         = @{ Icon = 0xE7F8; Desc = "Detected: $Maker $ModelName.  GPUs: $($GpuNames -join ', ')." }
}
$TileTabs = @('Startup Apps', 'Debloat Apps')

function New-PageHeader([string]$Title, [string]$Desc, $Panel, [string]$TabForLinks) {
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $Title; $h.FontSize = 22; $h.FontWeight = 'SemiBold'
    [void]$Panel.Children.Add($h)
    $d = New-Object System.Windows.Controls.TextBlock
    $d.Text = $Desc; $d.Foreground = Brush '#8590A3'; $d.TextWrapping = 'Wrap'; $d.Margin = '0,5,0,10'; $d.MaxWidth = 860; $d.HorizontalAlignment = 'Left'
    [void]$Panel.Children.Add($d)
    if ($TabForLinks) {
        $links = New-Object System.Windows.Controls.StackPanel
        $links.Orientation = 'Horizontal'; $links.Margin = '0,0,0,16'
        foreach ($pair in @(@('Select all', $true), @('Select none', $false))) {
            $lb = New-Object System.Windows.Controls.Button
            $lb.Style = $script:Window.FindResource('Link'); $lb.Content = $pair[0]
            $lb.Tag = @{ Tab = $TabForLinks; Value = $pair[1] }
            $lb.Add_Click({ param($s, $e)
                    $script:Bulk = $true
                    foreach ($t in $script:Tweaks) { if ($t.Tab -eq $s.Tag.Tab -and $t.CheckBox) { $t.CheckBox.IsChecked = $s.Tag.Value } }
                    $script:Bulk = $false; Update-Count })
            [void]$links.Children.Add($lb)
        }
        [void]$Panel.Children.Add($links)
    }
}

function New-GroupHeader([string]$Text, [int]$Count) {
    $g = New-Object System.Windows.Controls.TextBlock
    $g.Text = "$($Text.ToUpper())   $Count"; $g.Foreground = Brush '#5E6678'; $g.FontSize = 11; $g.FontWeight = 'SemiBold'; $g.Margin = '2,6,0,10'
    return $g
}

$script:Containers = New-Object System.Collections.ArrayList
$script:NavButtons = @()
$script:LastNav = $null
$firstNav = $null
foreach ($tab in $TabInfo.Keys) {
    $items = @($script:Tweaks | Where-Object { $_.Tab -eq $tab })
    if (-not $items) { continue }
    $page = New-Object System.Windows.Controls.StackPanel
    New-PageHeader $tab $TabInfo[$tab].Desc $page $tab

    if ($TileTabs -contains $tab) {
        $groups = @($items | ForEach-Object { $_.Group } | Select-Object -Unique)
        foreach ($g in $groups) {
            $gi = @($items | Where-Object { $_.Group -eq $g })
            [void]$page.Children.Add((New-GroupHeader $g $gi.Count))
            $wrap = New-Object System.Windows.Controls.WrapPanel
            $wrap.Margin = '0,0,0,10'
            [void]$script:Containers.Add($wrap)
            foreach ($t in $gi) { $t.Container = $wrap; [void]$wrap.Children.Add((New-Tile $t)) }
            [void]$page.Children.Add($wrap)
        }
    } else {
        $stack = New-Object System.Windows.Controls.StackPanel
        [void]$script:Containers.Add($stack)
        foreach ($t in $items) { $t.Container = $stack; [void]$stack.Children.Add((New-Card $t)) }
        [void]$page.Children.Add($stack)
    }

    $nav = New-Object System.Windows.Controls.RadioButton
    $nav.Style = $script:Window.FindResource('Nav'); $nav.GroupName = 'nav'; $nav.Tag = $page
    $ng = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $w; $ng.ColumnDefinitions.Add($cd) }
    $ni = New-Object System.Windows.Controls.TextBlock
    $ni.Text = Glyph $TabInfo[$tab].Icon; $ni.FontFamily = 'Segoe MDL2 Assets'; $ni.FontSize = 15; $ni.Width = 22; $ni.Margin = '4,0,10,0'; $ni.VerticalAlignment = 'Center'
    $nt = New-Object System.Windows.Controls.TextBlock
    $nt.Text = $tab; $nt.FontSize = 13.5; $nt.VerticalAlignment = 'Center'; $nt.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($nt, 1)
    $nc = New-Object System.Windows.Controls.TextBlock
    $nc.FontSize = 11.5; $nc.VerticalAlignment = 'Center'; $nc.Margin = '6,0,2,0'
    [System.Windows.Controls.Grid]::SetColumn($nc, 2)
    [void]$ng.Children.Add($ni); [void]$ng.Children.Add($nt); [void]$ng.Children.Add($nc)
    $nav.Content = $ng
    $script:NavCounts[$tab] = $nc
    $nav.Add_Checked({ param($s, $e)
            $script:LastNav = $s
            if ($script:SearchBox.Text) { $script:SearchBox.Text = '' }
            $script:Scroll.Content = $s.Tag; $script:Scroll.ScrollToTop() })
    [void]$script:NavHost.Children.Add($nav)
    $script:NavButtons += $nav
    if (-not $firstNav -or $tab -eq $StartTab) { $firstNav = $nav }
}

# Search results page (cards and tiles are moved here while searching, then put back)
$script:ResultsPage = New-Object System.Windows.Controls.StackPanel
$script:ResultsTitle = New-Object System.Windows.Controls.TextBlock
$script:ResultsTitle.FontSize = 22; $script:ResultsTitle.FontWeight = 'SemiBold'; $script:ResultsTitle.Margin = '0,0,0,14'
$script:ResultsCards = New-Object System.Windows.Controls.StackPanel
$script:ResultsTiles = New-Object System.Windows.Controls.WrapPanel
$script:ResultsTiles.Margin = '0,6,0,0'
[void]$script:ResultsPage.Children.Add($script:ResultsTitle)
[void]$script:ResultsPage.Children.Add($script:ResultsCards)
[void]$script:ResultsPage.Children.Add($script:ResultsTiles)

function Restore-Pages {
    $script:ResultsCards.Children.Clear(); $script:ResultsTiles.Children.Clear()
    foreach ($c in $script:Containers) { $c.Children.Clear() }
    foreach ($t in $script:Tweaks) { if ($t.Element) { [void]$t.Container.Children.Add($t.Element) } }
}

function Invoke-Search([string]$Q) {
    Restore-Pages
    $Q = $Q.Trim()
    if (-not $Q) {
        $script:SearchHint.Visibility = 'Visible'
        if ($script:LastNav) { $script:LastNav.IsChecked = $true; $script:Scroll.Content = $script:LastNav.Tag }
        return
    }
    $script:SearchHint.Visibility = 'Collapsed'
    $hits = @($script:Tweaks | Where-Object { $_.Element -and ("$($_.Name) $($_.Desc) $($_.Tab) $($_.Sub)".IndexOf($Q, [StringComparison]::OrdinalIgnoreCase) -ge 0) })
    foreach ($t in $hits) {
        [void]$t.Container.Children.Remove($t.Element)
        if ($t.IsTile) { [void]$script:ResultsTiles.Children.Add($t.Element) } else { [void]$script:ResultsCards.Children.Add($t.Element) }
    }
    $script:ResultsTitle.Text = "$($hits.Count) result(s) for ""$Q"""
    foreach ($n in $script:NavButtons) { $n.IsChecked = $false }
    $script:Scroll.Content = $script:ResultsPage
}
$script:SearchBox.Add_TextChanged({ Invoke-Search $script:SearchBox.Text })

# Presets
$script:PresetButtons = @()
$presets = @(
    @{ Level = 1; Title = 'Light'; Sub = 'Safe for anyone'; Dot = '#4ADE80' },
    @{ Level = 2; Title = 'Balanced'; Sub = 'Best for gaming'; Dot = '#FBBF24' },
    @{ Level = 3; Title = 'Max'; Sub = 'Everything, read warnings'; Dot = '#F87171' },
    @{ Level = -1; Title = 'Clear'; Sub = 'Untick all'; Dot = '#64748B' }
)
function Set-Preset([int]$Level) {
    $script:Bulk = $true
    foreach ($t in $script:Tweaks) {
        if ($t.CheckBox) { $t.CheckBox.IsChecked = ($t.Level -ge 1 -and $t.Level -le $Level) }
    }
    $script:Bulk = $false
    foreach ($b in $script:PresetButtons) {
        if ($b.Tag -eq $Level -and $Level -ge 1) { $b.Background = Brush '#18223A'; $b.BorderBrush = Brush '#3B6FE0' }
        else { $b.Background = Brush '#171A21'; $b.BorderBrush = Brush '#262B36' }
    }
    Update-Count
}
foreach ($p in $presets) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $script:Window.FindResource('Btn'); $b.Margin = '0,0,8,0'; $b.Padding = '14,7,16,7'; $b.Tag = $p.Level
    $b.Background = Brush '#171A21'; $b.BorderBrush = Brush '#262B36'; $b.HorizontalContentAlignment = 'Left'
    $sp = New-Object System.Windows.Controls.StackPanel
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'
    $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 8; $dot.Height = 8; $dot.Fill = Brush $p.Dot; $dot.Margin = '0,0,7,0'; $dot.VerticalAlignment = 'Center'
    $tt = New-Object System.Windows.Controls.TextBlock; $tt.Text = $p.Title; $tt.FontWeight = 'SemiBold'; $tt.FontSize = 13
    [void]$row.Children.Add($dot); [void]$row.Children.Add($tt)
    $st = New-Object System.Windows.Controls.TextBlock; $st.Text = $p.Sub; $st.Foreground = Brush '#737D90'; $st.FontSize = 11; $st.Margin = '15,1,0,0'
    [void]$sp.Children.Add($row); [void]$sp.Children.Add($st)
    $b.Content = $sp
    $b.Add_Click({ param($s, $e) Set-Preset ([int]$s.Tag) })
    [void]$script:PresetHost.Children.Add($b)
    $script:PresetButtons += $b
}

$script:RunBtn.Add_Click({ Invoke-Run 'apply' })
$script:UndoBtn.Add_Click({ Invoke-Run 'undo' })

# System info line
try {
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $os = Get-CimInstance Win32_OperatingSystem
    $script:SysInfo.Text = "$cpu   |   $($GpuNames -join ' + ')   |   $ram GB RAM   |   $($os.Caption -replace 'Microsoft ', '') build $($os.BuildNumber)"
} catch { $script:SysInfo.Text = 'System info unavailable' }

Import-Backup
foreach ($t in $script:Tweaks) { if ($t.AppliedBadge -and $script:Backup.ContainsKey($t.Id)) { $t.AppliedBadge.Visibility = 'Visible' } }
Show-TimerChart
$script:LogBox = $script:Window.FindName('LogBox')
Log "TweakHub $AppVersion ready. $($script:Tweaks.Count) items found for this PC. Backups and logs: $DataDir"
if (-not $isAdmin) { Log 'Not running as administrator: dry run only.' 'warn' }
if ($firstNav) { $firstNav.IsChecked = $true }
Update-Count
if ($StartTab -like 'search:*') { $script:SearchBox.Text = $StartTab.Substring(7) }

if ($Snapshot) {
    Set-Preset 2
    $script:Window.WindowStartupLocation = 'Manual'
    $script:Window.Left = -20000; $script:Window.Top = 0; $script:Window.ShowActivated = $false; $script:Window.ShowInTaskbar = $false
    $script:Window.Add_ContentRendered({
            $root = $script:Window.Content
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]$root.ActualWidth), ([int]$root.ActualHeight), 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($root)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
            $script:Window.Close()
        })
}

if ($SelfTest) {
    $script:Window.WindowStartupLocation = 'Manual'
    $script:Window.Left = -20000; $script:Window.Top = 0; $script:Window.ShowActivated = $false; $script:Window.ShowInTaskbar = $false
    $script:Window.Add_ContentRendered({
            $script:Bulk = $true
            foreach ($t in $script:Tweaks) { $t.CheckBox.IsChecked = $true }
            $script:Bulk = $false
            Invoke-Run 'apply'
            Invoke-Run 'undo'
            Log 'SELFTEST DONE'
            $script:Window.Close()
        })
}

[void]$script:Window.ShowDialog()
