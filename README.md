# Steam Cleaner

PowerShell cleaner for Windows that permanently removes everything inside the selected Steam installation except **steamapps**, **userdata**, and **steam.exe**. It does not clean separate Steam library folders.

## Run

Close Steam fully, including its background service if running. Back up important files first: configuration, custom skins, mods, and anything outside the three retained items will be deleted without the Recycle Bin. Preserving userdata is not a guarantee that every game's saves are backed up.

```powershell
irm https://raw.githubusercontent.com/dholank/steam-cleaner/main/clean-steam.ps1 | iex
```

Review the displayed location and deletion list. To proceed, type `DELETE ` followed by the exact displayed full Steam path. Any other response cancels. There is no unattended confirmation bypass.

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
tests/safety.tests.ps1    Isolated filesystem safety tests
.github/workflows/test.yml Windows PowerShell 5.1 and 7 checks
```

Run tests with `powershell -NoProfile -File .\tests\safety.tests.ps1` or `pwsh -NoProfile -File .\tests\safety.tests.ps1`. Tests use synthetic directories and never target an installed Steam client.
