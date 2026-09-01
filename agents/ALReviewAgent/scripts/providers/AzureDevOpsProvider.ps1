<#
.SYNOPSIS
    Azure DevOps review-host provider for Invoke-CopilotPRReview.ps1.

.DESCRIPTION
    Dot-sourced by the orchestrator when REVIEW_PROVIDER=azuredevops. Implements
    the same pull-request surface as GitHubProvider.ps1 against the Azure DevOps
    Git "pull request threads" REST API (api-version 7.1).

    GitHub -> Azure DevOps mapping:
      GitHub review comment (inline)  ->  a thread with threadContext.filePath
      GitHub issue comment (PR-level) ->  a thread without threadContext
      PATCH issue comment             ->  PATCH .../threads/{tid}/comments/{cid}

    Comment objects returned by Get-ReviewComments / Get-IssueComments expose the
    same property names the orchestrator reads from the GitHub payloads
    (.body .path .line .original_line .side .id) so the downstream dedup,
    iteration and summary-upsert logic is unchanged. For Azure DevOps, .id is a
    composite "<threadId>.<commentId>" string (Update-IssueComment parses it).

    Environment (Azure Pipelines predefined variables):
      SYSTEM_COLLECTIONURI             e.g. https://dev.azure.com/contoso/
      SYSTEM_TEAMPROJECT               project name
      BUILD_REPOSITORY_ID / _NAME      repository id (preferred) or name
      SYSTEM_PULLREQUEST_PULLREQUESTID pull request id
      SYSTEM_ACCESSTOKEN               OAuth token (map it explicitly in the job)
                                       or AZURE_DEVOPS_TOKEN as an override PAT
#>

Set-StrictMode -Version Latest

$script:AdoOrgUrl  = (($env:SYSTEM_COLLECTIONURI ?? '') + '').TrimEnd('/')
$script:AdoProject = ($env:SYSTEM_TEAMPROJECT ?? '') + ''
$script:AdoRepo    = ($env:BUILD_REPOSITORY_ID ?? $env:BUILD_REPOSITORY_NAME ?? '') + ''
$script:AdoPrId    = [int]((($env:SYSTEM_PULLREQUEST_PULLREQUESTID ?? $env:PR_NUMBER ?? '0') + '').Trim())
$script:AdoToken   = ($env:AZURE_DEVOPS_TOKEN ?? $env:SYSTEM_ACCESSTOKEN ?? '') + ''
$script:AdoApiVer  = '7.1'
$script:AdoThreadCache = $null

if (-not $script:AdoOrgUrl -or -not $script:AdoProject -or -not $script:AdoRepo) {
    throw 'AzureDevOpsProvider: SYSTEM_COLLECTIONURI, SYSTEM_TEAMPROJECT and BUILD_REPOSITORY_ID/NAME must all be set.'
}

$script:AdoBase = '{0}/{1}/_apis/git/repositories/{2}' -f `
    $script:AdoOrgUrl, [uri]::EscapeDataString($script:AdoProject), [uri]::EscapeDataString($script:AdoRepo)

function Invoke-AdoApi {
    param(
        [string] $Method,
        [string] $Path,
        [hashtable] $Query,
        [object]  $Body
    )

    if (-not $script:AdoToken) {
        throw 'AzureDevOpsProvider: no token available (set SYSTEM_ACCESSTOKEN or AZURE_DEVOPS_TOKEN).'
    }

    $q = @{ 'api-version' = $script:AdoApiVer }
    if ($Query) { foreach ($k in $Query.Keys) { $q[$k] = $Query[$k] } }
    $qs = ($q.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
    $url = "$script:AdoBase$Path`?$qs"

    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($script:AdoToken)"))
    $headers = @{
        Authorization = "Basic $basic"
        'User-Agent'  = 'bcapps-copilot-pr-reviewer'
    }

    $params = @{ Uri = $url; Method = $Method; Headers = $headers }
    if ($Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 12 -Compress)
        $params.ContentType = 'application/json'
    }
    return Invoke-RestMethod @params
}

# StrictMode-safe property read for Invoke-RestMethod JSON objects (Azure DevOps
# omits absent fields entirely, and the orchestrator runs Set-StrictMode -Latest).
function Get-JsonProp {
    param($Object, [string] $Name)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $null
}

function Get-AdoThreads {
    param([switch] $Refresh)
    if ($Refresh -or $null -eq $script:AdoThreadCache) {
        $resp = Invoke-AdoApi -Method GET -Path "/pullRequests/$($script:AdoPrId)/threads"
        $script:AdoThreadCache = @(Get-JsonProp $resp 'value')
    }
    return $script:AdoThreadCache
}

function ConvertFrom-AdoThreadComment {
    # Emits one comment-shaped object per non-deleted, non-system comment.
    param([object] $Thread)

    $ctx = Get-JsonProp $Thread 'threadContext'
    $filePath = Get-JsonProp $ctx 'filePath'
    $hasFile = [bool]$filePath
    $path = ''
    $line = 0
    $side = 'RIGHT'
    if ($hasFile) {
        $path = ([string]$filePath).TrimStart('/')
        $rightStart = Get-JsonProp $ctx 'rightFileStart'
        $leftStart  = Get-JsonProp $ctx 'leftFileStart'
        if ($null -ne (Get-JsonProp $rightStart 'line')) {
            $line = [int](Get-JsonProp $rightStart 'line'); $side = 'RIGHT'
        } elseif ($null -ne (Get-JsonProp $leftStart 'line')) {
            $line = [int](Get-JsonProp $leftStart 'line'); $side = 'LEFT'
        }
    }

    foreach ($c in @(Get-JsonProp $Thread 'comments')) {
        if (Get-JsonProp $c 'isDeleted') { continue }
        if (((Get-JsonProp $c 'commentType') ?? 'text') -eq 'system') { continue }
        $tid = Get-JsonProp $Thread 'id'
        $cid = Get-JsonProp $c 'id'
        [pscustomobject]@{
            id            = "$tid.$cid"
            thread_id     = [int]$tid
            comment_id    = [int]$cid
            body          = [string](Get-JsonProp $c 'content')
            path          = $path
            line          = $line
            original_line = $line
            side          = $side
            has_file      = [bool]$hasFile
        }
    }
}

function Get-PrFiles { return @() }

function Get-ReviewComments {
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($t in (Get-AdoThreads)) {
        foreach ($c in (ConvertFrom-AdoThreadComment -Thread $t)) {
            if ($c.has_file) { $out.Add($c) | Out-Null }
        }
    }
    return $out.ToArray()
}

function Get-IssueComments {
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($t in (Get-AdoThreads)) {
        foreach ($c in (ConvertFrom-AdoThreadComment -Thread $t)) {
            if (-not $c.has_file) { $out.Add($c) | Out-Null }
        }
    }
    return $out.ToArray()
}

function New-ReviewComment {
    param(
        [string] $Body, [string] $Path, [int] $Line, [string] $Side,
        [int] $StartLine = 0, [string] $StartSide = ''
    )

    if (-not $Line -or -not $Side) {
        throw 'Inline review comments require both line and side.'
    }

    $isLeft   = ($Side -eq 'LEFT')
    $startKey = if ($isLeft) { 'leftFileStart' } else { 'rightFileStart' }
    $endKey   = if ($isLeft) { 'leftFileEnd' }   else { 'rightFileEnd' }
    $start    = if ($StartLine -gt 0 -and $StartLine -lt $Line) { $StartLine } else { $Line }

    $ctx = @{ filePath = '/' + ($Path -replace '^/', '') }
    $ctx[$startKey] = @{ line = $start; offset = 1 }
    $ctx[$endKey]   = @{ line = $Line;  offset = 1 }

    $payload = @{
        comments = @(@{ parentCommentId = 0; content = $Body; commentType = 'text' })
        status   = 'active'
        threadContext = $ctx
    }
    $result = Invoke-AdoApi -Method POST -Path "/pullRequests/$($script:AdoPrId)/threads" -Body $payload
    $script:AdoThreadCache = $null   # invalidate; next read re-fetches
    return $result
}

function New-IssueComment {
    param([string] $Body)
    $payload = @{
        comments = @(@{ parentCommentId = 0; content = $Body; commentType = 'text' })
        status   = 'active'
    }
    $result = Invoke-AdoApi -Method POST -Path "/pullRequests/$($script:AdoPrId)/threads" -Body $payload
    $script:AdoThreadCache = $null
    return $result
}

function Update-IssueComment {
    param([string] $CommentId, [string] $Body)

    # $CommentId is the composite "<threadId>.<commentId>" emitted by
    # ConvertFrom-AdoThreadComment.
    $parts = ([string]$CommentId).Split('.')
    if ($parts.Count -ne 2) {
        # Fall back: locate the comment across current threads.
        foreach ($t in (Get-AdoThreads -Refresh)) {
            foreach ($c in @(Get-JsonProp $t 'comments')) {
                if ("$(Get-JsonProp $c 'id')" -eq "$CommentId") {
                    $parts = @("$(Get-JsonProp $t 'id')", "$(Get-JsonProp $c 'id')"); break
                }
            }
        }
    }
    if ($parts.Count -ne 2) { throw "Update-IssueComment: cannot resolve thread for comment '$CommentId'." }

    $threadId  = $parts[0]
    $commentId = $parts[1]
    $result = Invoke-AdoApi -Method PATCH `
        -Path "/pullRequests/$($script:AdoPrId)/threads/$threadId/comments/$commentId" `
        -Body @{ content = $Body }
    $script:AdoThreadCache = $null
    return $result
}
