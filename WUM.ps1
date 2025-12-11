# Set the working directory to the script location
Set-Location -Path "G:\Scripts\urlmonitoring"

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
$incidentFilePath = $config.filePaths.incidentFilePath

# Enforce TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Function to log messages with levels (INFO, WARN, ERROR)
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

# Function to check URL status with retry logic
Function Check-UrlStatus {
    param (
        [string]$url
    )
    $attempt = 0
    while ($attempt -lt $retryCount) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeoutSec -UseDefaultCredentials
            if ($response.StatusCode -eq 200) {
                return "Up"
            } else {
                return "Down"
            }
        } catch {
            $attempt++
            if ($attempt -ge $retryCount) {
                return "Down"
            }
            Start-Sleep -Seconds 5
        }
    }
}

# send email notifications for eac URL
function Send-EmailNotification {
    param (
        [string]$serviceName,
        [string]$url,
        [string]$timestamp,
        [string]$status,
        [string]$duration
    )
    $From = $emailSettings.from
    $To = $emailSettings.to
    $Subject = "$serviceName URL Status Alert - $status"

    $Body = @"
The following URL status has changed:

Service Name: $serviceName
URL: $url
Status: $status
Timestamp: $timestamp
Duration: $duration

Please check the web service and take necessary actions.
"@

 # Read the encrypted password from the file and convert it to a secure string
    $encryptedPassword = Get-Content $encryptedPasswordFilePath
    $secPassword = $encryptedPassword | ConvertTo-SecureString
    $Creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $From, $secPassword

    try {
        Send-MailMessage -From $From -To $To -Subject $Subject -Body $Body -SmtpServer $emailSettings.smtpServer -Port $emailSettings.port -UseSsl -Credential $Creds -Priority High
        Log-Message "Email sent for $url at $timestamp with status $status" "INFO"
    } catch {
        Log-Message "Failed to send email notification for $url at $timestamp. Error: $_" "ERROR"
    }
}

# Convert a JSON object to a hashtable
function ConvertTo-Hashtable {
    param (
        [Parameter(Mandatory = $true)]
        [PSObject]$JsonObject
    )
    $hashtable = @{ }
    foreach ($key in $JsonObject.PSObject.Properties.Name) {
        $hashtable[$key] = $JsonObject.$key
    }
    return $hashtable
}

# Downtime tracking from file
$downtimeStart = @{ }
if (Test-Path $downtimeFilePath) {
    $jsonContent = Get-Content $downtimeFilePath | ConvertFrom-Json
    $downtimeStart = ConvertTo-Hashtable -JsonObject $jsonContent
}

# Total downtime tracking file
$totalDowntime = @{ }
if (Test-Path $totalDowntimeFilePath) {
    $jsonContent = Get-Content $totalDowntimeFilePath | ConvertFrom-Json
    $totalDowntime = ConvertTo-Hashtable -JsonObject $jsonContent
}

# Initialize incident tracking from file
$incidentCreated = @{}
if (Test-Path $incidentFilePath) {
    $jsonContent = Get-Content $incidentFilePath | ConvertFrom-Json
    $incidentCreated = ConvertTo-Hashtable -JsonObject $jsonContent
}

# Convert time string to TimeSpan
function Convert-TimeStringToTimeSpan {
    param (
        [string]$timeString
    )
    return [TimeSpan]::Parse($timeString)
}

# add downtime durations
function Add-DowntimeDuration {
    param (
        [string]$existingDuration,
        [string]$newDuration
    )
    $existingTimeSpan = Convert-TimeStringToTimeSpan -timeString $existingDuration
    $newTimeSpan = Convert-TimeStringToTimeSpan -timeString $newDuration
    $totalTimeSpan = $existingTimeSpan + $newTimeSpan
    return $totalTimeSpan.ToString("c")
}

# Log the start of the script
Log-Message "URL monitoring script started" "INFO"

$statusList = @()

foreach ($service in $services) {
    $serviceName = $service.name
    $url = $service.url
    try {
        $status = Check-UrlStatus -url $url
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        if ($status -eq "Down") {
            if (-not $downtimeStart.ContainsKey($url)) {
                $downtimeStart[$url] = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
            $downtimeDuration = (New-TimeSpan -Start $downtimeStart[$url] -End (Get-Date)).ToString("c").Split(".")[0]
            if ($downtimeDuration -ge [TimeSpan]::Parse("00:15:00") -and (-not $incidentCreated.ContainsKey($url) -or $incidentCreated[$url] -eq $false)) {
                Log-Message "Creating incident for $url with downtime duration $downtimeDuration" "INFO"
                .\SnowIntegration.ps1 -serviceName $serviceName -url $url -downtimeDuration $downtimeDuration
                $incidentCreated[$url] = $true
            }
            if ($enableNotifications) {
                Send-EmailNotification -serviceName $serviceName -url $url -timestamp $timestamp -status "Down" -duration $downtimeDuration
            }
        } else {
            if ($downtimeStart.ContainsKey($url)) {
                $downtimeDuration = (New-TimeSpan -Start $downtimeStart[$url] -End (Get-Date)).ToString("c").Split(".")[0]
                $downtimeStart.Remove($url)
                $incidentCreated[$url] = $false
                Log-Message "Resetting incident flag for $url after downtime duration $downtimeDuration" "INFO"
                if ($totalDowntime.ContainsKey($url)) {
                    $totalDowntime[$url] = Add-DowntimeDuration -existingDuration $totalDowntime[$url] -newDuration $downtimeDuration
                } else {
                    $totalDowntime[$url] = $downtimeDuration
                }
                if ($enableNotifications) {
                    Send-EmailNotification -serviceName $serviceName -url $url -timestamp $timestamp -status "Up" -duration $downtimeDuration
                }
            }
        }
        $statusList += [PSCustomObject]@{ ServiceName = $serviceName; URL = $url; Status = $status; Timestamp = $timestamp }
        Log-Message "Checked $serviceName ($url) - Status: $status" "INFO"
    } catch {
        Log-Message "Error checking $serviceName ($url): $_.Exception.Message" "ERROR"
    }
}

# Save downtime start times to file
try {
    $downtimeStart | ConvertTo-Json | Set-Content -Path $downtimeFilePath
    Log-Message "Downtime start times saved to file" "INFO"
} catch {
    Log-Message "Error saving downtime start times to file: $_.Exception.Message" "ERROR"
}

# save total downtime to file
try {
    $totalDowntime | ConvertTo-Json | Set-Content -Path $totalDowntimeFilePath
    Log-Message "Total downtime saved to file" "INFO"
} catch {
    Log-Message "Error saving total downtime to file: $_.Exception.Message" "ERROR"
}

# Save incident tracking to file
try {
    $incidentCreated | ConvertTo-Json | Set-Content -Path $incidentFilePath
    Log-Message "Incident tracking saved to file" "INFO"
} catch {
    Log-Message "Error saving incident tracking to file: $_.Exception.Message" "ERROR"
}

# save status to JSON file
try {
    $statusList | ConvertTo-Json | Set-Content -Path $statusFilePath
    Log-Message "Status saved to JSON file" "INFO"
} catch {
    Log-Message "Error saving status to JSON file: $_.Exception.Message" "ERROR"
}

Log-Message "URL monitoring ended" "INFO"
