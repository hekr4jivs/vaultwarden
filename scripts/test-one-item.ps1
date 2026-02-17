param([string]$Session)
$orgId = "89f44255-10ff-455f-96e1-f4a4470f16e4"

# Get first item and its target collection
$items = bw list items --organizationid $orgId --session $Session | ConvertFrom-Json
$folders = bw list folders --session $Session | ConvertFrom-Json
$collections = bw list collections --organizationid $orgId --session $Session | ConvertFrom-Json

$folderLookup = @{}
foreach ($f in $folders) { if ($f.id) { $folderLookup[$f.id] = $f.name } }
$collectionLookup = @{}
foreach ($c in $collections) { $collectionLookup[$c.name] = $c.id }

# Find first item with a folder that matches a collection
$testItem = $null
$targetCollId = $null
foreach ($item in $items) {
    if ($item.folderId -and $folderLookup.ContainsKey($item.folderId)) {
        $folderName = $folderLookup[$item.folderId]
        if ($collectionLookup.ContainsKey($folderName)) {
            $testItem = $item
            $targetCollId = $collectionLookup[$folderName]
            break
        }
    }
}

if (-not $testItem) {
    Write-Host "No test item found" -ForegroundColor Red
    exit 1
}

Write-Host "Test item: $($testItem.name)" -ForegroundColor Cyan
Write-Host "Current collections: $($testItem.collectionIds -join ', ')" -ForegroundColor Yellow
Write-Host "Target collection: $targetCollId ($($folderLookup[$testItem.folderId]))" -ForegroundColor Green

# Keep existing + add new
$newCollIds = @($testItem.collectionIds | Where-Object { $_ }) + @($targetCollId) | Select-Object -Unique
Write-Host "New collection IDs: $($newCollIds -join ', ')" -ForegroundColor Cyan

$collJson = ConvertTo-Json @($newCollIds) -Compress
$collBytes = [System.Text.Encoding]::UTF8.GetBytes($collJson)
$encodedColl = [System.Convert]::ToBase64String($collBytes)

Write-Host "`nRunning: bw edit item-collections $($testItem.id) ..." -ForegroundColor Yellow
$result = bw edit item-collections $testItem.id $encodedColl --organizationid $orgId --session $Session 2>&1
Write-Host "Result: $result" -ForegroundColor White

# Verify
bw sync --session $Session | Out-Null
$updated = bw get item $testItem.id --session $Session | ConvertFrom-Json
Write-Host "`nAfter update - collections: $($updated.collectionIds -join ', ')" -ForegroundColor Green
