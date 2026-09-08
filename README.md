# Steam Cleaner

PowerShell cleaner for Windows that permanently removes everything inside the selected Steam installation except **steamapps**, **userdata**, and **steam.exe**. It does not clean separate Steam library folders.

Also includes **Depot Downloader**: resolve an AppID, prove depot access from SteamCMD license/package metadata, download an exact manifest set, and assemble it into one verified game directory. It does not create Steam installation records or bypass account ownership.

## Steam Cleaner menu

```powershell
irm https://raw.githubusercontent.com/dholank/steam-cleaner/main/steam-cleaner.ps1 | iex
```

Select **2: Depot Downloader**. A small Windows dialog lets you edit or browse to one **Download Location**, open an existing folder, and optionally keep temporary depot files. Continue saves the choice; Cancel changes nothing. Then enter an AppID and your Steam login name. Password and Steam Guard are entered directly in SteamCMD when prompted. Use `anonymous` only for applications that allow it.

The menu launcher downloads the required PowerShell files from one immutable GitHub revision into a unique TEMP folder and starts a child PowerShell process with process-only execution-policy bypass. It does not change the saved Windows execution policy. Remote execution trusts this repository; inspect it first. Organizations that disallow this flow should use their approved local-script process. The original cleaner-only URL below still works independently.

Defaults: Windows, x64, English, public branch, no DLC, and automatic temporary-cache cleanup. The default Download Location is `Documents\Steam Cleaner Downloads`; the saved choice is in `%LOCALAPPDATA%\SteamCleaner\settings.json`. For AppID `123`, temporary files use `<Download Location>\.depot-cache\123` and final files use `<Download Location>\<InstallDir>`. Logs stay in `%LOCALAPPDATA%\SteamCleaner\logs`.

For scripted use, download or clone the full repository. CLI values override an explicit config file, which overrides saved settings and then defaults. Keep the Download Location outside the installed Steam client.

```powershell
.\steam-cleaner.ps1
.\steam-cleaner.ps1 -Action Download -AppId 2651280 -UserName myaccount -DownloadRoot 'D:\Steam Cleaner Downloads' -KeepTemporaryDepots $false
.\steam-cleaner.ps1 -Action Download -AppId 2651280 -UserName myaccount -ConfigPath .\config\depot-settings.json
.\steam-cleaner.ps1 -Action Reassemble -MetadataPath 'D:\Steam Cleaner Downloads\.depot-cache\2651280\metadata.json' -DownloadRoot 'D:\Steam Cleaner Downloads'
```

Use a game your account can access; the AppID above is only a usage example. No game-specific depot mappings are included. PowerShell 7 is recommended for large games/long paths. The full offline suite also runs on Windows PowerShell 5.1.

Before downloading, the tool displays Game, AppID, Download Location, Temporary Cache, Final Output, and every depot decision. Explicit package grants may be selected; a depot absent from complete package grants is skipped with HIGH confidence. An app-level grant without a complete depot list becomes `REVIEW/LOW` and stops the download. Required shared depots must also be granted. Owned DLC remains excluded, zero-byte depots are recorded without work, and validated Steamworks Common Redistributables are not merged into the game.

Assembly follows stored `MountOrder`; later depots win collisions under Valve's mounting rule, and every collision is logged. LOW-confidence order stops for review. Files are verified in `<InstallDir>.assembling-<id>` before a same-parent rename. Existing final output is never replaced: interactive use offers another root or Cancel.

After **Files Ready / Assembly Complete**, the default removes exactly `.depot-cache\<AppID>`. Enabling **Keep temporary depot files** preserves metadata, receipts, and raw depots for reassembly. Any download, drift, assembly, or verification failure preserves the cache. Steam installation state and prerequisites are not changed.

See [Depot Downloader architecture and operations](docs/depot-downloader.md) for cache layout, retry behavior, limitations and error recovery.

## Run

Close Steam fully, including its background service if running. Back up important files first: configuration, custom skins, mods, and anything outside the three retained items will be deleted without the Recycle Bin. Preserving userdata is not a guarantee that every game's saves are backed up.

```powershell
irm https://raw.githubusercontent.com/dholank/steam-cleaner/main/clean-steam.ps1 | iex
```

Review the displayed location and deletion list. To proceed, type only `DELETE` (uppercase), then press Enter. Do not include the folder path or quotes. Press Enter without typing, or enter anything else, to cancel. There is no unattended confirmation bypass.

Remote execution trusts the current repository contents. Inspect the script first; for a stable version, replace `main` in the URL with a reviewed full commit SHA.

### Preview or custom location

Download the script, inspect it, then run:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/dholank/steam-cleaner/main/clean-steam.ps1 -OutFile .\clean-steam.ps1
.\clean-steam.ps1 -PreviewOnly
.\clean-steam.ps1 -SteamPath 'D:\Steam' -PreviewOnly
.\clean-steam.ps1 -SteamPath 'D:\Steam'
```

Windows PowerShell 5.1 or PowerShell 7 on Windows is required. Follow your organization's execution policy; the script does not change it. Start without administrator privileges. If permission is denied, inspect the error and folder permissions before choosing to elevate.

## Safety behavior

- Detects Steam through HKCU/HKLM registry entries and standard Program Files locations; ambiguous or missing installations require an explicit path.
- Requires both retained directories and a valid Valve-signed steam.exe. A missing directory or signature validation failure stops cleanup; it does not relax checks automatically.
- Rejects drive roots, common protected directories, UNC/relative paths, junctions and symbolic links in the path, retained entries, or deletion tree.
- Checks for Steam processes before preview, after confirmation, and during deletion; never kills them automatically.
- Enumerates hidden files, fails on unreadable content, and compares the deletion plan after confirmation.
- Deletes files individually and directories only when empty. Never recursively follows links; stops on errors and never claims success after a partial failure.

Keep Steam closed and avoid changing the directory during cleanup. Checks reduce accidental deletion but cannot provide transactional rollback or prevent a hostile concurrent process from changing filesystem paths between checks. Partial deletion is possible on errors. Restore from backup if needed. Running steam.exe afterward may recreate client files and download updates.

## Repository

```text
clean-steam.ps1           Standalone remote entry point and functions
steam-cleaner.ps1         Shared CLI menu; local commands and remote package launcher
modules/                 Parser, resolver, SteamCMD, download, metadata and assembly
config/                  Example non-secret downloader settings
docs/                    Architecture and operational limitations
tests/                   120 offline checks, synthetic fixtures, and process/UI adapters
tests/run-tests.ps1       Syntax checks and all offline suites
.github/workflows/test.yml Windows PowerShell 5.1 and 7 checks
```

Run tests with `powershell -NoProfile -File .\tests\safety.tests.ps1` or `pwsh -NoProfile -File .\tests\safety.tests.ps1`. Tests use synthetic directories and never target an installed Steam client.

For the complete suite, run `pwsh -NoProfile -File .\tests\run-tests.ps1` (or `powershell`). There is no separate package build or typecheck for this PowerShell project. The runner parses every PowerShell script before exercising the cleaner, resolver, filesystem pipeline and real child-process wrapper with a compiled offline fixture. Live Steam tests are opt-in; see the operations document.
