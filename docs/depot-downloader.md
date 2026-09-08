# Depot Downloader: architecture and operations

## Existing project and integration

Before this feature, the complete repository consisted of `clean-steam.ps1`, its safety tests, README, ignore rules and a Windows GitHub Actions workflow. It was Windows PowerShell 5.1-compatible, using Verb-Noun functions, `Write-Host`, `Read-Host`, terminating safety errors and an outer CLI error boundary. There was no GUI, dependency manager, settings store, file-copy abstraction, persistent logger, library finder or explicit cancellation service.

The cleaner entry point and `DELETE` confirmation remain available unchanged. The only extension inside its utilities is `Assert-LocalDirectory -AllowProtectedAncestor`: a caller creating a child of Documents or a drive root can validate that parent's filesystem/link chain. Actual deletion targets still use the original strict checks. The downloader reuses this guard, `Get-CleanupNode` for non-following traversal, and `Find-SteamRoot` to prevent cache/tools/output from overlapping a known client installation.

`steam-cleaner.ps1` adds a text menu and dispatches to these components:

| Component | Responsibility |
| --- | --- |
| `modules/DepotSupport.ps1` | Non-secret JSON settings, validated paths/IDs, structured logging, reuse of cleaner traversal |
| `modules/SteamCmdClient.ps1` | Detect or install Valve-signed SteamCMD, native interactive login, typed commands, concurrent stdout/stderr capture, timeout and error classification |
| `modules/AppInfoParser.ps1` | Ordered VDF parsing and extraction of one AppInfo object from console output |
| `modules/DepotResolver.ps1` | Restrictions, DLC and shared references, selected branch manifests, confidence and reasons |
| `modules/DepotMetadata.ps1` | Version identity, atomic JSON metadata, local SHA256 inventories, offline metadata validation |
| `modules/DepotDownloader.ps1` | Download all depots, completion checks, receipts, retries, drift detection, orchestration |
| `modules/DepotAssembler.ps1` | Collision preflight, merge into staging, hash verification, same-parent final rename |

The UI contains no depot selection or merge logic. The project stays PowerShell; the small C# fixture in tests is only a fake console executable for process-I/O tests.

## Resolution

SteamCMD retrieves `app_info_update 1` and `app_info_print <AppID>`. The parser keeps key enumeration order and exact decimal manifest strings, including values above signed 64-bit range. It rejects duplicate keys, truncated objects and unsupported VDF conditionals/directives.

The resolver prefers `config/installdir` exactly, after validating it as one Windows directory component. A malformed supplied InstallDir is an error. Only a missing InstallDir falls back to the sanitized game name. Reserved device names, path separators, traversal, alternate streams, trailing dots/spaces and control characters are rejected.

For each numeric depot entry, without deriving meaning from its ID:

1. Follow `depotfromapp` references with a recursion/cycle limit; inherit source restrictions and manifests. Conflicting restrictions require review.
2. Exclude DLC, nonselected OS, architecture or language depots with reasons.
3. Reject unknown applicable restrictions and separately mounted shared-install content as REVIEW.
4. Select only the chosen branch's visible manifest, accepting scalar and `gid` forms. Never substitute public for a missing beta manifest.
5. Record source AppID/build, configuration, DLC relationship, expected bytes when available, selected manifest, and ordering confidence.

HIGH means a supported metadata rule clearly decides inclusion/exclusion. Shared-source resolution is MEDIUM. Unresolved potential base depots are LOW/REVIEW and block the entire automatic selection. Overall confidence remains at most MEDIUM because AppInfo enumeration is not an independently verified Steam mount priority. Game names or numbers do not determine selection.

The source branch/build for shared depots can differ from the parent application's build; both are tracked. After all downloads, AppInfo is fetched again, including shared sources, and the selected configuration/build/manifest fingerprint is compared. Drift prevents automatic assembly. The pinned downloaded snapshot remains available for deliberate offline reassembly.

## SteamCMD and authentication

Detection uses an explicitly configured `SteamCmdPath`, the managed ToolsRoot, then PATH. If absent, only `steamcmd.exe` is extracted from Valve's HTTPS bootstrap ZIP, and a valid Valve Authenticode signature is required before execution. No arbitrary archive path is extracted.

For a named account, SteamCMD runs interactively with `+login <username> +quit`. Password/Guard handling belongs to the native terminal. The application does not intercept, save or log this session. Do not use PowerShell transcription during authentication. SteamCMD itself may maintain its own cached login/session files in its tools directory; protect that directory and do not publish it.

Subsequent operations use cached authentication with `@NoPromptForPassword 1`. If that session cannot be reused, the operation fails with instructions to authenticate again. No password, Guard code, Steam API key or branch password setting exists. SteamCMD performs actual ownership checks; retail games generally require an owning account. Native login failure details are visible in the native terminal, while captured operations use actionable error categories.

All automated commands are constructed from validated IDs and a validated login name. AppInfo text is never executed. The wrapper captures both output streams in memory concurrently, checks exit status and Steam-specific errors, and does not persist raw transcripts. A timed-out/cancelled captured operation terminates its owned child process in `finally`. Do not run another SteamCMD process against the same tools folder concurrently; the app uses locks to serialize its own workflows.

Progress reports the current depot and elapsed time. It does not invent a percentage when SteamCMD supplies no reliable percentage stream.

## Downloads, metadata and retry

```text
DepotCache/
  download-<time>-<id>.log
  <AppID>/
    <configuration-and-manifest-fingerprint>/
      metadata.json
      depot_<ID>.receipt.json
      depot_<ID>/...
      depot_<other-ID>/...
```

The extra fingerprint level keeps versions/configurations isolated. Within each snapshot, raw depot contents remain separate. A receipt identifies the pinned manifest, completion time and per-file length/SHA256 inventory. `metadata.json` contains the full plan, all decisions, build/configuration identity and every completed receipt. It is written as Downloaded only after **all** selected depots succeeded.

SteamCMD writes under its own `steamapps/content/app_<AppID>/depot_<DepotID>`. Earlier contents there are renamed to a unique `.previous-*` sibling before a fresh download, so stale files cannot contaminate another manifest. A success message must name the expected directory and manifest. Reported file count and AppInfo byte size are checked when supplied. Data is copied into a cache `.incoming-*` folder, verified, then renamed into the stable raw depot folder.

Retrying the same AppID/settings resolves the same snapshot and hashes completed cached depots before reuse. It downloads only depots without a completed cache receipt. Interrupted native SteamCMD spool/incoming directories are preserved for diagnosis, not silently trusted; individual partial native downloads are not resumed in place. An orphan stable cache without a valid receipt requires a new cache location or manual inspection. Cached corruption stops rather than silently substituting another version.

Local SHA256 inventories detect later corruption and verify copied/assembled bytes. They are **not** an independent implementation of Steam manifest signatures or a guarantee that publisher depot selection is complete. SteamCMD remains responsible for its CDN/manifest download protocol.

## Assembly and collisions

All raw sources are checked first. File/directory conflicts always stop. Identical file collisions can merge safely. Different-content file collisions stop under the default `CollisionPolicy=Stop`. Logs identify the relative path, existing depot, incoming depot and decision.

An explicit `CollisionPolicy=AppInfoOrder` uses preserved AppInfo order, with later depots winning; it still labels that order as unverified. Depot IDs are never numerically sorted for mounting. The override affects collisions only and cannot bypass REVIEW depots, invalid paths, missing manifests or failed downloads.

Merge uses Windows robocopy `/E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ` into `<InstallDir>.assembling-<unique-id>`, never `/MIR`. Expected merged file hashes are verified before the staging folder is renamed to `<InstallDir>` in the same parent. Existing destinations are refused; select another OutputRoot or cancel. No existing game is deleted or replaced automatically.

On disk-full, locked-file, permission, integrity or other assembly errors, raw cache and existing output remain. Partial staging remains clearly named for inspection. Check available space and retry assembly from metadata into an unused output location.

The default keeps raw cache. After success, `n` then `DELETE` deletes only the selected raw folders of that snapshot after the verified assembly result. Metadata/receipts remain, but offline reassembly then requires restoring raw files. This action deliberately does not delete SteamCMD's separate spool or `.previous-*` directories. Those may include earlier native downloads; manage them separately after checking their contents.

## Settings and manual testing

Copy `config/depot-settings.example.json` to an ignored `config/depot-settings.json` and adjust paths to existing local drives. Do not put credentials in the file. Unrecognized settings are rejected.

Defaults are Windows/x64/English/public/no DLC. Version 1 also accepts x86, other language tokens and visible non-password branch names. Linux/macOS downloading, Owned-DLC selection and encrypted/private branches are not implemented. The separated settings/resolver/metadata interfaces make these future additions possible without altering the cleaner.

1. Run the original cleaner's `-PreviewOnly` flow to check compatibility without deleting client data.
2. Run `steam-cleaner.ps1`, choose Depot Downloader, provide settings (or Enter for defaults), AppID, and a login account with access.
3. Complete native login/Guard prompts. Inspect the resolver decisions.
4. Confirm the resulting directory contains game files directly, plus a separate cache snapshot with metadata and receipts.
5. Keep cache, choose a different OutputRoot, and use `-Action Reassemble -MetadataPath <snapshot metadata>` to test offline reconstruction.
6. For games requiring Steam, use normal Steam install/discovery/verification later. Do not expect assembled files alone to create a working Steam installation.

Automated, network-free checks:

```powershell
powershell -NoProfile -File .\tests\run-tests.ps1
pwsh -NoProfile -File .\tests\run-tests.ps1
```

The process fixture is compiled with Windows PowerShell's bundled compiler. No paid game/account is used in any default test. CI runs both shells. Syntax parsing is the project's static check; no external linter/typechecker/build system was previously configured.

Optional live **metadata-only** test (downloads/initializes SteamCMD, but no game depots):

```powershell
pwsh -NoProfile -File .\tests\integration-steamcmd.ps1 -ToolsRoot 'D:\SteamCleanerSmoke\SteamCMD' -AppId 90
```

Development validation: offline suites exercise filters, parser, shared sources, ambiguity, exact manifest IDs, serialization, collision handling, rollback boundaries, retry, drift, process streams/errors/timeouts and existing cleaner behavior. The development environment could not establish TLS to Valve's CDN, so live SteamCMD bootstrap/login/depot download were not verified here. Do not treat offline fixtures as proof that every publisher layout works.

## Boundaries and future work

- Assembly outputs files, not a Steam-installed state. No `appmanifest_<appid>.acf` is forged and no prerequisite, DRM, launcher, anti-cheat or installscript is run.
- Password-protected manifests and unknown depot restrictions stop for review. Some applications do not expose enough metadata through the chosen account.
- Shared-install layouts requiring a separate target are blocked rather than flattened incorrectly. Owned DLC and richer publisher mounting rules need additional metadata/entitlement support.
- Robocopy supports long paths, but Windows PowerShell 5.1/.NET filesystem and hash operations may still reject some deep paths. Prefer PowerShell 7 and short cache/output roots; failures preserve source data.
- Verification currently uses in-memory inventories. Very large file counts can use substantial memory; streaming inventory storage and independent manifest-level checks are future improvements.
- Native spool, raw cache and final output can occupy roughly three copies, plus preserved interrupted/old data. No automatic deletion reclaims earlier spool snapshots.
- Version-1 output handling is choose-another-directory/cancel. Transactional replacement with a retained backup, richer resume/update, and a cache browser can build on existing metadata.
- Filesystem checks are not a security boundary against another process actively swapping paths after validation. Keep tools/cache/output under your own control during operations.

## Protocol references

- [Valve SteamCMD documentation](https://developer.valvesoftware.com/wiki/SteamCMD): installation and authentication workflow.
- [Valve depot mounting rules](https://partner.steamgames.com/doc/store/application/depots): OS, architecture, language, DLC restrictions and later-depot precedence.
- [SteamRE DepotDownloader implementation](https://github.com/SteamRE/DepotDownloader/blob/master/DepotDownloader/ContentDownloader.cs): reference for AppInfo shared-depot and scalar/structured manifest handling; not a runtime dependency and no source was copied.

SteamDB scraping is not used.
