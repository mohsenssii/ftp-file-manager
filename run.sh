#!/usr/bin/env bash
# FTP Manager runner (bash / Git Bash)
cd "$(dirname "$0")"
powershell -NoProfile -ExecutionPolicy Bypass -File "./FtpManager.ps1" "$@"
echo "Exit code: $?"
