# TweakHub

Windows 10/11 gaming tweaks and debloat in one window. Tick what you want, or pick a strength, then press **Run Tweaks**.

## Start it

Open PowerShell (Start menu, type PowerShell, Enter) and paste:

```powershell
irm https://raw.githubusercontent.com/NRBalpha/tweakhub/main/TweakHub.ps1 | iex
```

Click **Yes** on the admin prompt and the TweakHub window opens.

Or download this repo and double-click `TweakHub.bat`.

## Strength presets

| Preset | What it ticks |
|---|---|
| Light (green) | Safe for any PC: power plan, GPU scheduling, mouse acceleration off, Game DVR off, telemetry and ads off, browser debloat, obvious bloat apps |
| Balanced (amber) | Light plus the gaming tweaks: benchmarked timer resolution, CPU boost, Wi-Fi and network latency, USB power, game priority, startup apps |
| Max (red) | Everything, including VBS/hypervisor off, dynamic tick, search indexing and Xbox services. Read the yellow warnings |
| Manual (grey) | Never ticked by a preset. App and browser removal, hardware switches and other choices only you can make |

## Tabs

| Tab | What is in it |
|---|---|
| Performance | Power plan, CPU boost, GPU scheduling, benchmarked timer resolution, kernel timer, VBS, visual effects, Fast Startup |
| Input | Mouse acceleration, keyboard repeat, Sticky Keys, USB power saving, input buffers |
| Network | Wi-Fi and Ethernet power saving, roaming, background scans, packet coalescing, transmit power, 5 GHz, Nagle. Works on Intel, Realtek, MediaTek, Qualcomm/Killer and Broadcom cards |
| Games | Game Mode, Game DVR, fullscreen optimizations, per-game High priority, Fortnite settings |
| Browsers | Debloat Edge, Chrome, Firefox, Brave and Opera, remove any of them, including Microsoft Edge |
| Privacy & Background | Telemetry, ads, Bing in Start search, Copilot and Recall, activity history, update sharing, services, cleanup |
| Startup Apps | Every app that starts with Windows, with its icon |
| Debloat Apps | Every Microsoft app, Store app and desktop program on the PC, with its icon |
| Laptop & GPU | Run games on the dedicated GPU, plus brand-specific switches |

Use the search box to find any tweak or app across all tabs.

## Timer resolution

TweakHub does not just set the lowest timer value. It tests every value from 0.500 to 0.600 ms on the PC, re-tests the best five, and keeps the one where Windows wakes up most accurately and steadily. The result is shown as a chart on the card. Close games while it runs (about 15 seconds).

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
- App removals, browser removals and cleanups are tagged **No undo**. Reinstall removed apps from the Microsoft Store or the app's website.
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
- Browser debloat uses the browsers' official policies, so the browser shows "managed by your organization".
- Run it from the Windows account you game on. Settings for your user (mouse, keyboard, startup apps) apply to the account that runs it.
