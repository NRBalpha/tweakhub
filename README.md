# TweakHub

Windows 10/11 gaming tweaks and debloat in one window. Tick what you want, or pick a strength, then press **Run Tweaks**.

## Start it

Open PowerShell (Start menu, type PowerShell, Enter) and paste:

```powershell
irm https://raw.githubusercontent.com/NRBalpha/tweakhub/main/TweakHub.ps1 | iex
```

Click **Yes** on the admin prompt and the TweakHub window opens.

Or download this repo and double-click `TweakHub.bat`.

From an admin PowerShell instead:

```powershell
powershell -ExecutionPolicy Bypass -File .\TweakHub.ps1
```

## Strength presets

| Preset | What it ticks |
|---|---|
| Light (green) | Safe for any PC: power plan, GPU scheduling, mouse acceleration off, Game DVR off, telemetry and ads off, obvious bloat apps |
| Balanced (amber) | Light plus the gaming tweaks: timer resolution, CPU boost, network latency, USB power, game priority, startup apps |
| Max (red) | Everything, including VBS/hypervisor off, dynamic tick, search indexing and Xbox services. Read the yellow warnings |
| Manual (grey) | Never ticked by a preset. Hardware-specific or risky items you choose yourself |

## Tabs

Performance, Input, Network, Games, Privacy & Background, Startup Apps, Debloat Apps, and Laptop & GPU.
Startup Apps and Debloat Apps are built from what is actually installed on the PC.

## Using the dedicated GPU (laptops)

| Laptop | What TweakHub does |
|---|---|
| Any PC with two GPUs | Sets every Steam, Epic, Riot and Roblox game to "High performance" so it runs on the NVIDIA/AMD GPU |
| Lenovo Legion / LOQ | Flips the MUX to dGPU only and sets Performance mode directly |
| ASUS ROG / TUF | Switches to Ultimate GPU mode (MUX) and Turbo mode directly, like Armoury Crate |
| HP OMEN / Victus, Alienware, Dell G, MSI, Acer, Razer, Gigabyte | Opens the maker's app (or NVIDIA Control Panel) and shows exactly where the dGPU-only switch is |

dGPU-only (MUX) mode needs a restart and uses much more battery.

## Undo

- Every registry value, service, scheduled task, power setting and network adapter setting is backed up before it changes.
- Tick items and press **Undo selected** to put the original values back.
- App removals and temp cleanup are tagged **No undo**. Reinstall removed apps from the Microsoft Store.
- A Windows restore point is created before each run unless you untick it.

Backups and logs live in `C:\ProgramData\TweakHub`. Keep `backup.json` if you want undo to keep working.

## Testing without changing anything

```powershell
powershell -ExecutionPolicy Bypass -File .\TweakHub.ps1 -DryRun
```

Dry run opens the same window and logs every change it would make. It does not need admin.

## Notes

- Some changes need a restart. They have a blue **Restart** tag, and TweakHub offers to restart at the end.
- Network adapters restart once at the end of a run, so the internet drops for a few seconds.
- Run it from the Windows account you game on. Settings for your user (mouse, keyboard, startup apps) apply to the account that runs it.
