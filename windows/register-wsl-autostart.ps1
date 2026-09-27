# Run once from a normal (non-elevated) PowerShell, in this repo's windows\ folder:
#   powershell -ExecutionPolicy Bypass -File .\register-wsl-autostart.ps1 [-Distro Ubuntu-24.04]
#
# WSL2 does not start at Windows logon on its own, so neither does the Docker
# Engine inside the distro nor the tts-serve containers (restart: unless-stopped
# only restarts them once the engine is running). This registers a per-user
# logon task that boots the distro; with instanceIdleTimeout=-1 in .wslconfig
# (see README.md) it then stays up, systemd starts Docker, and Docker starts the
# containers. Safe to re-run: the task is replaced.
param(
    [string]$Distro = "Ubuntu-24.04"
)

$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $Distro --exec /bin/true"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName "Start WSL (TTS-Serve)" `
    -Description "Boots the $Distro WSL distro at logon so Docker and tts-serve come up." `
    -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "Registered logon task 'Start WSL (TTS-Serve)' for distro $Distro."
