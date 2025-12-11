# Load configuration from JSON file
$configFilePath = "G:\Scripts\urlmonitoring\config.json"
$config = Get-Content -Path $configFilePath | ConvertFrom-Json

# Validate configuration
function Validate-Config {
    param (
        [PSObject]$config
    )
    if (-not $config.services) { throw "Missing 'services' in configuration." }
    if (-not $config.emailSettings) { throw "Missing 'emailSettings' in configuration." }
    if (-not $config.loggingSettings) { throw "Missing 'loggingSettings' in configuration." }
    if (-not $config.timeoutSettings) { throw "Missing 'timeoutSettings' in configuration." }
    if (-not $config.notificationSettings) { throw "Missing 'notificationSettings' in configuration." }
    if (-not $config.filePaths) { throw "Missing 'filePaths' in configuration." }
}

try {
    Validate-Config -config $config
} catch {
    Write-Error "Configuration validation failed: $_"
    exit 1
}

# Extract settings from configuration
$services = $config.services
$emailSettings = $config.emailSettings
$logFilePathBase = $config.loggingSettings.logFilePath
$timeoutSec = $config.timeoutSettings.timeoutSec
$retryCount = $config.timeoutSettings.retryCount
$enableNotifications = $config.notificationSettings.enableNotifications
$failureThreshold = $config.notificationSettings.failureThreshold
$downtimeFilePath = $config.filePaths.downtimeFilePath
$totalDowntimeFilePath = $config.filePaths.totalDowntimeFilePath
$statusFilePath = $config.filePaths.statusFilePath
$encryptedPasswordFilePath = $config.filePaths.encryptedPasswordFilePath
$reportDirectory = $config.filePaths.reportDirectory

# Enforce TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Function to log messages with different levels (INFO, WARN, ERROR)
function Log-Message {
    param (
        [string]$message,
        [string]$level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logDate = (Get-Date).ToString("yyyy-MM-dd")
    $logFilePath = "$logFilePathBase\wum-$logDate.log"
    $logMessage = "$timestamp [$level] - $message"
    Add-Content -Path $logFilePath -Value $logMessage
}

# Load total downtime from JSON file
$totalDowntime = @{ }
if (Test-Path $totalDowntimeFilePath) {
    $jsonContent = Get-Content $totalDowntimeFilePath | ConvertFrom-Json
    $totalDowntime = ConvertTo-Hashtable -JsonObject $jsonContent
}

# Function to convert time string to hours
function Convert-TimeStringToHours {
    param (
        [string]$timeString
    )
    $timeSpan = [TimeSpan]::Parse($timeString)
    return $timeSpan.TotalHours
}

# Function to convert time string to minutes
function Convert-TimeStringToMinutes {
    param (
        [string]$timeString
    )
    $timeSpan = [TimeSpan]::Parse($timeString)
    return $timeSpan.TotalMinutes
}

# Calculate uptime percentage and downtime in minutes
function Calculate-UptimePercentage {
    param (
        [string]$url,
        [int]$totalHoursInMonth
    )
    if ($totalDowntime.ContainsKey($url)) {
        $downtimeHours = Convert-TimeStringToHours -timeString $totalDowntime[$url]
        $downtimeMinutes = Convert-TimeStringToMinutes -timeString $totalDowntime[$url]
        $uptimeHours = $totalHoursInMonth - $downtimeHours
        $uptimePercentage = ($uptimeHours / $totalHoursInMonth) * 100
    } else {
        $uptimePercentage = 100
        $downtimeMinutes = 0
    }
    return [math]::Round($uptimePercentage, 2), [math]::Round($downtimeMinutes, 2)
}

# Get total hours in the current month
$currentDate = Get-Date
$totalHoursInMonth = (New-TimeSpan -Start (Get-Date -Year $currentDate.Year -Month $currentDate.Month -Day 1) -End (Get-Date -Year $currentDate.Year -Month $currentDate.Month -Day ([DateTime]::DaysInMonth($currentDate.Year, $currentDate.Month)) -Hour 23 -Minute 59 -Second 59)).TotalHours

# Parse log files to count downtimes and checks
$logFiles = Get-ChildItem -Path $logFilePathBase -Filter "*.log"
$downtimeCounts = @{ }
$checkCounts = @{ }

foreach ($logFile in $logFiles) {
    $logContent = Get-Content -Path $logFile.FullName
    foreach ($line in $logContent) {
        if ($line -match "\[(INFO|ERROR)\] - Checked (.+?) \((.+?)\) - Status: (.+)") {
            $url = $matches[3]
            if (-not $checkCounts.ContainsKey($url)) {
                $checkCounts[$url] = 0
            }
            $checkCounts[$url]++
            if ($matches[4] -eq "Down") {
                if (-not $downtimeCounts.ContainsKey($url)) {
                    $downtimeCounts[$url] = 0
                }
                $downtimeCounts[$url]++
            }
        }
    }
}

# Generate report
$currentDateTime = Get-Date
$timestamp = $currentDateTime.ToString("yyyyMMdd_HHmmss")
$reportFilePath = "$reportDirectory\uptime_report_$timestamp.csv"

# Ensure the report directory exists
if (-not (Test-Path $reportDirectory)) {
    New-Item -Path $reportDirectory -ItemType Directory | Out-Null
}

$reportContent = @("Service Name,URL,Total Checks,Down Checks,Total Downtime (minutes),Uptime Percentage")

foreach ($service in $config.services) {
    $serviceName = $service.name
    $url = $service.url
    $uptimePercentage, $downtimeMinutes = Calculate-UptimePercentage -url $url -totalHoursInMonth $totalHoursInMonth
    $downtimeCount = $downtimeCounts[$url] -as [int]
    $checkCount = $checkCounts[$url] -as [int]
    $reportContent += "$serviceName,$url,$checkCount,$downtimeCount,$downtimeMinutes,$uptimePercentage"
}

# Save report to file
try {
    $reportContent | Out-File -FilePath $reportFilePath
    Log-Message "Uptime report generated and saved to $reportFilePath" "INFO"
} catch {
    Log-Message "Error saving uptime report to file: $_" "ERROR"
}
