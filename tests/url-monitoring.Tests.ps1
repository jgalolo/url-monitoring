
# tests\url-monitoring.Tests.ps1
# Starter tests for your URL Monitoring script
# Adjust function names if they differ in your file.

# Try to dot-source the script from repo root so tests can call its functions.
$scriptPathCandidates = @(
    (Join-Path $PSScriptRoot '..\url-monitoring.ps1'),
    (Join-Path $PSScriptRoot '..\WUM.ps1')
)

$scriptPath = $scriptPathCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $scriptPath) {
    throw "Monitoring script not found at repo root as url-monitoring.ps1 or WUM.ps1."
}

. $scriptPath  # dot-source the script so its functions & variables are available

# Ensure Pester is available (GitHub Actions installs it; local run may need this)
Import-Module Pester -ErrorAction SilentlyContinue

Describe 'Validate-Config' {
    It 'throws when required top-level keys are missing' {
        $badConfig = @{ }  # empty config
        { Validate-Config -config $badConfig } | Should -Throw
    }

    It 'passes when all required keys exist' {
        $goodConfig = @{
            services = @(@{ name = 'TestService'; url = 'https://example.org' })
            emailSettings = @{ from='a@b.com'; to='c@d.com'; smtpServer='smtp.test'; port=587 }
            loggingSettings = @{ logFilePath = 'C:\Logs' }
            timeoutSettings = @{ timeoutSec = 5; retryCount = 2 }
            notificationSettings = @{ enableNotifications = $true; failureThreshold = 15 }
            filePaths = @{
                downtimeFilePath='C:\temp\downtime.json'
                totalDowntimeFilePath='C:\temp\total.json'
                statusFilePath='C:\temp\status.json'
                encryptedPasswordFilePath='C:\secure\pw.txt'
                incidentFilePath='C:\temp\incident.json'
            }
        }
        { Validate-Config -config $goodConfig } | Should -Not -Throw
    }
}

Describe 'Check-UrlStatus' {
    BeforeAll {
        # Provide defaults if the script expects these globals
        if (-not (Get-Variable -Name retryCount -Scope Script -ErrorAction SilentlyContinue)) {
            Set-Variable -Name retryCount -Scope Script -Value 2
        }
        if (-not (Get-Variable -Name timeoutSec -Scope Script -ErrorAction SilentlyContinue)) {
            Set-Variable -Name timeoutSec -Scope Script -Value 5
        }
    }

    It 'returns Up when Invoke-WebRequest returns StatusCode 200' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        (Check-UrlStatus -url 'https://ok.test') | Should -Be 'Up'
    }

    It 'returns Down for non-200 codes' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 500 } }
        (Check-UrlStatus -url 'https://bad-code.test') | Should -Be 'Down'
    }

    It 'returns Down after retries when Invoke-WebRequest throws' {
        Mock Invoke-WebRequest { throw 'network error' }
        (Check-UrlStatus -url 'https://throws.test') | Should -Be 'Down'
    }
}

Describe 'Add-DowntimeDuration' {
    It 'adds two durations correctly' {
        (Add-DowntimeDuration -existingDuration '00:05:00' -newDuration '00:10:00') | Should -Be '00:15:00'
    }

    It 'handles hours wrap correctly' {
        (Add-DowntimeDuration -existingDuration '01:30:00' -newDuration '00:45:00') | Should -Be '02:15:00'
    }
}

Describe 'Log-Message (sanity)' {
    It 'appends to a date-based log file under provided base path' {
        # Arrange: temp folder and override the global used by the script
        $temp = Join-Path $env:TEMP ("log-" + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $temp | Out-Null

        Set-Variable -Name logFilePathBase -Scope Script -Value $temp

        # Act
        Log-Message -message 'hello world' -level 'INFO'

        # Assert
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $logFile = Join-Path $        $logFile = Join-Path $temp "wum-$today.log"
        Test-Path $logFile | Should -BeTrue

        # Cleanup
        Remove-Item $temp -Recurse -Force
    }
