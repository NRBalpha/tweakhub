<#
    TweakHub - Windows gaming tweaks and debloat in one window.
    Pick a strength (Light / Balanced / Max) or tick items yourself, then press Run Tweaks.
    Every registry, service, task, power and network change is backed up and can be undone.

    Start it with TweakHub.bat (it asks for admin rights), or from an admin PowerShell:
        powershell -ExecutionPolicy Bypass -File .\TweakHub.ps1

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
$AppVersion = '1.0'

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

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if ($DryRun) { $DataDir = Join-Path $env:TEMP "$AppName-dryrun" } else { $DataDir = Join-Path $env:ProgramData $AppName }
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$BackupFile = Join-Path $DataDir 'backup.json'
$LogFile = Join-Path $DataDir ('log-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))

if (-not ('TweakHubNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TweakHubNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint action, uint uiParam, int[] pvParam, uint winIni);
    [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfo")]
    public static extern bool SystemParametersInfoPtr(uint action, uint uiParam, IntPtr pvParam, uint winIni);
}
'@
}

# ---------------------------------------------------------------- logging + UI pump
$script:Window = $null
$script:LogBox = $null

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
        Log "   removing provisioned copy so new accounts don't get it"
        if (-not $DryRun) { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue | Out-Null }
    }
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

# ---------------------------------------------------------------- tweak catalog
# Level: 1 = Light (safe for everyone), 2 = Balanced (gaming), 3 = Max (aggressive), 0 = manual only (never auto-ticked)
$script:Tweaks = New-Object System.Collections.ArrayList
function Add-Tweak {
    param([string]$Id, [string]$Tab, [string]$Name, [string]$Desc, [int]$Level,
        [scriptblock]$Apply, [scriptblock]$Undo, [switch]$Reboot, [switch]$NoUndo, [switch]$Guide, [string]$Warn, $Data)
    [void]$script:Tweaks.Add([pscustomobject]@{
            Id = $Id; Tab = $Tab; Name = $Name; Desc = $Desc; Level = $Level; Apply = $Apply; Undo = $Undo
            Reboot = [bool]$Reboot; NoUndo = [bool]$NoUndo; Guide = [bool]$Guide; Warn = $Warn; Data = $Data; CheckBox = $null
        })
}

$MMKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$SUB_USB = '2a737441-1930-4402-8d77-b2bebba308a3'
$USB_SUSPEND = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'

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

Add-Tweak -Id 'timer-global' -Tab 'Performance' -Level 2 -Reboot -Name 'Global timer resolution requests' `
    -Desc 'Windows 11 only lets a game set a fine timer for itself. This makes one request apply system-wide, which the 0.5 ms timer below needs.' `
    -Apply { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1 }

Add-Tweak -Id 'timer-05' -Tab 'Performance' -Level 2 -Name '0.5 ms timer resolution at every startup' `
    -Desc 'Builds a tiny background helper that holds the system timer at about 0.504 ms and starts it at logon. Smoother frame pacing. Skipped if SetTimerResolution.exe is already running.' `
    -Apply {
    if (Get-Process SetTimerResolution -ErrorAction SilentlyContinue) { Log '   SetTimerResolution.exe is already running, nothing to add'; return }
    $exe = Join-Path $DataDir 'TimerRes.exe'
    $src = @'
using System; using System.Runtime.InteropServices; using System.Threading;
static class TimerRes {
    [DllImport("ntdll.dll")] static extern int NtSetTimerResolution(uint want, bool set, out uint cur);
    [DllImport("ntdll.dll")] static extern int NtQueryTimerResolution(out uint min, out uint max, out uint cur);
    static Mutex single;
    static void Main(string[] args) {
        bool created; single = new Mutex(true, "Global\\TweakHubTimerRes", out created);
        if (!created) return;
        uint min, max, cur; NtQueryTimerResolution(out min, out max, out cur);
        uint want = 5040; if (args.Length > 0) uint.TryParse(args[0], out want);
        if (want < max) want = max;
        NtSetTimerResolution(want, true, out cur);
        Thread.Sleep(Timeout.Infinite);
    }
}
'@
    Log "   building $exe"
    if ($DryRun) { return }
    Get-Process TimerRes -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    Add-Type -TypeDefinition $src -OutputAssembly $exe -OutputType WindowsApplication -ErrorAction Stop
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $exe -Argument '5040'
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'TweakHub Timer Resolution' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName 'TweakHub Timer Resolution'
    Log '   timer helper installed and running'
} -Undo {
    Log '   removing timer helper'
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

# ===== Input ================================================================
Add-Tweak -Id 'mouse-accel' -Tab 'Input' -Level 1 -Name 'Turn off mouse acceleration' `
    -Desc 'Turns off "Enhance pointer precision" so the same hand movement always moves your aim the same distance.' `
    -Apply {
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
    if (-not $DryRun) { [void][TweakHubNative]::SystemParametersInfo(0x0004, 0, [int[]](0, 0, 0), 3) }
} -Undo {
    if ($DryRun) { return }
    $m = Get-ItemProperty 'HKCU:\Control Panel\Mouse'
    [void][TweakHubNative]::SystemParametersInfo(0x0004, 0, [int[]]([int]$m.MouseThreshold1, [int]$m.MouseThreshold2, [int]$m.MouseSpeed), 3)
}

Add-Tweak -Id 'kb-repeat' -Tab 'Input' -Level 2 -Name 'Fastest keyboard repeat' `
    -Desc 'Shortest delay before a held key repeats, and the fastest repeat rate.' `
    -Apply {
    Set-Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String'
    if (-not $DryRun) {
        [void][TweakHubNative]::SystemParametersInfoPtr(0x0017, 0, [IntPtr]::Zero, 3)
        [void][TweakHubNative]::SystemParametersInfoPtr(0x000B, 31, [IntPtr]::Zero, 3)
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

# ===== Network ==============================================================
Add-Tweak -Id 'nic-power' -Tab 'Network' -Level 1 -Name 'No power saving on Wi-Fi and Ethernet' `
    -Desc 'Turns off adapter power saving (the main cause of random 100-500 ms ping spikes on Wi-Fi), Green/Energy-Efficient Ethernet and "allow turn off".' `
    -Apply {
    $nics = Get-PhysicalNics
    foreach ($n in $nics) {
        Set-NicProp $n '^(Power Saving|Power Saving Mode|MIMO Power Save Mode|Energy[- ]Efficient Ethernet|Advanced EEE|Green Ethernet|Gigabit Lite|Ultra Low Power Mode|Auto Disable Gigabit|U-APSD Support|Idle Power Saving)$' @('No SMPS', '^(\d\.\s*)?Disabled?$', '^Off$')
    }
    Disable-DevicePowerOff ($nics | ForEach-Object { $_.PnPDeviceID })
}

Add-Tweak -Id 'wifi-radio' -Tab 'Network' -Level 1 -Name 'Wi-Fi radio at maximum performance' `
    -Desc 'Sets the power plan Wireless Adapter setting to Maximum Performance on charger and battery.' `
    -Apply { Set-PowerValue '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1' '12bbebe6-58d6-4636-95bb-3217ef867c1a' 0 0 }

Add-Tweak -Id 'nic-wake' -Tab 'Network' -Level 2 -Name 'Turn off Wake-on-LAN' `
    -Desc 'Network packets can no longer wake the PC or keep the adapter in a listening mode.' `
    -Apply { foreach ($n in (Get-PhysicalNics)) { Set-NicProp $n '(?i)^wake on' @('^(\d\.\s*)?Disabled?$') } }

Add-Tweak -Id 'wifi-roam' -Tab 'Network' -Level 2 -Name 'Lowest Wi-Fi roaming' `
    -Desc 'Stops the card from scanning for other access points mid-game, which causes 1-3 second stalls.' `
    -Apply { foreach ($n in (Get-PhysicalNics 'wifi')) { Set-NicProp $n '^Roaming Aggressiveness$' @('Disabled', 'Lowest') } }

Add-Tweak -Id 'wifi-band' -Tab 'Network' -Level 2 -Name 'Prefer the 5 GHz band' `
    -Desc '5 GHz has far less interference than 2.4 GHz. Harmless if your router only has 2.4 GHz.' `
    -Apply { foreach ($n in (Get-PhysicalNics 'wifi')) { Set-NicProp $n '^Preferred Band$' @('5\s?GHz') } }

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
    Add-Tweak -Id 'wifi-ax' -Tab 'Network' -Level 0 -Name 'Lock Wi-Fi 7 card to 802.11ax (Wi-Fi 6)' `
        -Desc 'Fixes random disconnects on some MediaTek Wi-Fi 7 drivers. Driver updates can reset this, so run it again after updating.' `
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
    -Desc 'Turns off Start menu suggestions, "tips", the advertising ID and the silent installs of sponsored apps like Candy Crush.' `
    -Apply {
    $c = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'PreInstalledAppsEnabled',
        'OemPreInstalledAppsEnabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
        'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled') {
        Set-Reg $c $n 0
    }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
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
            Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' $n ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) 'Binary'
        }
    }
}

Add-Tweak -Id 'widgets' -Tab 'Privacy & Background' -Level 1 -Name 'Turn off Widgets and the news feed' `
    -Desc 'Removes the Widgets button and stops the news feed from running in the background.' `
    -Apply {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
}

Add-Tweak -Id 'edge-bg' -Tab 'Privacy & Background' -Level 1 -Name 'Stop Microsoft Edge running in the background' `
    -Desc 'Turns off Edge Startup Boost and background mode. Edge will say it is "managed by your organization"; that is just this setting.' `
    -Apply {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
}

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
    -Desc 'Fax, Retail Demo, Downloaded Maps Manager, Error Reporting, Geolocation and the Cloudflare WARP updater (if installed).' `
    -Warn 'Geolocation off means apps and Find My Device cannot see your location.' `
    -Apply {
    foreach ($s in 'Fax', 'RetailDemo', 'MapsBroker', 'WerSvc', 'lfsvc', 'CloudflareWARPUpdater') { Set-Svc $s 'disabled' }
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

Add-Tweak -Id 'clean-temp' -Tab 'Privacy & Background' -Level 1 -NoUndo -Name 'Clean temporary files' `
    -Desc 'Deletes leftovers in your Temp folder and Windows Temp. Files that are in use are skipped.' `
    -Apply {
    $total = 0
    foreach ($dir in @($env:TEMP, (Join-Path $env:WINDIR 'Temp'))) {
        if (-not (Test-Path $dir)) { continue }
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
    Log ('   freed {0:N0} MB' -f ($total / 1MB))
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
    $desc = $s.Command
    if ($desc.Length -gt 120) { $desc = $desc.Substring(0, 117) + '...' }
    if ($s.Disabled) { $desc = "Already off.  $desc"; $level = 0 }
    $displayName = $s.Name -replace '_[0-9A-F]{32}$', '' -replace '\.lnk$', ''
    Add-Tweak -Id "startup|$($s.Approved)|$($s.Name)" -Tab 'Startup Apps' -Level $level -Name $displayName -Desc $desc -Data $s -Apply {
        param($T)
        $ft = [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())
        Set-Reg $T.Data.Approved $T.Data.Name ([byte[]](@(3, 0, 0, 0) + $ft)) 'Binary'
        Log '   will not start with Windows anymore'
    }
}

# ===== Debloat apps (only what is installed) =================================
$AppCatalog = @(
    @('Microsoft.BingNews', 'News', 1), @('Microsoft.BingWeather', 'Weather', 1), @('Microsoft.BingFinance', 'Money', 1),
    @('Microsoft.BingSports', 'Sports', 1), @('Microsoft.Getstarted', 'Tips', 1), @('Clipchamp.Clipchamp', 'Clipchamp video editor', 1),
    @('Microsoft.MicrosoftSolitaireCollection', 'Solitaire Collection', 1), @('Microsoft.GetHelp', 'Get Help', 1),
    @('Microsoft.WindowsFeedbackHub', 'Feedback Hub', 1), @('Microsoft.PowerAutomateDesktop', 'Power Automate', 1),
    @('MicrosoftCorporationII.MicrosoftFamily', 'Microsoft Family Safety', 1), @('Microsoft.Windows.DevHome', 'Dev Home', 1),
    @('Microsoft.MicrosoftJournal', 'Journal', 1), @('Microsoft.Whiteboard', 'Whiteboard', 1), @('Microsoft.WindowsMaps', 'Maps', 1),
    @('Microsoft.People', 'People', 1), @('Microsoft.Microsoft3DViewer', '3D Viewer', 1), @('Microsoft.MixedReality.Portal', 'Mixed Reality Portal', 1),
    @('Microsoft.SkypeApp', 'Skype', 1), @('Microsoft.MicrosoftOfficeHub', 'Microsoft 365 (Office hub)', 1), @('Microsoft.549981C3F5F10', 'Cortana', 1),
    @('Microsoft.Copilot', 'Copilot app', 1), @('Microsoft.BingSearch', 'Bing web search in Start', 2),
    @('*CandyCrush*', 'Candy Crush', 1), @('*Disney*', 'Disney+', 1), @('*Facebook*', 'Facebook', 1), @('*Instagram*', 'Instagram', 1),
    @('*TikTok*', 'TikTok', 1), @('AmazonVideo.PrimeVideo', 'Prime Video', 1), @('*LinkedIn*', 'LinkedIn', 1),
    @('Microsoft.Todos', 'Microsoft To Do', 2), @('Microsoft.OutlookForWindows', 'Outlook (new)', 2), @('MSTeams', 'Microsoft Teams', 2),
    @('MicrosoftTeams', 'Microsoft Teams (personal)', 2), @('MicrosoftCorporationII.QuickAssist', 'Quick Assist', 2),
    @('Microsoft.ZuneVideo', 'Movies & TV', 2), @('Microsoft.OfficePushNotificationUtility', 'Office push notifications', 2),
    @('Microsoft.XboxSpeechToTextOverlay', 'Xbox speech-to-text overlay', 2), @('Microsoft.WindowsCommunicationsApps', 'Mail and Calendar (old)', 2),
    @('Microsoft.ZuneMusic', 'Media Player', 3), @('Microsoft.WindowsAlarms', 'Clock', 3), @('Microsoft.WindowsSoundRecorder', 'Sound Recorder', 3),
    @('Microsoft.MicrosoftStickyNotes', 'Sticky Notes', 3), @('Microsoft.YourPhone', 'Phone Link', 3),
    @('MicrosoftWindows.CrossDevice', 'Cross Device Experience Host (Phone Link helper)', 3),
    @('Microsoft.XboxGamingOverlay', 'Xbox Game Bar', 0)
)
$installed = @()
try { if ($isAdmin) { $installed = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } else { $installed = @(Get-AppxPackage -ErrorAction Stop) } }
catch { try { $installed = @(Get-AppxPackage -ErrorAction Stop) } catch {} }
foreach ($a in $AppCatalog) {
    $hit = @($installed | Where-Object { $_.Name -like $a[0] })
    if (-not $hit) { continue }
    $warn = $null
    if ($a[0] -eq 'Microsoft.XboxGamingOverlay') { $warn = 'Some games use Game Bar for screenshots and the Xbox party overlay.' }
    Add-Tweak -Id "app|$($a[0])" -Tab 'Debloat Apps' -Level $a[2] -NoUndo -Name $a[1] -Desc "Removes $($hit[0].Name). Reinstall it from the Microsoft Store if you miss it." `
        -Warn $warn -Data $a[0] -Apply { param($T) Remove-App $T.Data }
}

$OneDriveSetup = @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") + @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\OneDrive\*\OneDriveSetup.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName)
$OneDriveSetup = @($OneDriveSetup | Where-Object { Test-Path $_ })
if ($OneDriveSetup -and (Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe")) {
    Add-Tweak -Id 'app|onedrive' -Tab 'Debloat Apps' -Level 0 -NoUndo -Name 'OneDrive' -Data $OneDriveSetup[0] `
        -Desc 'Uninstalls the OneDrive sync app.' `
        -Warn 'Files that only live in the cloud (cloud icon) stay online and will not open from this PC. Download anything you need first.' `
        -Apply {
        param($T)
        if (-not $DryRun) { Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue }
        Invoke-Cmd $T.Data @('/uninstall')
    }
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
        if ($noUndo) { $msg += "`n`n$($noUndo.Count) of them cannot be undone by TweakHub (app removals, temp cleanup)." }
        if ($script:RestoreBox.IsChecked) { $msg += "`n`nA Windows restore point is created first." }
    } else {
        $msg = "Undo $($sel.Count) tweak(s)? Original values saved by TweakHub will be put back."
    }
    if ($DryRun) { $msg += "`n`nDRY RUN: nothing will actually change." }
    if (-not $SelfTest) {
        if ([Windows.MessageBox]::Show($script:Window, $msg, $AppName, 'YesNo', 'Question') -ne 'Yes') { return }
    }

    $script:RunBtn.IsEnabled = $false; $script:UndoBtn.IsEnabled = $false
    $ok = 0; $fail = 0; $reboot = $false
    try {
        if ($Mode -eq 'apply' -and $script:RestoreBox.IsChecked) { New-RestorePoint }
        $list = $sel
        if ($Mode -eq 'undo') { [array]::Reverse($list) }
        $i = 0
        foreach ($t in $list) {
            $i++
            $script:StatusText.Text = "$i / $($list.Count)  $($t.Name)"
            Log ("{0} {1}" -f $(if ($Mode -eq 'apply') { '>>' } else { '<<' }), $t.Name)
            $script:CurrentId = $t.Id
            try {
                if ($Mode -eq 'apply') { & $t.Apply $t }
                else {
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
        Title="TweakHub" Width="1100" Height="780" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#0E1014" Foreground="#E6E8EE"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#AEB5C4"/>
      <Setter Property="Margin" Value="0,0,0,3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="Transparent" CornerRadius="6" Padding="12,9">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1A1E26"/></Trigger>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="#222938"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
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
              <Border x:Name="box" Width="18" Height="18" CornerRadius="4" BorderThickness="1.5" BorderBrush="#4A5263" Background="#12151B" VerticalAlignment="Center">
                <Path x:Name="mark" Data="M3,8.5 L6.5,12 L13,4.5" Stroke="White" StrokeThickness="2.2" Visibility="Collapsed"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
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
      <Setter Property="Background" Value="#222733"/>
      <Setter Property="BorderBrush" Value="#2E3442"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#7AA7F7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,14,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button"><ContentPresenter/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="Root" Background="#0E1014">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#12151B" BorderBrush="#232833" BorderThickness="0,0,0,1" Padding="22,16">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="TweakHub" FontSize="22" FontWeight="SemiBold"/>
            <TextBlock x:Name="VersionText" Foreground="#6B7385" FontSize="12" VerticalAlignment="Bottom" Margin="8,0,0,4"/>
            <Border x:Name="DryBadge" Visibility="Collapsed" Background="#3A2A0A" CornerRadius="9" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="DRY RUN" Foreground="#F59E0B" FontSize="11" FontWeight="SemiBold"/>
            </Border>
          </StackPanel>
          <TextBlock x:Name="SysInfo" Foreground="#8A93A5" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock Text="STRENGTH" Foreground="#6B7385" FontSize="11" FontWeight="SemiBold" Margin="2,0,0,6"/>
          <StackPanel x:Name="PresetHost" Orientation="Horizontal"/>
        </StackPanel>
      </Grid>
    </Border>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="230"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Background="#11141A" BorderBrush="#232833" BorderThickness="0,0,1,0" Padding="12,16">
        <StackPanel x:Name="NavHost"/>
      </Border>
      <ScrollViewer x:Name="Scroll" Grid.Column="1" VerticalScrollBarVisibility="Auto" Padding="24,18,24,18"/>
    </Grid>

    <Border Grid.Row="2" Background="#0A0C10" BorderBrush="#232833" BorderThickness="0,1,0,0">
      <TextBox x:Name="LogBox" Height="120" IsReadOnly="True" Background="Transparent" Foreground="#93A3BC" BorderThickness="0"
               FontFamily="Consolas" FontSize="12" Padding="18,10" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
    </Border>

    <Border Grid.Row="3" Background="#12151B" BorderBrush="#232833" BorderThickness="0,1,0,0" Padding="22,12">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <CheckBox x:Name="RestoreBox" Style="{StaticResource Tick}" IsChecked="True" VerticalAlignment="Center">
          <TextBlock Text="Create a restore point first" Foreground="#C4CAD6"/>
        </CheckBox>
        <TextBlock x:Name="StatusText" Grid.Column="1" Foreground="#8A93A5" VerticalAlignment="Center" Margin="24,0" TextTrimming="CharacterEllipsis"/>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <Button x:Name="UndoBtn" Style="{StaticResource Btn}" Content="Undo selected" Margin="0,0,10,0"/>
          <Button x:Name="RunBtn" Style="{StaticResource Btn}" Background="#2563EB" BorderBrush="#3B82F6" Padding="28,10">
            <TextBlock Text="Run Tweaks" FontWeight="SemiBold" FontSize="14" Foreground="White"/>
          </Button>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'SysInfo', 'VersionText', 'DryBadge', 'PresetHost', 'NavHost', 'Scroll', 'LogBox', 'RestoreBox', 'StatusText', 'UndoBtn', 'RunBtn') {
    Set-Variable -Name $n -Scope Script -Value $script:Window.FindName($n)
}
$script:Window.Title = "$AppName $AppVersion"
$script:VersionText.Text = "v$AppVersion"
if ($DryRun) { $script:DryBadge.Visibility = 'Visible' }

$Conv = New-Object System.Windows.Media.BrushConverter
function Brush([string]$hex) { $Conv.ConvertFromString($hex) }

$LevelInfo = @{
    1 = @{ Label = 'Light'; Fg = '#4ADE80'; Bg = '#14301F' }
    2 = @{ Label = 'Balanced'; Fg = '#FBBF24'; Bg = '#33280C' }
    3 = @{ Label = 'Max'; Fg = '#F87171'; Bg = '#3A1616' }
    0 = @{ Label = 'Manual'; Fg = '#94A3B8'; Bg = '#1F2530' }
}

function New-Badge([string]$Text, [string]$Fg, [string]$Bg) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Brush $Bg; $b.CornerRadius = 9; $b.Padding = '8,2,8,2'; $b.Margin = '6,0,0,0'; $b.VerticalAlignment = 'Top'
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.Foreground = Brush $Fg; $t.FontSize = 11; $t.FontWeight = 'SemiBold'
    $b.Child = $t
    return $b
}

function Update-Count {
    $n = @(Get-Selected).Count
    if ($script:StatusText) { $script:StatusText.Text = "$n selected" }
}

$TabInfo = [ordered]@{
    'Performance'          = 'Power plan, CPU and GPU scheduling, timer resolution and visual effects.'
    'Input'                = 'Mouse, keyboard and USB latency.'
    'Network'              = 'Adapter power saving, Wi-Fi stability and TCP latency. Adapters restart once at the end.'
    'Games'                = 'Game Mode, recording, fullscreen behaviour and per-game priority.'
    'Privacy & Background' = 'Telemetry, ads, background apps, services and cleanup.'
    'Startup Apps'         = 'Apps found on this PC that start with Windows. Ticking one stops it from starting; it stays installed.'
    'Debloat Apps'         = 'Preinstalled apps found on this PC. Removal cannot be undone by TweakHub; reinstall from the Microsoft Store.'
    'Laptop & GPU'         = "Detected: $Maker $ModelName.  GPUs: $($GpuNames -join ', ')."
}

$script:Pages = @{}
$firstNav = $null
foreach ($tab in $TabInfo.Keys) {
    $items = @($script:Tweaks | Where-Object { $_.Tab -eq $tab })
    if (-not $items) { continue }

    $page = New-Object System.Windows.Controls.StackPanel
    $page.MaxWidth = 900; $page.HorizontalAlignment = 'Left'

    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $tab; $h.FontSize = 20; $h.FontWeight = 'SemiBold'
    [void]$page.Children.Add($h)
    $d = New-Object System.Windows.Controls.TextBlock
    $d.Text = $TabInfo[$tab]; $d.Foreground = Brush '#8A93A5'; $d.TextWrapping = 'Wrap'; $d.Margin = '0,4,0,10'
    [void]$page.Children.Add($d)

    $links = New-Object System.Windows.Controls.StackPanel
    $links.Orientation = 'Horizontal'; $links.Margin = '0,0,0,14'
    foreach ($pair in @(@('Select all', $true), @('Select none', $false))) {
        $lb = New-Object System.Windows.Controls.Button
        $lb.Style = $script:Window.FindResource('Link'); $lb.Content = $pair[0]
        $lb.Tag = @{ Tab = $tab; Value = $pair[1] }
        $lb.Add_Click({ param($s, $e)
                foreach ($t in $script:Tweaks) { if ($t.Tab -eq $s.Tag.Tab -and $t.CheckBox) { $t.CheckBox.IsChecked = $s.Tag.Value } } })
        [void]$links.Children.Add($lb)
    }
    [void]$page.Children.Add($links)

    foreach ($t in $items) {
        $card = New-Object System.Windows.Controls.Border
        $card.Background = Brush '#171A21'; $card.BorderBrush = Brush '#242934'; $card.BorderThickness = 1
        $card.CornerRadius = 8; $card.Padding = '14,12,14,12'; $card.Margin = '0,0,0,8'; $card.Cursor = 'Hand'

        $grid = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
        $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

        $left = New-Object System.Windows.Controls.StackPanel
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $script:Window.FindResource('Tick')
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $t.Name; $title.FontWeight = 'SemiBold'; $title.FontSize = 14; $title.TextWrapping = 'Wrap'
        $cb.Content = $title
        $cb.Add_Checked({ Update-Count }); $cb.Add_Unchecked({ Update-Count })
        $t.CheckBox = $cb
        [void]$left.Children.Add($cb)

        $desc = New-Object System.Windows.Controls.TextBlock
        $desc.Text = $t.Desc; $desc.Foreground = Brush '#8A93A5'; $desc.TextWrapping = 'Wrap'; $desc.Margin = '28,4,0,0'
        [void]$left.Children.Add($desc)
        if ($t.Warn) {
            $w = New-Object System.Windows.Controls.TextBlock
            $w.Text = "Heads up: $($t.Warn)"; $w.Foreground = Brush '#FBBF24'; $w.TextWrapping = 'Wrap'; $w.Margin = '28,6,0,0'; $w.FontSize = 12
            [void]$left.Children.Add($w)
        }
        [void]$grid.Children.Add($left)

        $tags = New-Object System.Windows.Controls.StackPanel
        $tags.Orientation = 'Horizontal'; $tags.VerticalAlignment = 'Top'; $tags.Margin = '12,0,0,0'
        [System.Windows.Controls.Grid]::SetColumn($tags, 1)
        $li = $LevelInfo[$t.Level]
        [void]$tags.Children.Add((New-Badge $li.Label $li.Fg $li.Bg))
        if ($t.Reboot) { [void]$tags.Children.Add((New-Badge 'Restart' '#93C5FD' '#172338')) }
        if ($t.NoUndo) { [void]$tags.Children.Add((New-Badge 'No undo' '#C4B5FD' '#241B38')) }
        if ($t.Guide) { [void]$tags.Children.Add((New-Badge 'Opens app' '#67E8F9' '#0E2A30')) }
        if ($script:Backup.ContainsKey($t.Id)) { [void]$tags.Children.Add((New-Badge 'Applied' '#4ADE80' '#10261A')) }
        [void]$grid.Children.Add($tags)

        $card.Child = $grid
        $card.Tag = $cb
        $card.Add_MouseLeftButtonUp({ param($s, $e) $s.Tag.IsChecked = -not $s.Tag.IsChecked })
        [void]$page.Children.Add($card)
    }
    $script:Pages[$tab] = $page

    $nav = New-Object System.Windows.Controls.RadioButton
    $nav.Style = $script:Window.FindResource('Nav'); $nav.GroupName = 'nav'; $nav.Tag = $page
    $navGrid = New-Object System.Windows.Controls.DockPanel
    $navCount = New-Object System.Windows.Controls.TextBlock
    $navCount.Text = "$($items.Count)"; $navCount.Foreground = Brush '#5E6678'; $navCount.FontSize = 12
    [System.Windows.Controls.DockPanel]::SetDock($navCount, 'Right')
    [void]$navGrid.Children.Add($navCount)
    $navText = New-Object System.Windows.Controls.TextBlock
    $navText.Text = $tab; $navText.FontSize = 14
    [void]$navGrid.Children.Add($navText)
    $nav.Content = $navGrid
    $nav.Add_Checked({ param($s, $e) $script:Scroll.Content = $s.Tag; $script:Scroll.ScrollToTop() })
    [void]$script:NavHost.Children.Add($nav)
    if (-not $firstNav -or $tab -eq $StartTab) { $firstNav = $nav }
}

# Presets
$script:PresetButtons = @()
$presets = @(
    @{ Level = 1; Title = 'Light'; Sub = 'Safe for anyone'; Dot = '#4ADE80' },
    @{ Level = 2; Title = 'Balanced'; Sub = 'Recommended for gaming'; Dot = '#FBBF24' },
    @{ Level = 3; Title = 'Max'; Sub = 'Everything, read warnings'; Dot = '#F87171' },
    @{ Level = -1; Title = 'Clear'; Sub = 'Untick all'; Dot = '#64748B' }
)
function Set-Preset([int]$Level) {
    foreach ($t in $script:Tweaks) {
        if ($t.CheckBox) { $t.CheckBox.IsChecked = ($t.Level -ge 1 -and $t.Level -le $Level) }
    }
    foreach ($b in $script:PresetButtons) {
        if ($b.Tag -eq $Level -and $Level -ge 1) { $b.Background = Brush '#1E2A44'; $b.BorderBrush = Brush '#3B82F6' }
        else { $b.Background = Brush '#1A1E27'; $b.BorderBrush = Brush '#2A303C' }
    }
    Update-Count
}
foreach ($p in $presets) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $script:Window.FindResource('Btn'); $b.Margin = '0,0,8,0'; $b.Padding = '14,7,16,7'; $b.Tag = $p.Level
    $b.Background = Brush '#1A1E27'; $b.BorderBrush = Brush '#2A303C'
    $sp = New-Object System.Windows.Controls.StackPanel
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'
    $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 8; $dot.Height = 8; $dot.Fill = Brush $p.Dot; $dot.Margin = '0,0,7,0'; $dot.VerticalAlignment = 'Center'
    $tt = New-Object System.Windows.Controls.TextBlock; $tt.Text = $p.Title; $tt.FontWeight = 'SemiBold'; $tt.FontSize = 13
    [void]$row.Children.Add($dot); [void]$row.Children.Add($tt)
    $st = New-Object System.Windows.Controls.TextBlock; $st.Text = $p.Sub; $st.Foreground = Brush '#7C8597'; $st.FontSize = 11; $st.Margin = '15,1,0,0'
    [void]$sp.Children.Add($row); [void]$sp.Children.Add($st)
    $b.Content = $sp; $b.HorizontalContentAlignment = 'Left'
    $b.Add_Click({ param($s, $e) Set-Preset ([int]$s.Tag) })
    [void]$script:PresetHost.Children.Add($b)
    $script:PresetButtons += $b
}

$script:RunBtn.Add_Click({ Invoke-Run 'apply' })
$script:UndoBtn.Add_Click({ Invoke-Run 'undo' })

# System info line
try {
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
    $gpus = (Get-CimInstance Win32_VideoController | ForEach-Object Name) -join ' + '
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $os = Get-CimInstance Win32_OperatingSystem
    $script:SysInfo.Text = "$cpu  |  $gpus  |  $ram GB RAM  |  $($os.Caption -replace 'Microsoft ', '') build $($os.BuildNumber)"
} catch { $script:SysInfo.Text = 'System info unavailable' }

Import-Backup
$script:LogBox = $script:Window.FindName('LogBox')
Log "TweakHub $AppVersion ready. $($script:Tweaks.Count) tweaks found for this PC. Backups and logs: $DataDir"
if (-not $isAdmin) { Log 'Not running as administrator: dry run only.' 'warn' }
if ($firstNav) { $firstNav.IsChecked = $true }
Update-Count

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
            foreach ($t in $script:Tweaks) { $t.CheckBox.IsChecked = $true }
            Invoke-Run 'apply'
            Invoke-Run 'undo'
            Log "SELFTEST DONE"
            $script:Window.Close()
        })
}

[void]$script:Window.ShowDialog()
