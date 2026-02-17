param([string]$Session)
$orgId = "89f44255-10ff-455f-96e1-f4a4470f16e4"

Write-Host "=== COLLECTION DIAGNOSTIC ===" -ForegroundColor Cyan
bw sync --session $Session | Out-Null

# Get all items and their collection assignments
$items = bw list items --organizationid $orgId --session $Session | ConvertFrom-Json
$collections = bw list collections --organizationid $orgId --session $Session | ConvertFrom-Json

# Build map: collectionId -> item count
$collItemCount = @{}
foreach ($coll in $collections) {
    $collItemCount[$coll.id] = 0
}
foreach ($item in $items) {
    if ($item.collectionIds) {
        foreach ($cid in $item.collectionIds) {
            if ($collItemCount.ContainsKey($cid)) {
                $collItemCount[$cid]++
            }
        }
    }
}

# Report
$empty = @()
$filled = @()
foreach ($coll in $collections | Sort-Object name) {
    $count = $collItemCount[$coll.id]
    if ($count -eq 0) {
        $empty += $coll
    } else {
        $filled += @{ Name = $coll.name; Count = $count; Id = $coll.id }
    }
}

Write-Host "`nCollections WITH items: $($filled.Count)" -ForegroundColor Green
foreach ($f in $filled) {
    Write-Host "  [$($f.Count)] $($f.Name)" -ForegroundColor Gray
}

Write-Host "`nEMPTY collections: $($empty.Count)" -ForegroundColor Yellow
foreach ($e in $empty) {
    Write-Host "  $($e.name)" -ForegroundColor Red
}

# Check items without collection
$noCollection = $items | Where-Object { -not $_.collectionIds -or $_.collectionIds.Count -eq 0 }
if ($noCollection.Count -gt 0) {
    Write-Host "`nItems WITHOUT any collection: $($noCollection.Count)" -ForegroundColor Red
    foreach ($nc in $noCollection) {
        Write-Host "  $($nc.name)" -ForegroundColor Red
    }
}

Write-Host "`nTotal: $($items.Count) items, $($collections.Count) collections" -ForegroundColor Cyan
