param(
    [string]$DeviceId
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendRoot = Join-Path $ProjectRoot 'backend'
$ApiUrl = 'http://127.0.0.1:8000/api/v1'
$HealthUrl = "$ApiUrl/health"
$BackendProcess = $null
$StartedBackend = $false
$ServerOut = Join-Path $env:TEMP 'localspot-serve.out.log'
$ServerErr = Join-Path $env:TEMP 'localspot-serve.err.log'

function Get-HealthyLocalSpotApi {
    try {
        # Health checks both OAuth token acquisition and a Firestore read.
        # Allow extra time on the first request while credentials initialize.
        $response = Invoke-RestMethod -Uri $HealthUrl -TimeoutSec 45
        return $response.data.ok -eq $true -and
            $response.data.database -eq 'up' -and
            $response.data.database_type -eq 'firestore'
    } catch {
        return $false
    }
}

function Test-LocalPort([int]$Port) {
    return Test-NetConnection -ComputerName '127.0.0.1' -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue
}

$FlutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
$PhpCommand = Get-Command php -ErrorAction SilentlyContinue
if ($null -eq $FlutterCommand) { throw 'Flutter was not found on PATH. Install Flutter or add its bin folder to PATH.' }
if ($null -eq $PhpCommand) { throw 'PHP was not found on PATH. Install PHP or add it to PATH.' }
if (-not (Test-Path (Join-Path $BackendRoot '.env'))) {
    throw "backend/.env is missing. Configure the backend first (see docs/OPERATIONS.md)."
}

$AdbCommand = Get-Command adb -ErrorAction SilentlyContinue
$AdbPath = if ($AdbCommand) { $AdbCommand.Source } else { $null }
if (-not $AdbPath) {
    $LocalProperties = Join-Path $ProjectRoot 'android/local.properties'
    if (Test-Path $LocalProperties) {
        $SdkLine = Get-Content $LocalProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
        if ($SdkLine) {
            $SdkRoot = ($SdkLine -split '=', 2)[1] -replace '\\\\', '\'
            $CandidateAdb = Join-Path $SdkRoot 'platform-tools/adb.exe'
            if (Test-Path $CandidateAdb) { $AdbPath = $CandidateAdb }
        }
    }
}
if (-not $AdbPath) {
    foreach ($SdkRoot in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)) {
        if ($SdkRoot) {
            $CandidateAdb = Join-Path $SdkRoot 'platform-tools/adb.exe'
            if (Test-Path $CandidateAdb) { $AdbPath = $CandidateAdb; break }
        }
    }
}
if (-not $AdbPath) {
    throw 'ADB was not found. Install Android SDK Platform-Tools or add adb to PATH.'
}

$DeviceLines = @(& $AdbPath devices | Select-Object -Skip 1 | Where-Object { $_ -match '^\s*\S+\s+device\s*$' })
if ($LASTEXITCODE -ne 0) { throw 'ADB could not start. Check Android SDK Platform-Tools.' }
$ConnectedDevices = @($DeviceLines | ForEach-Object { ($_ -split '\s+')[0] })
if (-not $DeviceId) {
    if ($ConnectedDevices.Count -eq 0) {
        throw 'No authorized Android device found. Connect the phone, enable USB debugging, accept its prompt, then retry.'
    }
    if ($ConnectedDevices.Count -eq 1) {
        $DeviceId = $ConnectedDevices[0]
    } else {
        Write-Host 'Connected Android devices:'
        $ConnectedDevices | ForEach-Object { Write-Host "  $_" }
        $DeviceId = Read-Host 'Enter the device ID to use'
    }
}
if ($ConnectedDevices -notcontains $DeviceId) {
    throw "Device '$DeviceId' is not connected and authorized. Run 'adb devices' and retry."
}

& $AdbPath -s $DeviceId reverse tcp:8000 tcp:8000 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'ADB port forwarding failed. Reconnect the phone and retry.' }
Write-Host "Forwarded phone port 8000 to this PC for device $DeviceId."

Push-Location $ProjectRoot
try {
    Write-Host 'Resolving Flutter dependencies...'
    & $FlutterCommand.Source pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }

    if (Test-LocalPort 8000) {
        if (-not (Get-HealthyLocalSpotApi)) {
            throw 'Port 8000 is already in use, but the LocalSpot API and Firestore health check failed. Stop the other service or check backend/storage/logs/laravel.log.'
        }
        Write-Host 'Using the healthy LocalSpot API already running on port 8000.'
    } else {
        Write-Host 'Starting Laravel...'
        $BackendProcess = Start-Process `
            -FilePath $PhpCommand.Source `
            -ArgumentList @('artisan', 'serve', '--host=127.0.0.1', '--port=8000') `
            -WorkingDirectory $BackendRoot `
            -WindowStyle Hidden `
            -RedirectStandardOutput $ServerOut `
            -RedirectStandardError $ServerErr `
            -PassThru
        $StartedBackend = $true

        $PortReady = $false
        for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
            if ($BackendProcess.HasExited) { break }
            if (Test-LocalPort 8000) { $PortReady = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $PortReady) {
            throw "Laravel did not open port 8000. Check $ServerOut and $ServerErr."
        }
        if (-not (Get-HealthyLocalSpotApi)) {
            throw "Laravel started, but Firestore health check failed. Check backend/storage/logs/laravel.log for the reported cause, then verify backend/.env and server credentials."
        }
        Write-Host 'Laravel and Firestore are ready.'
    }

    Write-Host "Running LocalSpot on $DeviceId against $ApiUrl. Press Ctrl+C to stop."
    & $FlutterCommand.Source run -d $DeviceId "--dart-define=LARAVEL_API_URL=$ApiUrl"
    $FlutterExitCode = $LASTEXITCODE
} finally {
    if ($StartedBackend -and $BackendProcess -and -not $BackendProcess.HasExited) {
        Write-Host 'Stopping the Laravel process started by this script...'
        & taskkill.exe /PID $BackendProcess.Id /T /F | Out-Null
    }
    Pop-Location
}

if ($null -ne $FlutterExitCode -and $FlutterExitCode -ne 0) {
    exit $FlutterExitCode
}
