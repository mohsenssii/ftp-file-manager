# FTP Manager

A tiny, portable FTP deployment tool for Windows.

It reads `config.json` and applies **renames → removes → uploads** in that order, all at once, over FTP / FTPS / SFTP using the [WinSCP .NET assembly](https://winscp.net/eng/docs/library).

No installation required. Works with Windows PowerShell 5.1 and PowerShell 7+.

> ⚠️ This repo contains **only dummy data**. Never commit real hosts, usernames or passwords.
> Copy `config.example.json` to `config.json` and fill in your own values locally.

---

## Contents

| File | What it is |
|---|---|
| `FtpManager.ps1` | Main script. Reads config, connects, runs operations. |
| `config.json` | Your local deployment plan (dummy data in git). |
| `config.example.json` | Template to copy from. |
| `FtpConfigEditor.exe` | Portable GUI: edit config, Save, DryRun, Execute (with confirm). |
| `ConfigEditor.cs` | Source code of the GUI. Build with `Build-Gui.bat`. |
| `Run.bat` / `run.sh` | One-click runners for the PowerShell script. |
| `Build-Gui.bat` | Rebuilds the GUI exe with built-in `csc.exe` (no SDK needed). |

`winscp.exe` / `WinSCPnet.dll` are **not** committed (see `.gitignore`). They are downloaded automatically or manually (below).

---

## Requirements

- Windows with PowerShell 5.1+ (Windows 10/11, Windows Server 2022+) or PowerShell 7+
- WinSCP binaries next to the script:
  - `WinSCPnet.dll` + `winscp.exe` (same folder, same version)
  - for PowerShell 7+: also `netstandard2.0/WinSCPnet.dll`

Get them either way:

**A. Automatic (easiest)**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\FtpManager.ps1 -AutoDownloadWinScp -DryRun
```
This downloads the latest stable WinSCP NuGet package (~9 MB) and extracts the 3 files.

**B. Manual**
1. Go to https://winscp.net/eng/download.php
2. Download the **Automation** ZIP (link *“.NET assembly / COM library”*).
3. Extract `WinSCPnet.dll` + `winscp.exe` next to `FtpManager.ps1`.
4. For PowerShell 7+, also extract `netstandard2.0/WinSCPnet.dll`.

---

## Quick start

```powershell
# 1. copy template
copy config.example.json config.json
# 2. edit config.json (or use the GUI below)

# 3. preview without touching the server
powershell -NoProfile -ExecutionPolicy Bypass -File .\FtpManager.ps1 -DryRun

# 4. real deploy
powershell -NoProfile -ExecutionPolicy Bypass -File .\FtpManager.ps1

# or just double-click:
Run.bat
```

Execution order is always:

```
1/3 renames  →  2/3 removes  →  3/3 uploads (overwrite, recursive)
```

Each item is independent — one failure is logged and the rest continue. Exit code `0` = success, `1` = some operations failed, `2` = fatal (bad config / no connection).

---

## Configuration

Full shape (`config.json`):

```json
{
  "ftp": {
    "host": "ftp.example.com",
    "port": 21,
    "username": "demo_user",
    "password": "CHANGE_ME",
    "protocol": "Ftp",
    "remoteRoot": "/",
    "passive": true,
    "timeoutSeconds": 60
  },
  "renames": [
    { "remote_file_address": "httpdocs/old-app.dll", "remote_new_file_name": "old-app.dll.bak" }
  ],
  "removes": [
    { "remote_file_address": "httpdocs/obsolete.txt" }
  ],
  "uploads": [
    {
      "local_file_address": ["C:/deploy/myapp/myapp.dll"],
      "local_folder_address": ["C:/deploy/myapp/assets"],
      "remote_folder": "httpdocs"
    }
  ]
}
```

### `ftp`

| Key | Default | Notes |
|---|---|---|
| `host` | — (required) | Override with `-FtpHost` or env `FTP_HOST`. |
| `port` | `21` (`22` for SFTP) | Override with `-FtpPort`. |
| `username` / `password` | — | Override with `-Username` / `-Password` or env `FTP_USER` / `FTP_PASS`. Empty password = anonymous (warns). |
| `protocol` | `Ftp` | `Ftp` (plain) · `FtpExplicit` / `FtpImplicit` (FTPS) · `Sftp`. |
| `remoteRoot` | `/` | Base that all relative `remote_*` paths resolve against. A path starting with `/` is absolute. |
| `passive` | `true` | `true` = passive, `false` = active. |
| `timeoutSeconds` | `60` | Connection timeout. |
| `sshHostKeyFingerprint` | — | Required for SFTP in production (or `-AcceptAnySshHostKey` for testing only). |
| `tlsFingerprint` / `acceptAnyCertificate` | — | For FTPS (or `-AcceptAnyCertificate` for testing only, insecure). |

Credentials precedence: **CLI params → `ftp.*` in config → env vars**.

### `renames`

Rename / move remote files **and** folders (`Session.MoveFile`).

- `remote_file_address`: source, relative to `remoteRoot`.
- `remote_new_file_name`: just the new name (`new.txt`), or a relative/absolute target path if it contains `/`.
- Missing / empty entries are skipped. Identical source/target is skipped.

### `removes`

Delete remote files **and** folders (recursive).

- Each entry: `{ "remote_file_address": "htdocs/old.txt" }` (plain strings also accepted).
- Folders are emptied (`/*`) then removed. Missing paths are reported as failures, empty list is skipped.

### `uploads`

Upload local files + folders to a remote folder (overwrite, binary mode, recursive, Windows copy/paste semantics: local folder `assets` → remote `htdocs/assets/`).

- `local_file_address`: string or array of files.
- `local_folder_address`: string or array of folders.
- `remote_folder`: target dir (created if needed).
- A file listed under `local_folder_address` (or vice versa) is skipped with a warning.
- Local paths may use `/` or `\`; the script normalizes to absolute Windows paths before calling WinSCP.

All sections are optional — missing / `null` / `[]` is skipped.

---

## GUI editor

`FtpConfigEditor.exe` — portable, no install (needs only .NET Framework, preinstalled on Windows).

- 4 tabs: **FTP · Renames · Removes · Uploads**
- `+ Add row` / `− Delete row`, `+File…` / `+Folder…` browse buttons
- Multiple local paths per upload cell: separate with `;`
- **💾 SAVE config.json** — writes pretty JSON next to the exe
- **🔍 DryRun** — safe preview, output streamed to the log box
- **🚀 EXECUTE deploy** — asks `Yes/No` confirmation, then runs the real deploy and streams the log + exit code

Rebuild from source any time (no SDK needed):

```
Build-Gui.bat
```

which runs:

```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /t:winexe /out:FtpConfigEditor.exe ConfigEditor.cs ...
```

---

## CLI reference

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\FtpManager.ps1 `
  -ConfigPath .\config.json `
  -FtpHost ftp.example.com -FtpPort 21 -Username u -Password p `
  -Protocol Ftp -RemoteRoot / `
  -AutoDownloadWinScp -DryRun -LogPath .\deploy.log
```

| Param | Purpose |
|---|---|
| `-ConfigPath` | Path to JSON (default: `config.json` next to script). |
| `-FtpHost/-FtpPort/-Username/-Password/-Protocol/-RemoteRoot` | Override `ftp.*` / env. |
| `-WinScpDllPath/-WinScpExePath` | Custom WinSCP binary locations. |
| `-AutoDownloadWinScp` | Download WinSCP from NuGet if missing. |
| `-DryRun` | Log what *would* happen, no connection/changes. |
| `-LogPath` | Append console output to a file. |
| `-AcceptAnyCertificate/-AcceptAnySshHostKey` | Testing only (insecure). Prefer fingerprints in config. |

`Run.bat` forwards args: `Run.bat -DryRun`. `run.sh` is the Git Bash equivalent.

---

## Security

- The repo ships with `ftp.example.com / demo_user / CHANGE_ME` only.
- Never commit real `config.json` credentials. Prefer env vars in CI:
  `FTP_HOST`, `FTP_USER`, `FTP_PASS`, plus `FTP_SSH_FINGERPRINT` / `FTP_TLS_FINGERPRINT`.
- Prefer SFTP or FTPS with fingerprints in production. Plain FTP sends passwords in cleartext.
- `*.log` and WinSCP binaries are gitignored — session logs can contain hostnames.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `WinSCPnet.dll not found` | Run with `-AutoDownloadWinScp` or do the manual Automation-ZIP step. |
| `Upload FAILED: … does not exist` / `C:\<name> does not exist` | Local path wrong — the script resolves via `Get-Item … .FullName`, check the file exists. Use `;` to separate multiple paths. |
| `renames FAILED: source not found` | Already renamed / wrong `remote_file_address`. Uploads still run. |
| `FTP connect failed` | Host/port/user/pass, firewall, `passive` true/false, `protocol` (plain vs Explicit/Implicit vs Sftp). Try `-DryRun` first, check `ftp-session-*.log`. |
| `.nupkg is not a supported archive` (old versions) | Fixed — the script copies `.nupkg` → `.nupkg.zip` before `Expand-Archive` and prefers `curl.exe`. Update to latest `FtpManager.ps1`. |

---

## Contributing

PRs welcome: keep PowerShell 5.1 compatibility (no `?.`, no `??`), test `DryRun` + real deploy against a test server, and never add real credentials to fixtures.

## License

MIT — see [LICENSE](LICENSE).
