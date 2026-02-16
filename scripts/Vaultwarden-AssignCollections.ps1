# Vaultwarden-AssignCollections.ps1
# Weist alle Collections einer Organisation einem bestimmten User zu

param(
    [string]$OrganizationId = "89f44255-10ff-455f-96e1-f4a4470f16e4",
    [string]$UserEmail = "",
    [switch]$DryRun = $false,
    [switch]$ReadOnly = $false,
    [switch]$HidePasswords = $false
)

Write-Host "=== VAULTWARDEN COLLECTION-ZUWEISUNG ===" -ForegroundColor Magenta
Write-Host "Organisation: $OrganizationId" -ForegroundColor Yellow

if ($DryRun) {
    Write-Host "DRY-RUN MODUS - Keine Aenderungen!" -ForegroundColor Cyan
}

# Session
try {
    $session = bw unlock --raw
    if (-not $session) {
        Write-Host "FEHLER: Bitwarden nicht entsperrt." -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "FEHLER: Bitwarden CLI nicht verfuegbar." -ForegroundColor Red
    exit 1
}

Write-Host "Bitwarden Session aktiv" -ForegroundColor Green

# Sync
Write-Host "Synchronisiere Vault..." -ForegroundColor Cyan
bw sync --session $session | Out-Null

# Org-Mitglieder laden
Write-Host "`n--- ORGANISATIONS-MITGLIEDER ---" -ForegroundColor Cyan
$members = bw list org-members --organizationid $OrganizationId --session $session | ConvertFrom-Json

if ($members.Count -eq 0) {
    Write-Host "FEHLER: Keine Mitglieder in der Organisation gefunden." -ForegroundColor Red
    exit 1
}

# User auswaehlen
if (-not $UserEmail) {
    Write-Host "Verfuegbare Mitglieder:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $members.Count; $i++) {
        $m = $members[$i]
        $role = switch ($m.type) { 0 { "Owner" } 1 { "Admin" } 2 { "User" } 3 { "Manager" } default { "Unknown" } }
        $status = switch ($m.status) { 0 { "Invited" } 1 { "Accepted" } 2 { "Confirmed" } default { "Unknown" } }
        Write-Host "  [$i] $($m.email) ($role, $status) - ID: $($m.id)" -ForegroundColor White
    }

    $selection = Read-Host "`nWaehle User (Nummer)"
    $selectedIndex = [int]$selection

    if ($selectedIndex -lt 0 -or $selectedIndex -ge $members.Count) {
        Write-Host "FEHLER: Ungueltige Auswahl." -ForegroundColor Red
        exit 1
    }

    $targetMember = $members[$selectedIndex]
} else {
    $targetMember = $members | Where-Object { $_.email -eq $UserEmail }
    if (-not $targetMember) {
        Write-Host "FEHLER: User '$UserEmail' nicht in Organisation gefunden." -ForegroundColor Red
        Write-Host "Verfuegbare Mitglieder:" -ForegroundColor Yellow
        $members | ForEach-Object { Write-Host "  - $($_.email)" -ForegroundColor White }
        exit 1
    }
}

Write-Host "`nZiel-User: $($targetMember.email) (Member-ID: $($targetMember.id))" -ForegroundColor Green

# Collections laden
Write-Host "`n--- COLLECTIONS ---" -ForegroundColor Cyan
$collections = bw list org-collections --organizationid $OrganizationId --session $session | ConvertFrom-Json

if ($collections.Count -eq 0) {
    Write-Host "FEHLER: Keine Collections in der Organisation gefunden." -ForegroundColor Red
    exit 1
}

Write-Host "Gefunden: $($collections.Count) Collections" -ForegroundColor Green

# Zuweisungs-Plan
Write-Host "`n--- ZUWEISUNGS-PLAN ---" -ForegroundColor Cyan
$accessMode = if ($ReadOnly) { "Nur-Lesen" } else { "Lesen/Schreiben" }
Write-Host "Zugriffsmodus: $accessMode" -ForegroundColor Yellow
Write-Host "Collections zuzuweisen: $($collections.Count)" -ForegroundColor Yellow

foreach ($coll in $collections) {
    Write-Host "  - $($coll.name)" -ForegroundColor White
}

if ($DryRun) {
    Write-Host "`nDRY-RUN: Wuerde $($collections.Count) Collections an $($targetMember.email) zuweisen." -ForegroundColor Cyan
    exit 0
}

# Zuweisung ausfuehren
Write-Host "`n--- STARTE ZUWEISUNG ---" -ForegroundColor Green
$successful = 0
$failed = 0
$alreadyAssigned = 0

foreach ($coll in $collections) {
    try {
        # Collection-Details mit aktuellen User-Zuweisungen laden
        $collDetail = bw get org-collection $coll.id --organizationid $OrganizationId --session $session | ConvertFrom-Json

        # Pruefen ob User bereits zugewiesen
        $existingUser = $collDetail.users | Where-Object { $_.id -eq $targetMember.id }
        if ($existingUser) {
            Write-Host "  ~ Bereits zugewiesen: $($coll.name)" -ForegroundColor DarkGray
            $alreadyAssigned++
            continue
        }

        # User zur Collection hinzufuegen
        $newUserEntry = @{
            id            = $targetMember.id
            readOnly      = [bool]$ReadOnly
            hidePasswords = [bool]$HidePasswords
            manage        = $false
        }

        # Bestehende Users beibehalten und neuen hinzufuegen
        $usersList = @()
        if ($collDetail.users) {
            foreach ($u in $collDetail.users) {
                $usersList += @{
                    id            = $u.id
                    readOnly      = $u.readOnly
                    hidePasswords = $u.hidePasswords
                    manage        = $u.manage
                }
            }
        }
        $usersList += $newUserEntry

        # Collection-Update JSON erstellen
        $updateObj = @{
            organizationId = $OrganizationId
            name           = $coll.name
            groups         = @()
            users          = $usersList
        }

        $updateJson = $updateObj | ConvertTo-Json -Depth 10 -Compress
        $updateBytes = [System.Text.Encoding]::UTF8.GetBytes($updateJson)
        $encodedUpdate = [System.Convert]::ToBase64String($updateBytes)

        $result = bw edit org-collection $coll.id $encodedUpdate --organizationid $OrganizationId --session $session | ConvertFrom-Json

        if ($result.id) {
            $successful++
            Write-Host "  + Zugewiesen: $($coll.name)" -ForegroundColor Green
        } else {
            $failed++
            Write-Host "  x Fehlgeschlagen: $($coll.name)" -ForegroundColor Red
        }
    } catch {
        $failed++
        Write-Host "  x Fehler bei $($coll.name): $_" -ForegroundColor Red
    }
}

# Zusammenfassung
Write-Host "`n=== ERGEBNIS ===" -ForegroundColor Magenta
Write-Host "Erfolgreich zugewiesen: $successful" -ForegroundColor Green
Write-Host "Bereits zugewiesen: $alreadyAssigned" -ForegroundColor DarkGray
Write-Host "Fehlgeschlagen: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "`nUser $($targetMember.email) hat jetzt Zugriff auf $($successful + $alreadyAssigned) Collections." -ForegroundColor Green
