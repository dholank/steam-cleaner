# Steam Cleaner

[![Safety checks](https://github.com/dholank/steam-cleaner/actions/workflows/test.yml/badge.svg)](https://github.com/dholank/steam-cleaner/actions/workflows/test.yml)
![Windows](https://img.shields.io/badge/platform-Windows-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)

Steam Cleaner is a PowerShell script that resets the Steam client files while preserving your game library and Steam user data.

The script preserves only:

```text
Steam\
|- steamapps\   Installed games and Steam libraries
|- userdata\    User data and some save/configuration files
`- steam.exe    Steam launcher
```

All other files and folders inside the Steam installation directory are permanently deleted, including custom folders such as `opensteamtool`.

> [!CAUTION]
> Deleted items do not go to the Recycle Bin. Close Steam and back up anything you need from the Steam folder before continuing. Only `steamapps`, `userdata`, and `steam.exe` are preserved.

## Quick Start

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/dholank/steam-cleaner/main/steam-cleaner.ps1 | iex
```

Steam Cleaner will:

1. Detect the Steam installation directory.
2. Validate the Valve digital signature on `steam.exe`.
3. Confirm that Steam and its background processes are closed.
4. Display the Steam location, target count, total size, and a concise deletion preview. Each folder appears once; its contents are included in the totals.
5. Wait for explicit confirmation before deleting anything.
6. Recheck the directory so newly created or changed items are not deleted unexpectedly.

Steam Cleaner checks the registry and standard install locations first. If those checks find no valid installation, it scans fixed local drives for `steam.exe`; this can take a while. Any discovered folder must contain `steamapps`, `userdata`, and a Valve-signed `steam.exe`. If more than one valid installation is found, Steam Cleaner asks for the full path to the one you want to clean. Press Enter to cancel.

When the confirmation prompt appears, type exactly:

```text
DELETE
```

Type only `DELETE`, without the path, quotation marks, or additional text. Press Enter without typing anything to cancel.

## Preview Without Deleting

Download the script first:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/dholank/steam-cleaner/main/steam-cleaner.ps1 -OutFile .\steam-cleaner.ps1
```

Run it in preview mode:

```powershell
.\steam-cleaner.ps1 -PreviewOnly
```

If Steam is installed in a custom location:

```powershell
.\steam-cleaner.ps1 -SteamPath 'D:\Steam' -PreviewOnly
```

Remove `-PreviewOnly` after reviewing the deletion list and when you are ready to clean the directory.

## What Is Preserved and Deleted

| Location | Result |
| --- | --- |
| `steamapps` | Preserved, including installed games. |
| `userdata` | Preserved. |
| `steam.exe` | Preserved. |
| All other contents, including `opensteamtool` and other custom folders | Permanently deleted. Back up anything you need first. |

Steam will normally download the required client files again the first time it starts after cleanup.

## Troubleshooting

### Steam is still running

Select **Steam > Exit**, then check Task Manager. Steam Cleaner does not terminate Steam processes automatically.

### Steam installation was not found

After automatic detection and the local drive scan, enter the full Steam folder path at the prompt. To provide it explicitly or run without prompts, download the script and use:

```powershell
.\steam-cleaner.ps1 -SteamPath 'D:\Steam'
```

### The digital signature is invalid

Make sure `steam.exe` comes from an official Steam installation. The script rejects executables that do not have a valid Valve signature.

### The directory changed after the preview

Another process created or modified files after the preview was displayed. Close Steam and related programs, then run Steam Cleaner again.

## Safety Measures

- Rejects drive roots, UNC paths, relative paths, and protected system directories.
- Confirms that `steamapps`, `userdata`, and `steam.exe` have the expected types and are not links.
- Preserves only `steamapps`, `userdata`, and `steam.exe`; other Steam folder contents are included in the deletion preview.
- Validates `steam.exe` with its Valve Authenticode signature.
- Treats junctions and symbolic links as single deletion targets without opening or following their destinations.
- Rechecks the complete deletion plan after confirmation.
- Deletes directories only after their verified contents have been removed.
- Stops if Steam starts again or a target changes during cleanup.

Remote execution trusts the contents of this repository. For controlled use, replace `main` in the raw URL with a full commit SHA that you have reviewed.

## Development

Repository structure:

```text
steam-cleaner.ps1            Main cleaner and irm | iex entry point
clean-steam.ps1              Compatibility alias for the original URL
tests\safety.tests.ps1       Checks using a synthetic Steam installation
tests\run-tests.ps1          Syntax validation and test runner
.github\workflows\test.yml  Windows PowerShell 5.1 and PowerShell 7
```

Run the offline checks:

```powershell
powershell -NoProfile -File .\tests\run-tests.ps1
pwsh -NoProfile -File .\tests\run-tests.ps1
```

The test fixture uses a dedicated temporary directory and never touches the user's Steam installation.


