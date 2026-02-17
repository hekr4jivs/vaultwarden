# Vaultwarden-CollectionMigration.ps1
# Migriert Items basierend auf erkennbarer Ordnerstruktur zu entsprechenden Collections
# ACHTUNG: Dieses Script verändert die Organisation! Backup vorher erstellen!
# KORRIGIERT: Verwendet org-collection statt collection

param(
    [string]$OrganizationId = "89f44255-10ff-455f-96e1-f4a4470f16e4",
    [switch]$DryRun = $false,
    [switch]$SkipConfirmation = $false,
    [string]$AnalysisFile = "",
    [string]$Session = ""
)

Write-Host "=== VAULTWARDEN COLLECTION MIGRATION ===" -ForegroundColor Magenta
Write-Host "Organisation: $OrganizationId" -ForegroundColor Yellow

if ($DryRun) {
    Write-Host "🔍 DRY-RUN MODUS - Keine Änderungen werden vorgenommen!" -ForegroundColor Cyan
}

# Backup Warnung
if (-not $SkipConfirmation -and -not $DryRun) {
    Write-Host "`n⚠️  WICHTIG: Dieses Script verändert deine Organisation!" -ForegroundColor Red
    Write-Host "   Erstelle vorher ein Backup mit:" -ForegroundColor Yellow
    Write-Host "   bw export --organizationid $OrganizationId --format json > backup-$(Get-Date -Format 'yyyyMMdd').json`n" -ForegroundColor Yellow
    
    $confirm = Read-Host "Fortfahren? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Migration abgebrochen." -ForegroundColor Yellow
        exit 0
    }
}

# Session check
if ($Session) {
    $session = $Session
} else {
    try {
        $session = bw unlock --raw
        if (-not $session) {
            Write-Host "FEHLER: Bitwarden nicht entsperrt. Führe 'bw unlock' aus oder nutze -Session <token>." -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host "FEHLER: Bitwarden CLI nicht verfügbar oder nicht eingeloggt." -ForegroundColor Red
        exit 1
    }
}

Write-Host "✅ Bitwarden Session aktiv" -ForegroundColor Green

# Sync durchführen um Organisations-Schlüssel zu laden
Write-Host "🔄 Synchronisiere Vault..." -ForegroundColor Cyan
bw sync --session $session | Out-Null
Write-Host "✅ Sync abgeschlossen" -ForegroundColor Green

# Prüfe Organisations-Zugriff
$orgStatus = bw list organizations --session $session | ConvertFrom-Json | Where-Object { $_.id -eq $OrganizationId }
if (-not $orgStatus) {
    Write-Host "FEHLER: Kein Zugriff auf Organisation $OrganizationId. Bist du Owner oder Admin?" -ForegroundColor Red
    exit 1
}
Write-Host "✅ Organisations-Zugriff bestätigt: $($orgStatus.name)" -ForegroundColor Green

# Analysedaten laden oder neue Analyse durchführen
$analysisData = $null
if ($AnalysisFile -and (Test-Path $AnalysisFile)) {
    Write-Host "📂 Lade Analysedaten aus: $AnalysisFile" -ForegroundColor Cyan
    $analysisData = Get-Content $AnalysisFile | ConvertFrom-Json
}

# 1. Organisation Items laden
Write-Host "`n--- LADE AKTUELLE DATEN ---" -ForegroundColor Cyan
$orgItems = bw list items --organizationid $OrganizationId --session $session | ConvertFrom-Json
Write-Host "Gefunden: $($orgItems.Count) Items in Organisation" -ForegroundColor Green

# 2. Persönliche Ordner laden - MIT NULL-ID SCHUTZ
$allFolders = bw list folders --session $session | ConvertFrom-Json
$folderLookup = @{}
foreach ($folder in $allFolders) {
    if ($folder.id) {  # NUR Ordner mit gültiger ID
        $folderLookup[$folder.id] = $folder.name
    }
}

# 3. Bestehende Collections
$existingCollections = bw list collections --organizationid $OrganizationId --session $session | ConvertFrom-Json
$collectionLookup = @{}
foreach ($coll in $existingCollections) {
    $collectionLookup[$coll.name] = $coll.id
}
Write-Host "Bestehende Collections: $($existingCollections.Count)" -ForegroundColor Green

# 4. Ordnergruppen identifizieren
Write-Host "`n--- IDENTIFIZIERE ORDNERSTRUKTUR ---" -ForegroundColor Cyan
$folderGroups = @{}
$processedItems = 0

foreach ($item in $orgItems) {
    $folderKey = "Ohne-Ordner"
    
    # Verschiedene Erkennungsmethoden - MIT NULL-CHECK
    if ($item.folderId -and $folderLookup.ContainsKey($item.folderId)) {
        $folderKey = $folderLookup[$item.folderId]
    }
    elseif ($item.notes -and $item.notes -match '(?i)(folder|ordner):\s*(.+?)(\r?\n|$)') {
        $folderKey = $matches[2].Trim()
    }
    elseif ($item.name -match '^([^/\\]+)[/\\]') {
        $folderKey = $matches[1]
    }
    
    if (-not $folderGroups.ContainsKey($folderKey)) {
        $folderGroups[$folderKey] = @()
    }
    $folderGroups[$folderKey] += $item
    $processedItems++
}

Write-Host "Verarbeitete Items: $processedItems" -ForegroundColor Green
Write-Host "Identifizierte Ordnergruppen: $($folderGroups.Keys.Count)" -ForegroundColor Green

# 5. Migration Plan anzeigen
Write-Host "`n--- MIGRATIONS-PLAN ---" -ForegroundColor Cyan
$newCollections = @()
$migrations = @()

foreach ($folderName in $folderGroups.Keys | Sort-Object) {
    $itemCount = $folderGroups[$folderName].Count
    
    if ($folderName -eq "Ohne-Ordner") {
        Write-Host "  ⏩ Überspringe: $folderName ($itemCount Items)" -ForegroundColor DarkGray
        continue
    }
    
    if ($collectionLookup.ContainsKey($folderName)) {
        Write-Host "  ♻️  Verwende bestehende Collection: $folderName ($itemCount Items)" -ForegroundColor Yellow
    } else {
        Write-Host "  ➕ Erstelle neue Collection: $folderName ($itemCount Items)" -ForegroundColor Green
        $newCollections += $folderName
    }
    
    $migrations += @{
        FolderName = $folderName
        Items = $folderGroups[$folderName]
        IsNew = -not $collectionLookup.ContainsKey($folderName)
    }
}

if ($DryRun) {
    Write-Host "`n🔍 DRY-RUN: Würde folgende Aktionen ausführen:" -ForegroundColor Cyan
    Write-Host "  - $($newCollections.Count) neue Collections erstellen" -ForegroundColor White
    Write-Host "  - $($migrations | ForEach-Object { $_.Items.Count } | Measure-Object -Sum).Sum Items verschieben" -ForegroundColor White
    Write-Host "`nFühre ohne -DryRun aus zum Anwenden der Änderungen." -ForegroundColor Yellow
    exit 0
}

# 6. Migration ausführen
Write-Host "`n--- STARTE MIGRATION ---" -ForegroundColor Green
$successful = 0
$failed = 0

foreach ($migration in $migrations) {
    $folderName = $migration.FolderName
    $items = $migration.Items
    $collectionId = $null
    
    Write-Host "`n📁 Verarbeite: $folderName ($($items.Count) Items)" -ForegroundColor Yellow
    
    # Collection erstellen oder ID ermitteln
    if ($migration.IsNew) {
        try {
            Write-Host "  ➕ Erstelle Collection..." -ForegroundColor Green
            
            # Base64-encoded JSON für bw create org-collection
            $jsonString = @"
{
  "organizationId": "$OrganizationId",
  "name": "$folderName"
}
"@
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonString)
            $encodedJson = [System.Convert]::ToBase64String($bytes)

            $newCollection = bw create org-collection $encodedJson --organizationid $OrganizationId --session $session | ConvertFrom-Json
            $collectionId = $newCollection.id
            Write-Host "    ✅ Collection erstellt: $($newCollection.id)" -ForegroundColor Green
        } catch {
            Write-Host "    ❌ Fehler beim Erstellen der Collection: $_" -ForegroundColor Red
            $failed++
            continue
        }
    } else {
        $collectionId = $collectionLookup[$folderName]
        Write-Host "  ♻️  Verwende bestehende Collection: $collectionId" -ForegroundColor Yellow
    }
    
    # Items zu Collection verschieben
    Write-Host "  🔄 Verschiebe Items..." -ForegroundColor Cyan
    $itemSuccess = 0
    $itemFailed = 0
    
    foreach ($item in $items) {
        try {
            # Collection-Zuordnung aktualisieren
            $item.collectionIds = @($collectionId)

            # Base64-encoded JSON für bw edit item
            $itemJson = $item | ConvertTo-Json -Depth 10 -Compress
            $itemBytes = [System.Text.Encoding]::UTF8.GetBytes($itemJson)
            $encodedItem = [System.Convert]::ToBase64String($itemBytes)
            $result = bw edit item $item.id $encodedItem --session $session | ConvertFrom-Json
            
            if ($result.id) {
                $itemSuccess++
                Write-Host "    ✓ $($item.name)" -ForegroundColor Gray
            } else {
                Write-Host "    ❌ Fehlgeschlagen: $($item.name)" -ForegroundColor Red
                $itemFailed++
            }
        } catch {
            Write-Host "    ❌ Fehler bei $($item.name): $_" -ForegroundColor Red
            $itemFailed++
        }
    }
    
    Write-Host "  📊 Ordner-Ergebnis: $itemSuccess erfolgreich, $itemFailed fehlgeschlagen" -ForegroundColor White
    $successful += $itemSuccess
    $failed += $itemFailed
}

# 7. Zusammenfassung
Write-Host "`n=== MIGRATIONS-ERGEBNIS ===" -ForegroundColor Magenta
Write-Host "✅ Erfolgreich verschoben: $successful Items" -ForegroundColor Green
Write-Host "❌ Fehlgeschlagen: $failed Items" -ForegroundColor Red
Write-Host "➕ Neue Collections: $($newCollections.Count)" -ForegroundColor Cyan

if ($newCollections.Count -gt 0) {
    Write-Host "`n🆕 Erstellte Collections:" -ForegroundColor Cyan
    $newCollections | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }
}

if ($failed -gt 0) {
    Write-Host "`n⚠️  Es gab Fehler. Prüfe die Ausgabe oben und führe ggf. eine manuelle Nachbearbeitung durch." -ForegroundColor Yellow
}

Write-Host "`n🎉 Migration abgeschlossen!" -ForegroundColor Green
