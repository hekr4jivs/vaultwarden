# Vaultwarden Collection Migration Scripts

Diese Scripts helfen dabei, eine bestehende Ordnerstruktur aus KeePass-Imports in Vaultwarden Collections zu organisieren.

## ✅ CLI-BEFEHL KORRIGIERT!

**Problem behoben:** Scripts verwenden jetzt korrekten Befehl `bw create org-collection` statt `bw create collection`

## Script-Übersicht

### 🎯 FÜR PERSONAL VAULT → ORGANISATION MIGRATION:
- **`Vaultwarden-PersonalVaultAnalysis.ps1`** - Analysiert Items im persönlichen Vault
- **`Vaultwarden-PersonalToOrgMigration.ps1`** - Migriert Items vom Personal Vault zur Organisation ✅ **KORRIGIERT**

### 📋 FÜR ORGANISATION COLLECTION RESTRUKTURIERUNG:
- **`Vaultwarden-StructureAnalysis.ps1`** - Analysiert bestehende Organisation-Items  
- **`Vaultwarden-CollectionMigration.ps1`** - Reorganisiert Items in Collections ✅ **KORRIGIERT**

## Empfohlener Ablauf

### 1. Personal Vault analysieren
```powershell
cd C:\REPOSITORIES\external\vaultwarden\scripts
.\Vaultwarden-PersonalVaultAnalysis.ps1
```

### 2. Migration vorbereiten
```powershell
# Backup erstellen
bw export --format json > personal-backup-$(Get-Date -Format 'yyyyMMdd').json

# Dry-Run der Migration
.\Vaultwarden-PersonalToOrgMigration.ps1 -DryRun
```

### 3. Migration durchführen
```powershell
.\Vaultwarden-PersonalToOrgMigration.ps1
```

## Voraussetzungen

1. **Bitwarden CLI installieren:**
   ```bash
   npm install -g @bitwarden/cli
   ```

2. **Bei Vaultwarden-Instanz anmelden:**
   ```bash
   bw config server https://vault.cloud.jivs.com
   bw login
   bw unlock
   ```

## Korrekturen in dieser Version

### ✅ **CLI-Befehl korrigiert**
- **Alt:** `bw create collection` → **Fehler:** "Unknown object 'collection'"
- **Neu:** `bw create org-collection` → **Funktioniert!**

### ✅ **Null-Folder-ID Fehler behoben**
- Sichere Verarbeitung von Ordnern ohne gültige ID
- Verhindert Array-Index-Fehler bei null-Werten

## Parameter

### Vaultwarden-PersonalVaultAnalysis.ps1
```powershell
# Standard-Ausführung
.\Vaultwarden-PersonalVaultAnalysis.ps1

# Mit spezifischer Organisation
.\Vaultwarden-PersonalVaultAnalysis.ps1 -OrganizationId "andere-id"
```

### Vaultwarden-PersonalToOrgMigration.ps1 ✅ **KORRIGIERT**
```powershell
# Dry-Run (empfohlen)
.\Vaultwarden-PersonalToOrgMigration.ps1 -DryRun

# Echte Migration
.\Vaultwarden-PersonalToOrgMigration.ps1

# Mit alternativer Default-Collection
.\Vaultwarden-PersonalToOrgMigration.ps1 -DefaultCollection "KeePass-Import"

# Ohne Bestätigungsdialog
.\Vaultwarden-PersonalToOrgMigration.ps1 -SkipConfirmation
```

### Vaultwarden-CollectionMigration.ps1 ✅ **KORRIGIERT**
```powershell
# Dry-Run (empfohlen)
.\Vaultwarden-CollectionMigration.ps1 -DryRun

# Echte Migration
.\Vaultwarden-CollectionMigration.ps1

# Mit Analysedatei
.\Vaultwarden-CollectionMigration.ps1 -AnalysisFile "analysis.json"

# Ohne Bestätigung
.\Vaultwarden-CollectionMigration.ps1 -SkipConfirmation
```

## Fehlerbehebung

### ✅ "Unknown object 'collection'" - BEHOBEN!
**→ Scripts verwenden jetzt `bw create org-collection`**

### ❌ "Index operation failed; the array index evaluated to null"
**→ Behoben!** Scripts handhaben null-Folder-IDs sicher

### ❌ "Bitwarden nicht entsperrt"
```bash
bw unlock
# Führe das angezeigte export-Kommando aus
```

### ❌ "Organisation nicht gefunden"
- Prüfe Organisation-ID: **89f44255-10ff-455f-96e1-f4a4470f16e4**
- Stelle sicher, dass du Admin-Rechte hast

## Was die Scripts machen

### Personal Vault Analyse:
- Scannt **nur persönliche Items** (nicht-Organisation Items)
- Identifiziert Ordnerstruktur via Folder-IDs, Notes, Name-Prefixes
- Zeigt Migrationspotential und problematische Items

### Personal → Organisation Migration: ✅ **KORRIGIERT**
- **Erstellt Collections** mit korrektem `org-collection` Befehl
- **Verschiebt Items** zur Organisation und ordnet sie Collections zu
- **Entfernt persönliche Ordner-Zuordnung**
- **Behält Item-Metadaten** und Inhalte bei

## Sicherheit

- ✅ **Backup-Warnungen** vor jeder Migration
- ✅ **Dry-Run Modus** zum sicheren Testen  
- ✅ **Bestätigungs-Dialoge** vor Änderungen
- ✅ **Fehler-Behandlung** mit detailliertem Logging
- ✅ **API Rate-Limiting** (100ms Pause zwischen Items)
- ✅ **Korrekte CLI-Befehle** (org-collection)

## Ausgabe-Dateien

- **Analyse**: `personal-vault-analysis-YYYYMMDD-HHMMSS.json`
- **Backups**: `personal-backup-YYYYMMDD.json`

## CLI-Befehl Referenz

### ✅ **KORREKT** (diese Version):
```powershell
bw create org-collection  # Für Organisation Collections
```

### ❌ **FALSCH** (alte Version):
```powershell
bw create collection  # Fehler: "Unknown object"
```

## Häufige Fragen

### Q: Warum der "Unknown object 'collection'" Fehler?
A: ✅ **Behoben!** Scripts verwenden jetzt den korrekten `org-collection` Befehl.

### Q: Gehen meine Ordner verloren?
A: Nein! Ordnerstruktur wird als Collections nachgebildet. Original-Metadaten bleiben erhalten.

### Q: Kann ich die Migration rückgängig machen?
A: Ja, durch Restore des Backups. Deshalb ist Backup-Erstellung Pflicht.

## Support

Bei Problemen kontaktiere Henry bei DMI.

### Debug-Informationen sammeln:
```powershell
bw status
bw list organizations
bw list items | ConvertFrom-Json | Measure-Object
bw list folders | ConvertFrom-Json | Measure-Object
```

## Organisation-ID

Aktuelle Organisation: **89f44255-10ff-455f-96e1-f4a4470f16e4**

---

**Version:** Korrigiert - CLI-Befehl & null-ID Fehler behoben  
**Erstellt:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  
**Location:** C:\REPOSITORIES\external\vaultwarden\scripts\
