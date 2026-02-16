# Vaultwarden-PersonalVaultAnalysis.ps1
# Analysiert die Ordnerstruktur im PERSÖNLICHEN Vault vor der Organisation-Migration
# Zeigt was zur Organisation migriert werden soll

param(
    [string]$OrganizationId = "89f44255-10ff-455f-96e1-f4a4470f16e4"
)

Write-Host "=== VAULTWARDEN PERSÖNLICHER VAULT ANALYSE ===" -ForegroundColor Magenta
Write-Host "Zielorganisation: $OrganizationId`n" -ForegroundColor Yellow

# Session check
try {
    $session = bw unlock --raw
    if (-not $session) {
        Write-Host "FEHLER: Bitwarden nicht entsperrt. Führe 'bw unlock' aus." -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "FEHLER: Bitwarden CLI nicht verfügbar oder nicht eingeloggt." -ForegroundColor Red
    Write-Host "Installation: npm install -g @bitwarden/cli" -ForegroundColor Yellow
    Write-Host "Login: bw config server https://vault.cloud.jivs.com && bw login" -ForegroundColor Yellow
    exit 1
}

Write-Host "✅ Bitwarden Session aktiv" -ForegroundColor Green

# 1. Persönliche Items laden (ohne Organisation)
Write-Host "`n--- LADE PERSÖNLICHE VAULT DATEN ---" -ForegroundColor Cyan
$personalItems = bw list items --session $session | ConvertFrom-Json | Where-Object { -not $_.organizationId }
Write-Host "Gefunden: $($personalItems.Count) Items im persönlichen Vault" -ForegroundColor Green

# 2. Persönliche Ordner laden
$allFolders = bw list folders --session $session | ConvertFrom-Json
$folderLookup = @{}
foreach ($folder in $allFolders) {
    if ($folder.id) {  # Nur Ordner mit gültiger ID
        $folderLookup[$folder.id] = $folder.name
    }
}
Write-Host "Verfügbare Ordner: $($allFolders.Count) (davon $($folderLookup.Count) mit gültiger ID)" -ForegroundColor Green

# 3. Organisation prüfen
try {
    $orgItems = bw list items --organizationid $OrganizationId --session $session | ConvertFrom-Json
    $orgCollections = bw list collections --organizationid $OrganizationId --session $session | ConvertFrom-Json
    Write-Host "Organisation enthält bereits: $($orgItems.Count) Items in $($orgCollections.Count) Collections" -ForegroundColor Yellow
} catch {
    Write-Host "⚠️  Kann Organisation nicht laden - prüfe ID und Berechtigung" -ForegroundColor Yellow
}

if ($personalItems.Count -eq 0) {
    Write-Host "`n❌ KEINE PERSÖNLICHEN ITEMS GEFUNDEN" -ForegroundColor Red
    Write-Host "Möglicherweise wurden bereits alle Items zur Organisation migriert." -ForegroundColor Yellow
    Write-Host "Verwende stattdessen: .\Vaultwarden-StructureAnalysis.ps1" -ForegroundColor Cyan
    exit 0
}

# 4. Ordnerstruktur analysieren
Write-Host "`n--- ANALYSE PERSÖNLICHE ORDNERSTRUKTUR ---" -ForegroundColor Cyan
$folderGroups = @{}
$itemsWithoutFolder = 0
$itemsWithFolder = 0

foreach ($item in $personalItems) {
    $folderKey = "🚫 Ohne-Ordner"
    $hasFolder = $false
    
    # Prüfe Folder-ID
    if ($item.folderId -and $folderLookup.ContainsKey($item.folderId)) {
        $folderKey = "📁 " + $folderLookup[$item.folderId]
        $hasFolder = $true
        $itemsWithFolder++
    }
    # Fallback: Notes durchsuchen
    elseif ($item.notes -and $item.notes -match '(?i)(folder|ordner):\s*(.+?)(\r?\n|$)') {
        $folderKey = "📝 " + $matches[2].Trim()
        $hasFolder = $true
        $itemsWithFolder++
    }
    # Fallback: Item-Name Prefix
    elseif ($item.name -match '^([^/\\]+)[/\\]') {
        $folderKey = "🔤 " + $matches[1]
        $hasFolder = $true
        $itemsWithFolder++
    }
    else {
        $itemsWithoutFolder++
    }
    
    if (-not $folderGroups.ContainsKey($folderKey)) {
        $folderGroups[$folderKey] = @()
    }
    $folderGroups[$folderKey] += $item
}

# Ergebnisse anzeigen
Write-Host "Items MIT erkennbarer Ordnerstruktur: $itemsWithFolder" -ForegroundColor Green
Write-Host "Items OHNE erkennbare Ordnerstruktur: $itemsWithoutFolder" -ForegroundColor Yellow

Write-Host "`n--- IDENTIFIZIERTE ORDNERGRUPPEN ---" -ForegroundColor Cyan
$folderGroups.Keys | Sort-Object | ForEach-Object {
    $count = $folderGroups[$_].Count
    $percentage = [math]::Round(($count / $personalItems.Count) * 100, 1)
    Write-Host "  $_ : $count Items ($percentage%)" -ForegroundColor White
}

# Detail-Analyse für größte Gruppen
Write-Host "`n--- DETAIL-ANALYSE (Top 5 Gruppen) ---" -ForegroundColor Cyan
$topGroups = $folderGroups.GetEnumerator() | Sort-Object {$_.Value.Count} -Descending | Select-Object -First 5

foreach ($group in $topGroups) {
    Write-Host "`n  📊 $($group.Key) ($($group.Value.Count) Items):" -ForegroundColor Yellow
    $group.Value | Select-Object -First 3 | ForEach-Object {
        $truncatedName = if ($_.name.Length -gt 50) { $_.name.Substring(0,47) + "..." } else { $_.name }
        Write-Host "    • $truncatedName" -ForegroundColor Gray
    }
    if ($group.Value.Count -gt 3) {
        Write-Host "    ... und $($group.Value.Count - 3) weitere" -ForegroundColor DarkGray
    }
}

# Export für Migration Script
$exportData = @{
    AnalysisType = "PersonalVault"
    OrganizationId = $OrganizationId
    TotalPersonalItems = $personalItems.Count
    ItemsWithFolder = $itemsWithFolder
    ItemsWithoutFolder = $itemsWithoutFolder
    FolderGroups = @{}
    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    AvailableFolders = $folderLookup.Values | Sort-Object
}

foreach ($group in $folderGroups.GetEnumerator()) {
    $cleanKey = $group.Key -replace "^[📁📝🔤🚫]\s*", ""  # Remove emojis
    $exportData.FolderGroups[$cleanKey] = @{
        Count = $group.Value.Count
        Items = $group.Value | ForEach-Object { 
            @{
                Id = $_.id
                Name = $_.name
                Type = $_.type
                FolderId = $_.folderId
            }
        }
    }
}

$exportPath = Join-Path $PSScriptRoot "personal-vault-analysis-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $exportPath -Encoding UTF8
Write-Host "`n💾 Analyse exportiert nach: $exportPath" -ForegroundColor Cyan

# Empfehlung
Write-Host "`n=== EMPFEHLUNG ===" -ForegroundColor Magenta
if ($itemsWithFolder -gt ($personalItems.Count * 0.7)) {
    Write-Host "✅ Struktur ist gut erkennbar - automatische Migration möglich" -ForegroundColor Green
    Write-Host "   Führe .\Vaultwarden-PersonalToOrgMigration.ps1 aus" -ForegroundColor Green
} else {
    Write-Host "⚠️  Struktur teilweise unklar - teilweise manuelle Nachbearbeitung nötig" -ForegroundColor Yellow
    Write-Host "   $itemsWithoutFolder Items brauchen manuelle Zuordnung" -ForegroundColor Yellow
}

Write-Host "`n=== NÄCHSTE SCHRITTE ===" -ForegroundColor Magenta
Write-Host "1. Prüfe die identifizierten Ordnergruppen oben" -ForegroundColor White
Write-Host "2. Bei Zufriedenheit: .\Vaultwarden-PersonalToOrgMigration.ps1 ausführen" -ForegroundColor White
Write-Host "3. Backup vorher erstellen: bw export --format json > personal-backup-$(Get-Date -Format 'yyyyMMdd').json" -ForegroundColor White
