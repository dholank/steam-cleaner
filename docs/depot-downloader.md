# Depot Downloader: architecture and operations

## Scope

The original Steam cleaner and its `DELETE` confirmation remain available. Depot Downloader is a separate menu action that downloads account-accessible game files without writing a Steam library manifest, registering an install, running an install script, launching a game, or changing the installed Steam client.

The supported automatic target is Windows, x64 or x86, one language, one visible non-password branch, and `DLC=None`. The defaults are Windows, x64, English, and public. Unknown restrictions or incomplete ownership evidence stop the whole automatic operation.

## One Download Location

Interactive menu use opens a WinForms dialog in an STA PowerShell process. The dialog has an editable path, **Browse...**, **Open Folder**, **Keep temporary depot files**, **Continue**, and **Cancel**. Continue validates or creates the directory and performs a temporary write probe. Cancel does not save anything. Settings are atomically stored at `%LOCALAPPDATA%\SteamCleaner\settings.json`.

Value precedence is:

1. Local CLI parameters
2. Explicit JSON config
3. Saved dialog settings
4. `Downloads\Steam Cleaner Downloads`

A saved path that exactly matches the former `Documents\Steam Cleaner Downloads` default resolves to the new Downloads default. This changes the default selection only; old cache or output files are never moved or deleted.

`DownloadRoot` is the only content-location input. For AppID `123` and InstallDir `Game`, paths are derived as:

```text
<DownloadRoot>\
  .depot-cache\
    123\
      metadata.json
      receipt_<DepotID>.json
      depot_<DepotID>\...
      stale\...
  Game\...
```

Legacy `CacheRoot`/`OutputRoot` config migrates only when `CacheRoot` is exactly `<OutputRoot>\.depot-cache`. Any other combination stops with migration guidance and no old data is moved.

If the final output already exists, interactive use allows a different Download Location or Cancel. Scripted use stops with the same guidance. This version does not update or replace existing output.

## SteamCMD and entitlement

SteamCMD is detected from `SteamCmdPath`, the managed tools directory, or PATH. If it must be bootstrapped, only `steamcmd.exe` is extracted from Valve's HTTPS ZIP and its Valve Authenticode signature is required. Password and Steam Guard prompts belong to SteamCMD's native terminal; the project does not accept, capture, or log them.

The typed wrapper supports `app_info_print`, `licenses_for_app`, `licenses_print`, `package_info_print`, `help download_depot`, and `download_depot`. IDs, account names, working directories, and optional destination paths are validated before a process starts. Captured stdout and stderr are drained concurrently. Raw transcripts, passwords, Guard codes, access tokens, and package tokens are never written to the project log.

The resolver works in this order:

1. Confirm each numeric depot belongs to the target AppInfo or a resolved shared source app.
2. Get relevant active package IDs from SteamCMD license metadata.
3. Parse each package's `appids` and `depotids` grant lists.
4. Classify entitlement as true, false, or unknown.
5. Apply DLC, OS, architecture, language, branch, manifest, shared-depot, and mount-order rules.

An explicit active-package depot grant is eligible for selection. A depot absent from complete package grants is `SKIP/HIGH`. An app-level grant with an incomplete depot list is `REVIEW/LOW`, so no ambiguous depot is downloaded. A required shared depot checks its source app/package: unowned is an error and unknown is review. SteamCMD access failures explain ownership, edition, DLC, or branch checks the user can make.

Owned DLC remains skipped under `DLC=None`. A zero-byte selected depot is recorded but neither downloaded nor merged. Steamworks Common Redistributables are skipped only when source AppInfo validates both their Steam component AppID and exact identity; there is no game-specific mapping.

Every decision records entitlement, selection, decision, reason, confidence, content kind, manifest, download state, mount order, source AppID/build, and source package IDs.

## Destination, capacity, and download lifecycle

The client checks `help download_depot` for a destination argument. When available, each depot downloads directly to its cache directory. Otherwise a managed SteamCMD runtime is placed under `<DownloadRoot>\.depot-cache\_steamcmd-runtime`; its normal spool therefore remains on the selected drive, and completed data is copied and hash-verified into the AppID cache.

Before download, the tool estimates peak use as remaining raw depot bytes plus assembly staging bytes plus ten percent headroom, with a minimum 1 GiB headroom. A proven shortage is a hard stop. Missing depot sizes produce an explicit estimate warning.

`metadata.json` is written atomically at `Planned`, updated during `Downloading` and after every depot, then records `Downloaded`, `Assembling`, and `Complete` or a failure state. Each completed depot has a separate receipt and SHA256 inventory. A retry reuses only an exact ManifestID receipt whose inventory still matches. Mismatched or incomplete stable data moves into the AppID's `stale` directory before a new download.

After every selected depot completes, AppInfo, package entitlement, build, branch, manifests, and the plan fingerprint are resolved again. Any drift stops assembly and preserves the cache.

Logs use `%LOCALAPPDATA%\SteamCleaner\logs`. They contain structured decisions and paths, not raw SteamCMD authentication or license transcripts.

## Assembly and cleanup

Assembly sorts by stored `MountOrder`, never numeric DepotID. Later mounted depots replace earlier files according to [Valve's depot mounting rule](https://partner.steamgames.com/doc/store/application/depots). All file collisions are logged. HIGH or MEDIUM order confidence permits later-wins assembly; LOW confidence becomes review before assembly. File/directory shape conflicts always stop.

Raw inventories are verified before copying. Robocopy merges into `<InstallDir>.assembling-<id>` in the Download Location, the complete merged inventory and hashes are verified, and the directory is renamed to `<InstallDir>` in the same parent. A previous final output is never deleted or replaced.

After verified success:

- `KeepTemporaryDepots=false` removes exactly `.depot-cache\<AppID>` and removes `.depot-cache` only if empty.
- `KeepTemporaryDepots=true` keeps metadata, receipts, stale data, and raw depots.

Every failure keeps the AppID cache. A failed assembly with complete receipts can be retried locally with `-Action Reassemble` and the exact metadata path. A successful result says **Files Ready / Assembly Complete** and reminds the user that Steam installation state and prerequisites were not changed.

## Commands

Interactive launcher:

```powershell
irm https://raw.githubusercontent.com/dholank/steam-cleaner/main/steam-cleaner.ps1 | iex
```

Local, noninteractive download:

```powershell
.\steam-cleaner.ps1 -Action Download -AppId 2651280 -UserName myaccount -DownloadRoot 'D:\Steam Cleaner Downloads' -KeepTemporaryDepots $false
```

Offline reassembly from a retained cache:

```powershell
.\steam-cleaner.ps1 -Action Reassemble -MetadataPath 'D:\Steam Cleaner Downloads\.depot-cache\2651280\metadata.json' -DownloadRoot 'D:\Steam Cleaner Downloads'
```

Run all offline tests:

```powershell
powershell -NoProfile -File .\tests\run-tests.ps1
pwsh -NoProfile -File .\tests\run-tests.ps1
```

GitHub Actions runs syntax validation and the full suite in Windows PowerShell 5.1 and PowerShell 7. The 121-check suite covers the original 77 checks plus settings/UI adapters, the Downloads default, atomic settings replacement, package grants, unknown entitlement, generic edition fixtures, DLC, zero-byte and shared depots, Common Redistributables, destination/fallback behavior, exact cache paths, retry/stale handling, disk capacity, cleanup, collision order, transactional output, and prohibited Steam state changes.

Optional live metadata smoke test:

```powershell
pwsh -NoProfile -File .\tests\integration-steamcmd.ps1 -ToolsRoot 'D:\SteamCleanerSmoke\SteamCMD' -AppId 90
```

This optional test initializes SteamCMD and reads metadata; it does not download game depots.

## Limits

- Encrypted or password-protected branches and unsupported VDF conditions require review.
- SteamCMD package output can be incomplete for some products; incomplete evidence deliberately stops instead of guessing.
- Assembly creates files only. Use normal Steam install/discovery/verification later when a game requires Steam, DRM, launchers, anti-cheat, or prerequisites.
- SHA256 inventories verify local transfer and assembly integrity; SteamCMD remains responsible for CDN and manifest authenticity.
- PowerShell 7 is preferred for very deep paths and large file counts. Both Windows PowerShell 5.1 and PowerShell 7 are supported and tested.

Protocol references: [Valve SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD) and [Valve depot documentation](https://partner.steamgames.com/doc/store/application/depots). No SteamDB scraping or SteamKit runtime dependency is used.
