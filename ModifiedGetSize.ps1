$SPath = "C:\Users\jgalolo\OneDrive - DXC Production\Desktop\TestScript"
$DStart = Get-Date "2023-12-20"
$Dend = Get-Date "2024-11-22"

$files = Get-ChildItem -Path $SPath -File -Recurse | Where-Object {
    ($_.LastWriteTime -ge $DStart) -and ($_.LastWriteTime -le $Dend)
}
$totalSize = ($files | Measure-Object -Property Length -Sum).Sum
$totalSizeMB = [math]::Round($totalSize / 1MB, 2)
Write-Host "Total size modified from the date range given ($totalSizeMB MB)"

# Monitor job progress
Write-Host "Background job started with ID: $($job.Id)"
Write-Host "Run 'Get-Job -Id $($job.Id)' to check the job status."