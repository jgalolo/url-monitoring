# Load configuration from JSON file
$configFilePath = "G:\\Scripts\\urlmonitoring\\config.json"
$jsonContent = Get-Content -Path $configFilePath
# Write-Output "JSON Content: $jsonContent"  # Debugging step
$config = $jsonContent | ConvertFrom-Json

# Extract encrypted API credentials and other configurations
$clientIdPath = $config.apiCredentials.clientIdPath
$clientSecretPath = $config.apiCredentials.clientSecretPath
$refreshTokenPath = $config.apiCredentials.refreshTokenPath
$logFilePathBase = $config.logFilePathBase
$endpointUrl = $config.endpointUrl
$oauthTokenUrl = $config.oauthTokenUrl

# Function to read and decrypt credentials
function Get-DecryptedCredential {
    param (
        [string]$filePath
    )
    if (Test-Path $filePath) {
        $encryptedContent = Get-Content -Path $filePath
        if ($encryptedContent) {
            $secureString = $encryptedContent | ConvertTo-SecureString
            return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString))
        } else {
            throw "File content is null: $filePath"
        }
    } else {
        throw "File not found: $filePath"
    }
}

# Read and decrypt the credentials
try {
    $clientId = Get-DecryptedCredential -filePath $clientIdPath
    $clientSecret = Get-DecryptedCredential -filePath $clientSecretPath
    $refreshToken = Get-DecryptedCredential -filePath $refreshTokenPath
} catch {
    Log-Message "Failed to read and decrypt credentials: $_" "ERROR"
    exit 1
}

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

# Function to get OAuth 2.0 token
function Get-OAuthToken {
    $body = @{
        grant_type = "refresh_token"
        client_id = $clientId
        client_secret = $clientSecret
        refresh_token = $refreshToken
    }
    $response = Invoke-RestMethod -Uri $oauthTokenUrl -Method Post -Body $body
    return $response.access_token
}

# Function to create ServiceNow incident
function Create-ServiceNowIncident {
    param (
        [string]$token,
        [string]$serviceName,
        [string]$url,
        [string]$downtimeDuration
    )
    $incidentData = @{
        u_action = "create"
        u_contact_type = "Auto Ticket"
        u_urgency = "1"
        u_impact = "1"
        u_location = "MANILA NET PARK OFFICE"
        u_category = "Business Application & Databases"
        u_subcategory = "Application Platform"
        u_configuration_item = "eCARM CLOUD"
        u_service_offering = "ILM Optimization"
        u_business_service = "D&A ENTERPRISE ARCHIVE"
        u_assignment_group = "DXC_eCARM_SUPPORT"
        u_short_description = "[AUTO][eCARM-$serviceName]. Unable to connect to URL."
        u_description = "The service $serviceName is unable to connect to URL $url. Downtime duration: $downtimeDuration."
        u_problem_type = "Design: Availability"
    }
    $headers = @{
        Authorization = "Bearer $token"
        "Content-Type" = "application/json"
    }
    $response = Invoke-RestMethod -Uri $endpointUrl -Method Post -Headers $headers -Body ($incidentData | ConvertTo-Json)
    return $response
}

# Main logic
try {
    $token = Get-OAuthToken
    $response = Create-ServiceNowIncident -token $token -serviceName $serviceName -url $url -downtimeDuration $downtimeDuration
    Log-Message "Incident created successfully: $response" "INFO"
} catch {
    Log-Message "Failed to create incident: $_" "ERROR"
}
