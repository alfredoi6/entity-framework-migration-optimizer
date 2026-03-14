<#
.SYNOPSIS
    Manages EF Core migration Designer.cs files -- swaps between full (.generated) and stripped (.slim) versions.

.DESCRIPTION
    File convention:
      *.Designer.cs           Active compiled file (either full or slim content)
      *.Designer.cs.generated Full original with BuildTargetModel body (backup)
      *.Designer.cs.slim      Stripped version with empty BuildTargetModel (backup)

.PARAMETER Action
    slim          Slim a single migration (partial name match)
    restore       Restore a single migration to full .generated version
    slim-all      Slim all migrations
    restore-last  Restore the last N migrations to full versions
    status        Show state of all migrations
    sync-snapshot Update the DbContextModelSnapshot from a migration designer (partial name match)

.PARAMETER Target
    Migration name (partial match) for slim/restore, or count N for restore-last.

.PARAMETER SnapshotFileName
    Name of the model snapshot file. Defaults to auto-detection (*ModelSnapshot.cs).

.EXAMPLE
    .\ef-migration-optimizer.ps1 status
    .\ef-migration-optimizer.ps1 slim AddUserRoles
    .\ef-migration-optimizer.ps1 restore AddUserRoles
    .\ef-migration-optimizer.ps1 slim-all
    .\ef-migration-optimizer.ps1 restore-last 3
    .\ef-migration-optimizer.ps1 sync-snapshot AddPaymentMethods
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("slim", "restore", "slim-all", "restore-last", "status", "sync-snapshot")]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$Target,

    [string]$SnapshotFileName
)

if (-not $Action) {
    Write-Host @"

ef-migration-optimizer.ps1 - Manages EF Core migration Designer.cs files

Actions:
  slim          Slim a single migration (partial name match)
  restore       Restore a single migration to full .generated version
  slim-all      Slim all migrations
  restore-last  Restore the last N migrations to full versions
  status        Show state of all migrations
  sync-snapshot Update the DbContextModelSnapshot from a migration designer (partial name match)

Usage:
  .\ef-migration-optimizer.ps1 status
  .\ef-migration-optimizer.ps1 slim AddUserRoles
  .\ef-migration-optimizer.ps1 restore AddUserRoles
  .\ef-migration-optimizer.ps1 slim-all
  .\ef-migration-optimizer.ps1 restore-last 3
  .\ef-migration-optimizer.ps1 sync-snapshot AddPaymentMethods
"@
    exit 0
}

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-SnapshotFile {
    if ($script:SnapshotFileName) {
        $path = Join-Path $scriptDir $script:SnapshotFileName
        if (Test-Path $path) { return $path }
        throw "Snapshot file not found: $path"
    }
    $candidates = Get-ChildItem -Path $scriptDir -Filter "*ModelSnapshot.cs"
    if ($candidates.Count -eq 0) { throw "No *ModelSnapshot.cs file found in $scriptDir. Use -SnapshotFileName to specify." }
    if ($candidates.Count -gt 1) { throw "Multiple *ModelSnapshot.cs files found. Use -SnapshotFileName to specify which one." }
    return $candidates[0].FullName
}

function Get-MigrationFiles {
    Get-ChildItem -Path $scriptDir -Filter "*.Designer.cs" |
        Where-Object { $_.Name -ne "ef-migration-optimizer.ps1" } |
        Sort-Object Name
}

function Test-IsSlim {
    param([string]$Path)
    $content = Get-Content -Path $Path -Raw
    return ($content -match 'BuildTargetModel\(ModelBuilder modelBuilder\)\s*\{\s*\}')
}

function New-SlimContent {
    param([string]$Path)
    $lines = Get-Content -Path $Path -Encoding UTF8
    $slimLines = @()

    foreach ($line in $lines) {
        $slimLines += $line
        if ($line -match 'protected override void BuildTargetModel\(ModelBuilder modelBuilder\)') {
            $slimLines += "        {"
            $slimLines += "        }"
            $slimLines += "    }"
            $slimLines += "}"
            break
        }
    }

    return $slimLines
}

function Find-Migration {
    param([string]$Name)

    $files = Get-MigrationFiles
    $matches = $files | Where-Object { $_.Name -like "*$Name*" }

    if ($matches.Count -eq 0) {
        Write-Host "No migration found matching '$Name'" -ForegroundColor Red
        return $null
    }
    if ($matches.Count -gt 1) {
        Write-Host "Multiple migrations match '$Name':" -ForegroundColor Yellow
        $matches | ForEach-Object { Write-Host "  $($_.Name)" }
        return $null
    }

    return $matches[0]
}

function Invoke-Slim {
    param([System.IO.FileInfo]$File)

    $designerPath = $File.FullName
    $genPath = "$designerPath.generated"
    $slimPath = "$designerPath.slim"
    $baseName = $File.Name -replace '\.Designer\.cs$', ''

    if (Test-IsSlim $designerPath) {
        Write-Host "  $baseName - already slim, skipping" -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path $genPath)) {
        Copy-Item -Path $designerPath -Destination $genPath -Force
    }

    $slimContent = New-SlimContent -Path $genPath
    $slimContent | Set-Content -Path $slimPath -Encoding UTF8
    $slimContent | Set-Content -Path $designerPath -Encoding UTF8

    $genLines = (Get-Content $genPath).Count
    $newLines = $slimContent.Count
    Write-Host "  $baseName - $genLines -> $newLines lines" -ForegroundColor Green
}

function Invoke-Restore {
    param([System.IO.FileInfo]$File)

    $designerPath = $File.FullName
    $genPath = "$designerPath.generated"
    $baseName = $File.Name -replace '\.Designer\.cs$', ''

    if (-not (Test-Path $genPath)) {
        Write-Host "  $baseName - no .generated backup found, skipping" -ForegroundColor Red
        return
    }

    if (-not (Test-IsSlim $designerPath)) {
        Write-Host "  $baseName - already full, skipping" -ForegroundColor DarkGray
        return
    }

    Copy-Item -Path $genPath -Destination $designerPath -Force
    $lines = (Get-Content $designerPath).Count
    Write-Host "  $baseName - restored ($lines lines)" -ForegroundColor Cyan
}

# --- sync-snapshot helpers ---

function Get-DesignerSourcePath {
    param([System.IO.FileInfo]$DesignerFile)
    $designerPath = $DesignerFile.FullName
    $genPath = "$designerPath.generated"
    if (Test-IsSlim $designerPath) {
        if (-not (Test-Path $genPath)) {
            return $null
        }
        return $genPath
    }
    return $designerPath
}

function Get-ModelBodyFromDesigner {
    param([string]$DesignerPath)
    $lines = Get-Content -Path $DesignerPath -Encoding UTF8
    $startIdx = -1
    $restoreIdx = -1
    $endIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '#pragma warning disable 612, 618') {
            $startIdx = $i
        }
        if ($lines[$i] -match '#pragma warning restore 612, 618') {
            $restoreIdx = $i
        }
        if ($restoreIdx -ge 0 -and $i -gt $restoreIdx -and $endIdx -lt 0) {
            if ($lines[$i] -match '^\s{8}\}\s*$') {
                $endIdx = $i
                break
            }
        }
    }
    if ($startIdx -lt 0 -or $restoreIdx -lt 0 -or $endIdx -lt 0) {
        return $null
    }
    $body = @()
    for ($i = $startIdx; $i -le $endIdx; $i++) {
        $body += $lines[$i]
    }
    return $body
}

function Update-SnapshotFromDesignerBody {
    param(
        [string]$SnapshotPath,
        [string[]]$NewBody,
        [string]$MigrationId
    )
    $lines = Get-Content -Path $SnapshotPath -Encoding UTF8
    $startIdx = -1
    $restoreIdx = -1
    $endIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '#pragma warning disable 612, 618') {
            $startIdx = $i
        }
        if ($lines[$i] -match '#pragma warning restore 612, 618') {
            $restoreIdx = $i
        }
        if ($restoreIdx -ge 0 -and $i -gt $restoreIdx -and $endIdx -lt 0) {
            if ($lines[$i] -match '^\s{8}\}\s*$') {
                $endIdx = $i
                break
            }
        }
    }
    if ($startIdx -lt 0 -or $restoreIdx -lt 0 -or $endIdx -lt 0) {
        throw "Snapshot does not contain expected pragma/brace structure."
    }
    $before = $lines[0..($startIdx - 1)]
    $after = $lines[($endIdx + 1)..($lines.Count - 1)]
    $result = @()
    $result += $before
    $result += $NewBody
    $result += $after

    # Add or update [SnapshotGeneratedFromMigration("MigrationId")] if the attribute type is present in the project
    $snapshotAttrPattern = '\[SnapshotGeneratedFromMigration\("[^"]*"\)\]'
    $newAttr = "[SnapshotGeneratedFromMigration(`"$MigrationId`")]"
    $dbContextLineIdx = -1
    $hasSnapshotAttr = $false
    $snapshotAttrIdx = -1
    for ($i = 0; $i -lt $result.Count; $i++) {
        if ($result[$i] -match '\[DbContext\(typeof') {
            $dbContextLineIdx = $i
        }
        if ($result[$i] -match $snapshotAttrPattern) {
            $hasSnapshotAttr = $true
            $snapshotAttrIdx = $i
            break
        }
    }
    if ($hasSnapshotAttr -and $snapshotAttrIdx -ge 0) {
        $result[$snapshotAttrIdx] = $newAttr
    } elseif ($dbContextLineIdx -ge 0) {
        $insert = @()
        $insert += $result[0..$dbContextLineIdx]
        $insert += "    $newAttr"
        $insert += $result[($dbContextLineIdx + 1)..($result.Count - 1)]
        $result = $insert
    }

    $result | Set-Content -Path $SnapshotPath -Encoding UTF8
}

switch ($Action) {
    "slim" {
        if (-not $Target) {
            Write-Host "Usage: .\ef-migration-optimizer.ps1 slim <migration-name>" -ForegroundColor Yellow
            exit 1
        }
        $file = Find-Migration $Target
        if ($file) {
            Write-Host "Slimming migration:"
            Invoke-Slim $file
        }
    }

    "restore" {
        if (-not $Target) {
            Write-Host "Usage: .\ef-migration-optimizer.ps1 restore <migration-name>" -ForegroundColor Yellow
            exit 1
        }
        $file = Find-Migration $Target
        if ($file) {
            Write-Host "Restoring migration:"
            Invoke-Restore $file
        }
    }

    "slim-all" {
        $files = Get-MigrationFiles
        Write-Host "Slimming $($files.Count) migrations:"
        foreach ($file in $files) {
            Invoke-Slim $file
        }
        Write-Host "`nDone." -ForegroundColor Green
    }

    "restore-last" {
        if (-not $Target -or -not ($Target -match '^\d+$')) {
            Write-Host "Usage: .\ef-migration-optimizer.ps1 restore-last <N>" -ForegroundColor Yellow
            exit 1
        }
        $n = [int]$Target
        $files = Get-MigrationFiles
        if ($n -gt $files.Count) { $n = $files.Count }
        $last = $files | Select-Object -Last $n
        Write-Host "Restoring last $n migration(s):"
        foreach ($file in $last) {
            Invoke-Restore $file
        }
        Write-Host "`nDone. You can now run 'dotnet ef migrations remove'." -ForegroundColor Green
    }

    "status" {
        $files = Get-MigrationFiles
        Write-Host "`nMigration Designer.cs Status ($($files.Count) migrations)`n"
        Write-Host ("{0,-60} {1,-10} {2,-10} {3,-10}" -f "Migration", "Active", ".generated", ".slim")
        Write-Host ("{0,-60} {1,-10} {2,-10} {3,-10}" -f ("-" * 58), ("-" * 8), ("-" * 8), ("-" * 8))

        foreach ($file in $files) {
            $baseName = $file.Name -replace '\.Designer\.cs$', ''
            if ($baseName.Length -gt 57) { $baseName = $baseName.Substring(0, 57) + "..." }

            $isSlim = Test-IsSlim $file.FullName
            $activeLabel = if ($isSlim) { "slim" } else { "full" }
            $hasGen = Test-Path "$($file.FullName).generated"
            $hasSlim = Test-Path "$($file.FullName).slim"
            $genLabel = if ($hasGen) { "yes" } else { "-" }
            $slimLabel = if ($hasSlim) { "yes" } else { "-" }

            $color = if ($isSlim) { "Green" } else { "Cyan" }
            Write-Host ("{0,-60} {1,-10} {2,-10} {3,-10}" -f $baseName, $activeLabel, $genLabel, $slimLabel) -ForegroundColor $color
        }
        Write-Host ""
    }

    "sync-snapshot" {
        if (-not $Target) {
            Write-Host "Usage: .\ef-migration-optimizer.ps1 sync-snapshot <migration-name>" -ForegroundColor Yellow
            exit 1
        }
        $file = Find-Migration $Target
        if (-not $file) { exit 1 }
        $sourcePath = Get-DesignerSourcePath -DesignerFile $file
        if (-not $sourcePath) {
            $baseName = $file.Name -replace '\.Designer\.cs$', ''
            Write-Host "Migration '$baseName' is slim and has no .generated backup. Run: .\ef-migration-optimizer.ps1 restore $Target" -ForegroundColor Red
            exit 1
        }
        $body = Get-ModelBodyFromDesigner -DesignerPath $sourcePath
        if (-not $body) {
            Write-Host "Could not extract model body from designer (missing pragma/brace structure)." -ForegroundColor Red
            exit 1
        }
        $snapshotPath = Find-SnapshotFile
        if (-not (Test-Path $snapshotPath)) {
            Write-Host "Snapshot not found: $snapshotPath" -ForegroundColor Red
            exit 1
        }
        $migrationId = $file.Name -replace '\.Designer\.cs$', ''
        try {
            Update-SnapshotFromDesignerBody -SnapshotPath $snapshotPath -NewBody $body -MigrationId $migrationId
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            exit 1
        }
        Write-Host "Snapshot updated from migration: $migrationId" -ForegroundColor Green
    }
}
