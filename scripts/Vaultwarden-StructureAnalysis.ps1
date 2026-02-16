# Vaultwarden-StructureAnalysis.ps1
# Analysiert die bestehende Ordnerstruktur in einer Vaultwarden Organisation
# ohne Änderungen vorzunehmen (KORRIGIERTE VERSION - null-ID Fehler behoben)

param(
    [string]$OrganizationId = "89f44255-10ff-455f-96e1-f4a4470f16e4"
)

Write-Host "=== VAULTWARDEN STRUKTUR ANALYSE ===" -ForegroundColor Magenta
Write-Host "Organisation: $OrganizationId`n" -ForegroundColor Yellow

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

Write-Host "✓ Bitwarden Session aktiv" -ForegroundColor Green

# 1. Organisation Items laden
Write-Host "`n--- LADE ORGANISATION DATEN ---" -ForegroundColor Cyan
try {
    $orgItems = bw list items --organizationid $OrganizationId --session $session | ConvertFrom-Json
} catch {
    Write-Host "FEHLER: Kann Organisation Items nicht laden. Prüfe Organisation-ID." -ForegroundColor Red
    exit 1
}
Write-Host "Gefunden: $($orgItems.Count) Items in Organisation" -ForegroundColor Green

# 2. Persönliche Ordner laden (für Name-Lookup) - MIT NULL-ID SCHUTZ
$allFolders = bw list folders --session $session | ConvertFrom-Json
$folderLookup = @{}
foreach ($folder in $allFolders) {
    if ($folder.id) {  # NUR Ordner mit gültiger ID hinzufügen
        $folderLookup[$folder.id] = $folder.name
    }
}
Write-Host "Verfügbare persönliche Ordner: $($allFolders.Count) (davon $($folderLookup.Count) mit gültiger ID)" -ForegroundColor Green

# 3. Bestehende Collections
$existingCollections = bw list collections --organizationid $OrganizationId --session $session | ConvertFrom-Json
Write-Host "Bestehende Collections: $($existingCollections.Count)" -ForegroundColor Green

Write-Host "`n--- AKTUELLE COLLECTIONS ---" -ForegroundColor Cyan
foreach ($coll in $existingCollections) {
    $itemsInCollection = ($orgItems | Where-Object { $_.collectionIds -contains $coll.id }).Count
    Write-Host "  $($coll.name): $itemsInCollection Items" -ForegroundColor White
}

# 4. Struktur-Analyse
Write-Host "`n--- ERKENNBARE ORDNERSTRUKTUR ---" -ForegroundColor Cyan
$folderGroups = @{}
$itemsWithoutFolder = 0
$itemsWithFolder = 0

foreach ($item in $orgItems) {
    $folderKey = "🚫 Ohne-Ordner"
    $hasFolder = $false
    
    # Prüfe verschiedene Quellen für Ordner-Information - MIT NULL-CHECK
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
    $percentage = [math]::Round(($count / $orgItems.Count) * 100, 1)
    Write-Host "  $_ : $count Items ($percentage%)" -ForegroundColor White
}

# 5. Detail-Analyse für größte Gruppen
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

# 6. Export für Migration Script
$exportData = @{
    AnalysisType = "OrganizationItems"
    OrganizationId = $OrganizationId
    TotalItems = $orgItems.Count
    ItemsWithFolder = $itemsWithFolder
    ItemsWithoutFolder = $itemsWithoutFolder
    FolderGroups = @{}
    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}

foreach ($group in $folderGroups.GetEnumerator()) {
    $cleanKey = $group.Key -replace "^[📁📝🔤🚫]\s*", ""  # Remove emojis for export
    $exportData.FolderGroups[$cleanKey] = @{
        Count = $group.Value.Count
        Items = $group.Value | ForEach-Object { 
            @{
                Id = $_.id
                Name = $_.name
                Type = $_.type
            }
        }
    }
}

$exportPath = Join-Path $PSScriptRoot "vaultwarden-analysis-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $exportPath -Encoding UTF8
Write-Host "`n💾 Analyse exportiert nach: $exportPath" -ForegroundColor Cyan

Write-Host "`n=== EMPFEHLUNG ===" -ForegroundColor Magenta
if ($orgItems.Count -eq 0) {
    Write-Host "❌ Keine Items in Organisation gefunden!" -ForegroundColor Red
    Write-Host "   Möglicherweise sind Items noch im persönlichen Vault." -ForegroundColor Yellow
    Write-Host "   Verwende: .\Vaultwarden-PersonalVaultAnalysis.ps1" -ForegroundColor Cyan
} elseif ($itemsWithFolder -gt ($orgItems.Count * 0.7)) {
    Write-Host "✅ Struktur ist gut erkennbar - automatische Migration möglich" -ForegroundColor Green
    Write-Host "   Führe .\Vaultwarden-CollectionMigration.ps1 aus für $($folderGroups.Keys.Count - 1) Collections" -ForegroundColor Green
} else {
    Write-Host "⚠️  Struktur teilweise unklar - manuelle Nachbearbeitung nötig" -ForegroundColor Yellow
    Write-Host "   $itemsWithoutFolder Items müssen manuell zugeordnet werden" -ForegroundColor Yellow
}

Write-Host "`n=== NÄCHSTE SCHRITTE ===" -ForegroundColor Magenta
Write-Host "1. Prüfe die identifizierten Ordnergruppen oben" -ForegroundColor White
Write-Host "2. Bei Zufriedenheit: .\Vaultwarden-CollectionMigration.ps1 ausführen" -ForegroundColor White
Write-Host "3. Backup vorher erstellen: bw export --organizationid $OrganizationId" -ForegroundColor White
