$ErrorActionPreference = 'Stop'

$repo = if ($env:RTSP30_REPO) { $env:RTSP30_REPO } else { 'yyling0101-a11y/recamera-rtsp30' }
$branch = if ($env:RTSP30_BRANCH) { $env:RTSP30_BRANCH } else { 'main' }
$deviceIp = Read-Host 'reCamera IP address'
$deviceUser = Read-Host 'SSH username'
$securePassword = Read-Host 'SSH password' -AsSecureString

if ([string]::IsNullOrWhiteSpace($deviceIp) -or [string]::IsNullOrWhiteSpace($deviceUser)) {
    throw 'IP address and username are required.'
}
$passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
    $env:RTSP30_DEVICE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
}
$env:RTSP30_DEVICE_IP = $deviceIp
$env:RTSP30_DEVICE_USER = $deviceUser
$env:RTSP30_REPO = $repo
$env:RTSP30_BRANCH = $branch

$python = Get-Command py -ErrorAction SilentlyContinue
if ($python) {
    $pythonCommand = 'py'
    $pythonArgs = @('-3')
} else {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw 'Python 3 is required. Install Python 3 and run this script again.' }
    $pythonCommand = $python.Source
    $pythonArgs = @()
}

$tempScript = Join-Path ([IO.Path]::GetTempPath()) ('rtsp30-pc-deploy-' + [guid]::NewGuid().ToString() + '.py')
try {
    $helperUrl = "https://raw.githubusercontent.com/$repo/$branch/tools/pc-deploy.py"
    Invoke-WebRequest -Uri $helperUrl -OutFile $tempScript
    & $pythonCommand @pythonArgs $tempScript
    if ($LASTEXITCODE -ne 0) { throw "Deployment failed with exit code $LASTEXITCODE." }
} finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    Remove-Item Env:RTSP30_DEVICE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:RTSP30_DEVICE_IP -ErrorAction SilentlyContinue
    Remove-Item Env:RTSP30_DEVICE_USER -ErrorAction SilentlyContinue
    Remove-Item Env:RTSP30_REPO -ErrorAction SilentlyContinue
    Remove-Item Env:RTSP30_BRANCH -ErrorAction SilentlyContinue
}
