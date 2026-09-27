# Run once from an elevated PowerShell, in this repo's windows\ folder:
#   powershell -ExecutionPolicy Bypass -File .\open-tts-ports.ps1
#
# Lets other machines on the LAN reach the tts-serve containers running in
# WSL2 (mirrored networking mode, see README.md). Ports 7500-7510 cover every
# tts-serve engine plus room for an STT server. Safe to re-run: existing rules
# with the same names are replaced.

$ports = '7500-7510'

# 1. Windows Defender Firewall -- inbound from the local subnet only.
Get-NetFirewallRule -DisplayName 'TTS-Serve (WSL) inbound' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'TTS-Serve (WSL) inbound' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $ports -RemoteAddress LocalSubnet -Profile Private | Out-Null

# 2. Hyper-V firewall -- in mirrored mode WSL traffic is filtered here too, and
#    its default is to block inbound. {40E0AC32-...} is the WSL VM creator id.
$wsl = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
Get-NetFirewallHyperVRule -Name 'TTS-Serve-WSL' -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule
New-NetFirewallHyperVRule -Name 'TTS-Serve-WSL' -DisplayName 'TTS-Serve (WSL) inbound' `
    -Direction Inbound -VMCreatorId $wsl -Protocol TCP -LocalPorts $ports -Action Allow | Out-Null

Write-Host "Opened TCP $ports for the local subnet (Windows + Hyper-V firewall)."
