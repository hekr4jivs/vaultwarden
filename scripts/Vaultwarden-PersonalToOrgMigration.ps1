# Vaultwarden-PersonalToOrgMigration.ps1
# Migriert Items vom persönlichen Vault zu einer Organisation
# Erstellt Collections basierend auf der Ordnerstruktur
# Verwendet 'bw share' zum Verschieben (nicht 'bw edit item', das kann keine Org-Zuweisung)

param(
    [string]$OrganizationId = "89f44255-10ff-455f-96e1-f4a4470f16e4",
    [switch]$DryRun = $false,
    [switch]$SkipConfirmation = $false,
    [string]$AnalysisFile = "",
    [string]$DefaultCollection = "Imported-Items",
    [string]$Session = ""
)

Write-Host "=== VAULTWARDEN PERSONAL → ORGANISATION MIGRATION ===" -ForegroundColor Magenta
Write-Host "Ziel-Organisation: $OrganizationId" -ForegroundColor Yellow

if ($DryRun) {
    Write-Host "🔍 DRY-RUN MODUS - Keine Änderungen werden vorgenommen!" -ForegroundColor Cyan
}

# Backup Warnung
if (-not $SkipConfirmation -and -not $DryRun) {
    Write-Host "`n⚠️  WICHTIG: Dieses Script migriert Items vom persönlichen Vault zur Organisation!" -ForegroundColor Red
    Write-Host "   Erstelle vorher ein Backup mit:" -ForegroundColor Yellow
    Write-Host "   bw export --format json > personal-backup-$(Get-Date -Format 'yyyyMMdd').json`n" -ForegroundColor Yellow
    
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
        Write-Host "FEHLER: Bitwarden CLI nicht verfügbar." -ForegroundColor Red
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

# 1. Persönliche Items laden (nur nicht-Organisation Items)
Write-Host "`n--- LADE PERSÖNLICHE VAULT DATEN ---" -ForegroundColor Cyan
$personalItems = bw list items --session $session | ConvertFrom-Json | Where-Object { -not $_.organizationId }
Write-Host "Gefunden: $($personalItems.Count) Items im persönlichen Vault" -ForegroundColor Green

if ($personalItems.Count -eq 0) {
    Write-Host "❌ Keine persönlichen Items zum Migrieren gefunden." -ForegroundColor Red
    exit 0
}

# 2. Ordner-Mapping laden
$allFolders = bw list folders --session $session | ConvertFrom-Json
$folderLookup = @{}
foreach ($folder in $allFolders) {
    if ($folder.id) {
        $folderLookup[$folder.id] = $folder.name
    }
}
Write-Host "Verfügbare Ordner: $($folderLookup.Count)" -ForegroundColor Green

# 3. Bestehende Organisation Collections laden
$existingCollections = bw list collections --organizationid $OrganizationId --session $session | ConvertFrom-Json
$collectionLookup = @{}
foreach ($coll in $existingCollections) {
    $collectionLookup[$coll.name] = $coll.id
}
Write-Host "Bestehende Collections in Organisation: $($existingCollections.Count)" -ForegroundColor Green

# 4. Items nach Ordnerstruktur gruppieren
Write-Host "`n--- GRUPPIERE ITEMS NACH ORDNERSTRUKTUR ---" -ForegroundColor Cyan
$folderGroups = @{}
$processedItems = 0

foreach ($item in $personalItems) {
    $folderKey = $DefaultCollection  # Fallback
    
    # Ordner-Erkennung
    if ($item.folderId -and $folderLookup.ContainsKey($item.folderId)) {
        $folderKey = $folderLookup[$item.folderId]
    }
    elseif ($item.notes -and $item.notes -match '(?i)(folder|ordner):\s*(.+?)(\r?\n|$)') {
        $folderKey = $matches[2].Trim()
    }
    elseif ($item.name -match '^([^/\\]+)[/\\]') {
        $folderKey = $matches[1]
    }
    
    # Ungültige Collection-Namen bereinigen
    $folderKey = $folderKey -replace '[<>:"/\\|?*]', '-'  # Ungültige Zeichen
    $folderKey = $folderKey.Trim()
    
    if (-not $folderGroups.ContainsKey($folderKey)) {
        $folderGroups[$folderKey] = @()
    }
    $folderGroups[$folderKey] += $item
    $processedItems++
}

Write-Host "Verarbeitete Items: $processedItems" -ForegroundColor Green
Write-Host "Identifizierte Ziel-Collections: $($folderGroups.Keys.Count)" -ForegroundColor Green

# 5. Migrations-Plan anzeigen
Write-Host "`n--- MIGRATIONS-PLAN ---" -ForegroundColor Cyan
$newCollections = @()
$migrations = @()

foreach ($folderName in $folderGroups.Keys | Sort-Object) {
    $itemCount = $folderGroups[$folderName].Count
    
    if ($collectionLookup.ContainsKey($folderName)) {
        Write-Host "  ♻️  Verwende bestehende Collection: $folderName ($itemCount Items)" -ForegroundColor Yellow
    } else {
        Write-Host "  ➕ Erstelle neue Collection: $folderName ($itemCount Items)" -ForegroundColor Green
        $newCollections += $folderName
    }
    
    $migrations += @{
        CollectionName = $folderName
        Items = $folderGroups[$folderName]
        IsNew = -not $collectionLookup.ContainsKey($folderName)
    }
}

if ($DryRun) {
    Write-Host "`n🔍 DRY-RUN: Würde folgende Aktionen ausführen:" -ForegroundColor Cyan
    Write-Host "  - $($newCollections.Count) neue Collections erstellen" -ForegroundColor White
    Write-Host "  - $($migrations | ForEach-Object { $_.Items.Count } | Measure-Object -Sum).Sum Items zur Organisation verschieben" -ForegroundColor White
    
    Write-Host "`n📋 Geplante Collections:" -ForegroundColor Cyan
    foreach ($migration in $migrations) {
        $status = if ($migration.IsNew) { "NEU" } else { "BESTEHEND" }
        Write-Host "  - $($migration.CollectionName) ($($migration.Items.Count) Items) [$status]" -ForegroundColor White
    }
    
    Write-Host "`nFühre ohne -DryRun aus zum Anwenden der Änderungen." -ForegroundColor Yellow
    exit 0
}

# 6. Migration ausführen
Write-Host "`n--- STARTE MIGRATION ---" -ForegroundColor Green
$successful = 0
$failed = 0
$createdCollections = @()

foreach ($migration in $migrations) {
    $collectionName = $migration.CollectionName
    $items = $migration.Items
    $collectionId = $null
    
    Write-Host "`n📂 Verarbeite: $collectionName ($($items.Count) Items)" -ForegroundColor Yellow
    
    # Collection erstellen oder ID ermitteln
    if ($migration.IsNew) {
        try {
            Write-Host "  ➕ Erstelle Collection: $collectionName..." -ForegroundColor Green
            
            # Base64-encoded JSON für bw create org-collection
            $jsonString = @"
{
  "organizationId": "$OrganizationId",
  "name": "$collectionName"
}
"@
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonString)
            $encodedJson = [System.Convert]::ToBase64String($bytes)

            $newCollection = bw create org-collection $encodedJson --organizationid $OrganizationId --session $session | ConvertFrom-Json
            
            if ($newCollection.id) {
                $collectionId = $newCollection.id
                $createdCollections += $collectionName
                Write-Host "    ✅ Collection erstellt: $($newCollection.id)" -ForegroundColor Green
            } else {
                Write-Host "    ❌ Collection-Erstellung fehlgeschlagen" -ForegroundColor Red
                $failed += $items.Count
                continue
            }
        } catch {
            Write-Host "    ❌ Fehler beim Erstellen der Collection: $_" -ForegroundColor Red
            $failed += $items.Count
            continue
        }
    } else {
        $collectionId = $collectionLookup[$collectionName]
        Write-Host "  ♻️  Verwende bestehende Collection: $collectionId" -ForegroundColor Yellow
    }
    
    # Items zur Organisation/Collection verschieben
    Write-Host "  🔄 Migriere Items zur Organisation..." -ForegroundColor Cyan
    $itemSuccess = 0
    $itemFailed = 0
    
    foreach ($item in $items) {
        try {
            # Item zur Organisation verschieben mit bw share
            # bw share <itemId> <organizationId> <encodedCollectionIds>
            $collectionIdsJson = ConvertTo-Json @($collectionId) -Compress
            $collectionIdsBytes = [System.Text.Encoding]::UTF8.GetBytes($collectionIdsJson)
            $encodedCollectionIds = [System.Convert]::ToBase64String($collectionIdsBytes)

            $result = bw share $item.id $OrganizationId $encodedCollectionIds --session $session 2>&1

            # bw share gibt das Item als JSON zurück bei Erfolg
            $resultObj = $null
            try { $resultObj = $result | ConvertFrom-Json } catch {}

            if ($resultObj -and $resultObj.id) {
                $itemSuccess++
                Write-Host "    ✓ $($item.name)" -ForegroundColor Gray
            } else {
                # Prüfe ob Item bereits in Organisation ist
                if ($result -match "already belongs to an organization|already shared") {
                    Write-Host "    ⏩ Bereits in Organisation: $($item.name)" -ForegroundColor DarkGray
                    $itemSuccess++
                } else {
                    Write-Host "    ❌ Fehlgeschlagen: $($item.name) - $result" -ForegroundColor Red
                    $itemFailed++
                }
            }
        } catch {
            Write-Host "    ❌ Fehler bei $($item.name): $_" -ForegroundColor Red
            $itemFailed++
        }

        # Kurze Pause um API nicht zu überlasten
        Start-Sleep -Milliseconds 200
    }
    
    Write-Host "  📊 Collection-Ergebnis: $itemSuccess erfolgreich, $itemFailed fehlgeschlagen" -ForegroundColor White
    $successful += $itemSuccess
    $failed += $itemFailed
}

# 7. Zusammenfassung
Write-Host "`n=== MIGRATIONS-ERGEBNIS ===" -ForegroundColor Magenta
Write-Host "✅ Erfolgreich migriert: $successful Items" -ForegroundColor Green
Write-Host "❌ Fehlgeschlagen: $failed Items" -ForegroundColor Red
Write-Host "➕ Neue Collections erstellt: $($createdCollections.Count)" -ForegroundColor Cyan

if ($createdCollections.Count -gt 0) {
    Write-Host "`n🆕 Erstellte Collections:" -ForegroundColor Cyan
    $createdCollections | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }
}

if ($failed -gt 0) {
    Write-Host "`n⚠️  Es gab Fehler. Prüfe die Ausgabe oben." -ForegroundColor Yellow
    Write-Host "   Führe ggf. eine manuelle Nachbearbeitung durch." -ForegroundColor Yellow
}

# Abschluss-Verifikation
Write-Host "`n--- VERIFIKATION ---" -ForegroundColor Cyan
$remainingPersonal = (bw list items --session $session | ConvertFrom-Json | Where-Object { -not $_.organizationId }).Count
$orgItemsNow = (bw list items --organizationid $OrganizationId --session $session | ConvertFrom-Json).Count

Write-Host "Verbleibende persönliche Items: $remainingPersonal" -ForegroundColor $(if ($remainingPersonal -eq 0) { "Green" } else { "Yellow" })
Write-Host "Items in Organisation jetzt: $orgItemsNow" -ForegroundColor Green

Write-Host "`n🎉 Migration abgeschlossen!" -ForegroundColor Green

if ($remainingPersonal -gt 0) {
    Write-Host "ℹ️  Hinweis: $remainingPersonal Items verblieben im persönlichen Vault" -ForegroundColor Yellow
    Write-Host "   (möglicherweise spezielle Item-Typen oder Fehler)" -ForegroundColor Yellow
}
