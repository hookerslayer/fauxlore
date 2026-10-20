param([int]$Port = 8004)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$pythonPath = Join-Path $projectRoot '.venv/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $pythonPath)) { $pythonPath = (Get-Command python -ErrorAction Stop).Source }
Push-Location $projectRoot
try {
    & $pythonPath tools/build_supabase_site.py
    if ($LASTEXITCODE -ne 0) { throw 'Сборка карты завершилась с ошибкой' }
    Write-Host "Fauxlore (Supabase): http://127.0.0.1:$Port/"
    & $pythonPath -m http.server $Port --bind 127.0.0.1 --directory .local/supabase-site
} finally { Pop-Location }
