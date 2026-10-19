param([int]$Port = 8002)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
if (-not (Test-Path -LiteralPath '.venv/Scripts/python.exe')) { python -m venv .venv }
$pythonExe = Join-Path $projectRoot '.venv/Scripts/python.exe'
& $pythonExe -m pip install -r requirements.lock.txt
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed' }
if (-not $env:DATABASE_URL) {
    if (-not (Test-Path -LiteralPath '.local/pgsql/bin/pg_ctl.exe')) {
        New-Item -ItemType Directory -Force .local | Out-Null
        Invoke-WebRequest 'https://get.enterprisedb.com/postgresql/postgresql-17.11-3-windows-x64-binaries.zip' -OutFile '.local/postgresql.zip'
        & $pythonExe -c "import zipfile; z=zipfile.ZipFile('.local/postgresql.zip'); z.extractall('.local')"
    }
    & $pythonExe tools/setup_database.py
    if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL startup failed' }
}
$env:APP_ORIGIN = "http://127.0.0.1:$Port"
& $pythonExe -m uvicorn server.app:app --host 127.0.0.1 --port $Port
