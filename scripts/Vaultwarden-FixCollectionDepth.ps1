# Vaultwarden-FixCollectionDepth.ps1
# Reassigns items from shallow/parent collections to their correct deeper collections
# based on path information encoded in item names.
#
# Example: Item "Terraform / jivs-easy / CH / Kunden / helvetia / sql read user"
#   currently in collection "AZURE ADN/Terraform"
#   should also be in "AZURE ADN/Terraform/jivs-easy/CH/Kunden/helvetia"
#
# Uses 'bw edit item-collections' for collection assignments.

param(
    [string]$OrganizationId = "89f44255-10ff-455f-96e1-f4a4470f16e4",
    [switch]$DryRun = $false,
    [switch]$SkipConfirmation = $false,
    [switch]$RemoveFromDefault = $false,
    [switch]$RemoveFromShallow = $false,
    [string]$DefaultCollectionName = "DevOp-Standardsammlung",
    [string]$Session = ""
)

Write-Host "=== VAULTWARDEN FIX COLLECTION DEPTH ===" -ForegroundColor Magenta
Write-Host "Organisation: $OrganizationId" -ForegroundColor Yellow

if ($DryRun) {
    Write-Host "DRY-RUN MODUS - Keine Aenderungen werden vorgenommen!" -ForegroundColor Cyan
}
if ($RemoveFromDefault) {
    Write-Host "RemoveFromDefault: Items werden aus '$DefaultCollectionName' entfernt" -ForegroundColor Yellow
}
if ($RemoveFromShallow) {
    Write-Host "RemoveFromShallow: Items werden aus flachen Parent-Collections entfernt" -ForegroundColor Yellow
}

# Confirmation
if (-not $SkipConfirmation -and -not $DryRun) {
    Write-Host "`nDieses Script veraendert Collection-Zuweisungen!" -ForegroundColor Red
    Write-Host "   Empfehlung: Zuerst mit -DryRun ausfuehren!" -ForegroundColor Yellow

    $confirm = Read-Host "Fortfahren? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Abgebrochen." -ForegroundColor Yellow
        exit 0
    }
}

# --- SESSION ---
if ($Session) {
    $session = $Session
} else {
    try {
        $session = bw unlock --raw
        if (-not $session) {
            Write-Host "FEHLER: Bitwarden nicht entsperrt. Nutze 'bw unlock' oder -Session <token>." -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host "FEHLER: Bitwarden CLI nicht verfuegbar oder nicht eingeloggt." -ForegroundColor Red
        exit 1
    }
}
Write-Host "Bitwarden Session aktiv" -ForegroundColor Green

# --- SYNC ---
Write-Host "Synchronisiere Vault..." -ForegroundColor Cyan
bw sync --session $session | Out-Null
Write-Host "Sync abgeschlossen" -ForegroundColor Green

# --- ORG ACCESS ---
$orgStatus = bw list organizations --session $session | ConvertFrom-Json | Where-Object { $_.id -eq $OrganizationId }
if (-not $orgStatus) {
    Write-Host "FEHLER: Kein Zugriff auf Organisation $OrganizationId." -ForegroundColor Red
    exit 1
}
Write-Host "Organisations-Zugriff bestaetigt: $($orgStatus.name)" -ForegroundColor Green

# --- LOAD DATA ---
Write-Host "`n--- LADE DATEN ---" -ForegroundColor Cyan

$orgItems = bw list items --organizationid $OrganizationId --session $session | ConvertFrom-Json
Write-Host "Items in Organisation: $($orgItems.Count)" -ForegroundColor Green

$allFolders = bw list folders --session $session | ConvertFrom-Json
$folderLookup = @{}
foreach ($folder in $allFolders) {
    if ($folder.id) {
        $folderLookup[$folder.id] = $folder.name
    }
}

$existingCollections = bw list collections --organizationid $OrganizationId --session $session | ConvertFrom-Json
Write-Host "Collections in Organisation: $($existingCollections.Count)" -ForegroundColor Green

# Build collection lookups (name -> id, id -> name)
# Use case-insensitive lookup for matching
$collectionNameToId = @{}
$collectionIdToName = @{}
foreach ($coll in $existingCollections) {
    $collectionNameToId[$coll.name.ToLower()] = $coll.id
    $collectionIdToName[$coll.id] = $coll.name
}

# Find the default collection ID
$defaultCollectionId = $null
if ($collectionNameToId.ContainsKey($DefaultCollectionName.ToLower())) {
    $defaultCollectionId = $collectionNameToId[$DefaultCollectionName.ToLower()]
    Write-Host "Default Collection: $DefaultCollectionName ($defaultCollectionId)" -ForegroundColor Gray
}

# --- BACKUP ---
$backupPath = Join-Path $PSScriptRoot "depth-fix-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$backupData = @()
foreach ($item in $orgItems) {
    $backupData += @{
        Id = $item.id
        Name = $item.name
        CollectionIds = $item.collectionIds
    }
}
$backupData | ConvertTo-Json -Depth 5 | Out-File -FilePath $backupPath -Encoding UTF8
Write-Host "Backup gespeichert: $backupPath" -ForegroundColor Green

# --- HELPER: Count segments in a collection path ---
function Get-PathDepth {
    param([string]$CollectionName)
    return ($CollectionName -split '/').Count
}

# --- ANALYZE ---
Write-Host "`n--- ANALYSIERE ITEMS ---" -ForegroundColor Cyan

$reassignments = @()
$skippedNoPath = 0
$skippedNoOverlap = 0
$skippedAlreadyCorrect = 0
$skippedNoDeeper = 0

foreach ($item in $orgItems) {
    # Split item name by " / " to extract path segments
    $nameSegments = $item.name -split '\s*/\s*'

    # Need at least 2 segments (path + actual name) to have path structure
    if ($nameSegments.Count -lt 2) {
        $skippedNoPath++
        continue
    }

    # Path segments = all except last (last = actual item name)
    $pathSegments = $nameSegments[0..($nameSegments.Count - 2)]

    # Get item's current collections (excluding default)
    $currentCollIds = @()
    if ($item.collectionIds) {
        $currentCollIds = @($item.collectionIds | Where-Object { $_ -and $_ -ne $defaultCollectionId })
    }

    # If item has no non-default collections, try to match purely by name path
    if ($currentCollIds.Count -eq 0) {
        # Try building a collection path from the name segments alone
        # Look for the longest existing collection that matches a prefix of the path segments
        $bestMatch = $null
        $bestMatchDepth = 0

        for ($depth = $pathSegments.Count; $depth -ge 1; $depth--) {
            $candidatePath = ($pathSegments[0..($depth - 1)]) -join '/'
            if ($collectionNameToId.ContainsKey($candidatePath.ToLower())) {
                $bestMatch = $candidatePath
                $bestMatchDepth = $depth
                break
            }
        }

        if ($bestMatch) {
            $targetCollId = $collectionNameToId[$bestMatch.ToLower()]
            $currentCollNames = @($DefaultCollectionName)
            $reassignments += @{
                Item = $item
                CurrentCollections = $currentCollNames -join ', '
                TargetCollection = $bestMatch
                TargetCollectionId = $targetCollId
                AddCollectionIds = @($targetCollId)
                RemoveCollectionIds = @()
            }
        }
        continue
    }

    # Find the deepest current collection (most "/" segments)
    $deepestCollName = ""
    $deepestCollId = ""
    $deepestDepth = 0
    foreach ($collId in $currentCollIds) {
        if ($collectionIdToName.ContainsKey($collId)) {
            $collName = $collectionIdToName[$collId]
            $depth = Get-PathDepth $collName
            if ($depth -gt $deepestDepth) {
                $deepestDepth = $depth
                $deepestCollName = $collName
                $deepestCollId = $collId
            }
        }
    }

    if (-not $deepestCollName) {
        $skippedNoOverlap++
        continue
    }

    # Split the deepest collection path into segments
    # NOTE: Wrap in @() to prevent PowerShell from unwrapping single-element arrays to scalars
    $collSegments = $deepestCollName -split '/'
    $collSegmentsTrimmed = @($collSegments | ForEach-Object { $_.Trim().ToLower() })
    $pathSegmentsTrimmed = @($pathSegments | ForEach-Object { $_.Trim().ToLower() })

    # Find alignment: where does the item's name path start within the collection path?
    # e.g. Collection "AZURE ADN/DM-Innovation/DigitalLounge", Name path ["DM-Innovation", "DigitalLounge"]
    #   -> "DM-Innovation" found at collSegments[1], "DigitalLounge" matches collSegments[2] -> fully aligned
    # e.g. Collection "AZURE ADN/Terraform", Name path ["Terraform", "jivs-easy", "CH", ...]
    #   -> "Terraform" found at collSegments[1], but name path continues beyond collection -> needs deeper

    $alignStart = -1
    for ($s = 0; $s -lt $collSegmentsTrimmed.Count; $s++) {
        if ($collSegmentsTrimmed[$s] -eq $pathSegmentsTrimmed[0]) {
            # Check if subsequent name segments also match collection segments
            $matches = $true
            $matchLen = [Math]::Min($pathSegmentsTrimmed.Count, $collSegmentsTrimmed.Count - $s)
            for ($m = 1; $m -lt $matchLen; $m++) {
                if ($collSegmentsTrimmed[$s + $m] -ne $pathSegmentsTrimmed[$m]) {
                    $matches = $false
                    break
                }
            }
            if ($matches) {
                $alignStart = $s
                break
            }
        }
    }

    if ($alignStart -lt 0) {
        # No alignment found between name path and collection path
        $skippedNoOverlap++
        continue
    }

    # How many name path segments are already covered by the collection?
    $coveredCount = $collSegmentsTrimmed.Count - $alignStart
    $remainingNameSegments = @()
    if ($coveredCount -lt $pathSegmentsTrimmed.Count) {
        $remainingNameSegments = $pathSegments[$coveredCount..($pathSegments.Count - 1)]
    }

    if ($remainingNameSegments.Count -eq 0) {
        # All name path segments are covered by collection -> already at correct depth
        $skippedAlreadyCorrect++
        continue
    }

    # Build candidate paths: deepestCollection + remaining name segments
    $candidateBase = $deepestCollName

    # Find the deepest EXISTING collection matching candidate path (try from full to shortest)
    $targetCollPath = $null
    $targetCollId = $null

    for ($i = $remainingNameSegments.Count; $i -ge 1; $i--) {
        $tryPath = $candidateBase + '/' + (($remainingNameSegments[0..($i - 1)] | ForEach-Object { $_.Trim() }) -join '/')
        if ($collectionNameToId.ContainsKey($tryPath.ToLower())) {
            $targetCollPath = $tryPath
            $targetCollId = $collectionNameToId[$tryPath.ToLower()]
            break
        }
    }

    if (-not $targetCollPath) {
        # No deeper collection exists
        $skippedNoDeeper++
        continue
    }

    # Check if item is already in the target collection
    if ($item.collectionIds -contains $targetCollId) {
        $skippedAlreadyCorrect++
        continue
    }

    # Determine which collections to remove
    $removeCollIds = @()
    if ($RemoveFromShallow) {
        # Remove from all shallower parent collections (but not the target)
        foreach ($collId in $currentCollIds) {
            if ($collId -ne $targetCollId -and $collectionIdToName.ContainsKey($collId)) {
                $collName = $collectionIdToName[$collId]
                # Check if this collection is a parent/prefix of the target
                if ($targetCollPath.ToLower().StartsWith($collName.ToLower() + '/') -or $targetCollPath.ToLower().StartsWith($collName.ToLower())) {
                    $removeCollIds += $collId
                }
            }
        }
    }
    if ($RemoveFromDefault -and $defaultCollectionId -and ($item.collectionIds -contains $defaultCollectionId)) {
        $removeCollIds += $defaultCollectionId
    }

    $reassignments += @{
        Item = $item
        CurrentCollections = ($currentCollIds | ForEach-Object {
            if ($collectionIdToName.ContainsKey($_)) { $collectionIdToName[$_] } else { $_ }
        }) -join ', '
        TargetCollection = $targetCollPath
        TargetCollectionId = $targetCollId
        AddCollectionIds = @($targetCollId)
        RemoveCollectionIds = @($removeCollIds | Select-Object -Unique)
    }
}

# --- REPORT ---
Write-Host "`n--- ANALYSE-ERGEBNIS ---" -ForegroundColor Cyan
Write-Host "  Items ohne Pfadstruktur im Namen: $skippedNoPath" -ForegroundColor Gray
Write-Host "  Items ohne Overlap (Name/Collection): $skippedNoOverlap" -ForegroundColor Gray
Write-Host "  Items bereits korrekt zugeordnet: $skippedAlreadyCorrect" -ForegroundColor Gray
Write-Host "  Items ohne tiefere Collection verfuegbar: $skippedNoDeeper" -ForegroundColor Gray
Write-Host "  Items zur Neuzuordnung: $($reassignments.Count)" -ForegroundColor $(if ($reassignments.Count -gt 0) { "Green" } else { "Yellow" })

if ($reassignments.Count -eq 0) {
    Write-Host "`nKeine Neuzuordnungen noetig. Alle Items sind korrekt zugeordnet." -ForegroundColor Green
    exit 0
}

# Show planned changes
Write-Host "`n--- GEPLANTE AENDERUNGEN ---" -ForegroundColor Cyan
$groupedByTarget = $reassignments | Group-Object { $_.TargetCollection }
foreach ($group in $groupedByTarget | Sort-Object { $_.Name }) {
    Write-Host "`n  -> $($group.Name) ($($group.Count) Items)" -ForegroundColor Yellow
    foreach ($r in $group.Group | Select-Object -First 5) {
        $truncName = if ($r.Item.name.Length -gt 60) { $r.Item.name.Substring(0, 57) + "..." } else { $r.Item.name }
        Write-Host "     $truncName" -ForegroundColor Gray
        Write-Host "       von: $($r.CurrentCollections)" -ForegroundColor DarkGray
    }
    if ($group.Count -gt 5) {
        Write-Host "     ... und $($group.Count - 5) weitere" -ForegroundColor DarkGray
    }
}

if ($DryRun) {
    Write-Host "`nDRY-RUN abgeschlossen. Fuehre ohne -DryRun aus zum Anwenden." -ForegroundColor Cyan
    exit 0
}

# --- EXECUTE ---
Write-Host "`n--- FUEHRE NEUZUORDNUNGEN DURCH ---" -ForegroundColor Green
$successful = 0
$failed = 0

foreach ($r in $reassignments) {
    $item = $r.Item
    try {
        # Build new collection ID list: existing + additions - removals
        $newCollIds = @()
        if ($item.collectionIds) {
            $newCollIds = @($item.collectionIds | Where-Object { $_ })
        }

        # Add target collection
        foreach ($addId in $r.AddCollectionIds) {
            if ($newCollIds -notcontains $addId) {
                $newCollIds += $addId
            }
        }

        # Remove specified collections
        if ($r.RemoveCollectionIds.Count -gt 0) {
            $newCollIds = @($newCollIds | Where-Object { $r.RemoveCollectionIds -notcontains $_ })
        }

        $collJson = ConvertTo-Json @($newCollIds) -Compress
        $collBytes = [System.Text.Encoding]::UTF8.GetBytes($collJson)
        $encodedColl = [System.Convert]::ToBase64String($collBytes)

        $result = bw edit item-collections $item.id $encodedColl --organizationid $OrganizationId --session $session 2>&1

        $resultObj = $null
        try { $resultObj = $result | ConvertFrom-Json } catch {}

        if ($resultObj) {
            $successful++
            $truncName = if ($item.name.Length -gt 50) { $item.name.Substring(0, 47) + "..." } else { $item.name }
            Write-Host "  -> $truncName => $($r.TargetCollection)" -ForegroundColor Gray
        } else {
            Write-Host "  FEHLER: $($item.name) - $result" -ForegroundColor Red
            $failed++
        }
    } catch {
        Write-Host "  FEHLER bei $($item.name): $_" -ForegroundColor Red
        $failed++
    }
}

# --- VERIFY ---
Write-Host "`n--- VERIFIZIERUNG ---" -ForegroundColor Cyan
bw sync --session $session | Out-Null
$updatedItems = bw list items --organizationid $OrganizationId --session $session | ConvertFrom-Json

# Count items per collection depth
$depthCounts = @{}
foreach ($item in $updatedItems) {
    if ($item.collectionIds) {
        $maxDepth = 0
        foreach ($cid in $item.collectionIds) {
            if ($collectionIdToName.ContainsKey($cid)) {
                $d = Get-PathDepth $collectionIdToName[$cid]
                if ($d -gt $maxDepth) { $maxDepth = $d }
            }
        }
        if (-not $depthCounts.ContainsKey($maxDepth)) { $depthCounts[$maxDepth] = 0 }
        $depthCounts[$maxDepth]++
    }
}

Write-Host "Items nach Collection-Tiefe:" -ForegroundColor White
foreach ($depth in $depthCounts.Keys | Sort-Object) {
    Write-Host "  Tiefe $depth : $($depthCounts[$depth]) Items" -ForegroundColor Gray
}

# --- SUMMARY ---
Write-Host "`n=== ERGEBNIS ===" -ForegroundColor Magenta
Write-Host "Erfolgreich: $successful Items" -ForegroundColor Green
Write-Host "Fehlgeschlagen: $failed Items" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "Backup: $backupPath" -ForegroundColor Gray

if ($failed -gt 0) {
    Write-Host "`nEs gab Fehler. Pruefe die Ausgabe oben." -ForegroundColor Yellow
}

if (-not $RemoveFromShallow -and $successful -gt 0) {
    Write-Host "`nTipp: Mit -RemoveFromShallow erneut ausfuehren um Items aus flachen Parent-Collections zu entfernen." -ForegroundColor Cyan
}
if (-not $RemoveFromDefault -and $successful -gt 0) {
    Write-Host "Tipp: Mit -RemoveFromDefault erneut ausfuehren um Items aus '$DefaultCollectionName' zu entfernen." -ForegroundColor Cyan
}

Write-Host "`nAbgeschlossen!" -ForegroundColor Green
