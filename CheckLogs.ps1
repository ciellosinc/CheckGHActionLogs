Param(
    [Parameter(HelpMessage = "The GitHub Token running the action", Mandatory = $true)]
    [string] $GH_TOKEN,
    [Parameter(HelpMessage = "The GitHub repo name", Mandatory = $false)]
    [string] $REPO = $env:GITHUB_REPOSITORY,
    [Parameter(HelpMessage = "ID of the workflow run to check. If empty, the WORKFLOWS repository variable is used", Mandatory = $false)]
    [string] $RunId = '',
    [Parameter(HelpMessage = "JSON array of workflow names. Default is the WORKFLOWS repository variable", Mandatory = $false)]
    [string] $Workflows = '',
    [Parameter(HelpMessage = "Maximum number of error lines to include", Mandatory = $false)]
    [int] $MaxErrors = 50
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$reportableConclusions = @("failure", "neutral", "cancelled", "skipped", "timed_out", "action_required", "startup_failure")
$runFields = 'attempt,conclusion,startedAt,displayTitle,headBranch,event,url,databaseId,workflowName,status'
$env:GH_TOKEN = $GH_TOKEN

function Get-WorkflowNames {
    if ($Workflows) {
        $json = $Workflows
    }
    else {
        # Retrieve the 'WORKFLOWS' repository variable
        try {
            $json = gh api "repos/$REPO/actions/variables/WORKFLOWS" --jq '.value'
        }
        catch {
            Write-Host "Failed to retrieve the 'WORKFLOWS' repository variable. $($_.Exception.Message)"
            return @()
        }
    }
    if (-not $json) {
        Write-Host "No workflow names specified (input 'workflows' or repository variable 'WORKFLOWS')."
        return @()
    }
    try {
        return @(ConvertFrom-Json -InputObject $json | Where-Object { $_ } | Select-Object -Unique)
    }
    catch {
        Write-Host "Failed to parse the workflow names as JSON. $($_.Exception.Message)"
        return @()
    }
}

function Get-RunErrors {
    Param(
        [string] $Id
    )

    $tempFolder = Join-Path ([System.IO.Path]::GetTempPath()) "workflow_logs_$Id"
    $logFile = "$tempFolder.zip"
    try {
        $headers = @{
            "Authorization"        = "Bearer $GH_TOKEN"
            "Accept"               = "application/vnd.github+json"
            "X-GitHub-Api-Version" = "2022-11-28"
        }
        Invoke-WebRequest -Uri "https://api.github.com/repos/$REPO/actions/runs/$Id/logs" -Headers $headers -OutFile $logFile | Out-Null
        Expand-Archive -Path $logFile -DestinationPath $tempFolder -Force

        # Collect the lines marked as errors, without the timestamp and the ##[error] marker
        $errorLines = Get-ChildItem -Path $tempFolder -Recurse -Filter "*.txt" |
            ForEach-Object { Get-Content -Path $_.FullName } |
            Select-String -Pattern "\[error\]" |
            ForEach-Object { ($_.Line -replace '^.*?\[error\]\s*', '').Trim() } |
            Where-Object { $_ -and $_ -notmatch '^Process completed with exit code' } |
            Select-Object -Unique

        $alErrors = @($errorLines | Where-Object { $_ -match '\bAL\d{4}\b' })
        $otherErrors = @($errorLines | Where-Object { $_ -notmatch '\bAL\d{4}\b' })
        $message = ""
        if ($alErrors) {
            $message += "AL errors found in logs:`n" + (($alErrors | Select-Object -First $MaxErrors) -join "`n")
        }
        if ($otherErrors) {
            if ($message) { $message += "`n`n" }
            $message += "Other errors found in logs:`n" + (($otherErrors | Select-Object -First $MaxErrors) -join "`n")
        }
        if (-not $message) {
            $message = "No error lines found in the logs."
        }
        return $message
    }
    catch {
        Write-Host "Failed to download or extract the log file. $($_.Exception.Message)"
        return "Failed to download or extract the log file."
    }
    finally {
        Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
    }
}

function Set-Output {
    Param(
        [string] $Name,
        [string] $Value
    )
    Add-Content -Encoding UTF8 -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
    Add-Content -Encoding UTF8 -Path $env:GITHUB_ENV -Value "$Name=$Value"
    Write-Host "Set $($Name): $Value"
}

# Find the run to report
$run = $null
if ($RunId) {
    $run = gh run view $RunId --repo $REPO --json $runFields | ConvertFrom-Json
    if ($run.conclusion -notin $reportableConclusions) {
        Write-Host "Workflow run '$($run.workflowName)' ($RunId) has conclusion: $($run.conclusion). No action taken."
        $run = $null
    }
}
else {
    $workflowRuns = @(gh run list --repo $REPO --limit 50 --json $runFields | ConvertFrom-Json)
    foreach ($workflowName in (Get-WorkflowNames)) {
        # AL-Go workflow names start with a space, so compare trimmed names
        $latest = $workflowRuns | Where-Object { $_.status -eq 'completed' -and ($_.workflowName.Trim() -eq $workflowName.Trim() -or $_.displayTitle.Trim() -eq $workflowName.Trim()) } | Select-Object -First 1
        if (-not $latest) {
            Write-Host "No completed workflow runs found for workflow '$workflowName' in repository '$REPO'."
        }
        elseif ($latest.conclusion -in $reportableConclusions) {
            $run = $latest
            break
        }
        else {
            Write-Host "Workflow '$workflowName' has conclusion: $($latest.conclusion). No action taken."
        }
    }
}

if (-not $run) {
    Write-Host "No workflows with the specified conclusions found."
    Set-Output -Name 'found' -Value 'false'
    return
}

$workflowRunName = $run.workflowName.Trim()
$workflowRunMessage = "The workflow '$workflowRunName' started at $($run.startedAt) on branch '$($run.headBranch)' for the event '$($run.event)' has been attempted $($run.attempt) times and has finished with status: $($run.conclusion)."
Write-Host $workflowRunMessage
Write-Host "To find out more information, please check: $($run.url)"

$foundErrors = ''
if ($run.conclusion -eq 'failure') {
    $foundErrors = Get-RunErrors -Id $run.databaseId
    $workflowRunMessage += "`n`n$foundErrors"
}

Set-Output -Name 'found' -Value 'true'
Set-Output -Name 'workflowRunName' -Value $workflowRunName
Set-Output -Name 'workflowRunId' -Value $run.databaseId
Set-Output -Name 'workflowRunAttempts' -Value $run.attempt
Set-Output -Name 'workflowRunStartTime' -Value $run.startedAt
Set-Output -Name 'workflowRunOnBranch' -Value $run.headBranch
Set-Output -Name 'workflowRunAtEvent' -Value $run.event
Set-Output -Name 'workflowRunConclusion' -Value $run.conclusion
Set-Output -Name 'workflowRunURL' -Value $run.url
Set-Output -Name 'workflowRunMessage' -Value ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($workflowRunMessage)))
Set-Output -Name 'allFoundErrors' -Value ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($foundErrors)))
