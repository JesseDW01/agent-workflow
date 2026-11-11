<#
.SYNOPSIS
  Azure Boards tracking helper shared by ado-backlog-orchestrator, ado-worktree-worker and ado-pr-reviewer.

.DESCRIPTION
  Keeps the sprint taskboard truthful while agents work:
    current  - print the team's current iteration path (fails if none).
    ensure   - ensure a current sprint exists; creates "Sprint <yyyy>-<ww> <Suffix>" (-Days long) under \<Project>\<yyyy> and adds it to the team.
    assign   - put work items (and, with -WithChildren, their child Tasks) into the current sprint.
    move     - set state / remaining work / activity / tags, optionally add a discussion comment, on items.
    audit    - list inconsistencies under a root item (Tasks of Done PBIs not Done, Tasks In Progress under New/Approved PBIs,
               active items outside the current sprint). -Fix repairs them.

.EXAMPLE
  ado-board.ps1 -Action ensure -Org ABB-PA-Global -Project ConversionFramework -Team "ConversionFramework Team" -Suffix UI
  ado-board.ps1 -Action move -Org ABB-PA-Global -Project ConversionFramework -Id 16505 -State "In Progress" -Remaining 4 -Comment "Started in feat/AB-16450-x"
  ado-board.ps1 -Action audit -Org ABB-PA-Global -Project ConversionFramework -Team "ConversionFramework Team" -Id 16421 -Fix
#>
param(
  [Parameter(Mandatory)][ValidateSet('current', 'ensure', 'assign', 'move', 'audit')][string]$Action,
  [Parameter(Mandatory)][string]$Org,
  [Parameter(Mandatory)][string]$Project,
  [string]$Team,
  [int[]]$Id,
  [string]$State,
  [double]$Remaining = -1,
  [string]$Activity,
  [string]$Comment,
  [string]$AddTags,
  [string]$RemoveTags,
  [switch]$WithChildren,
  [switch]$Fix,
  [string]$Suffix = '',
  [int]$Days = 14
)
$ErrorActionPreference = 'Stop'
if (-not $Team) { $Team = "$Project Team" }
$tok = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
if (-not $tok) { throw 'az login required (az account get-access-token failed)' }
$H = @{ Authorization = "Bearer $tok" }
$B = "https://dev.azure.com/$Org/$([uri]::EscapeDataString($Project))"
$T = "$B/$([uri]::EscapeDataString($Team))"

function Api($m, $u, $body, $ct = 'application/json') {
  $p = @{ Method = $m; Uri = $u; Headers = $H }
  if ($null -ne $body) { $p.Body = if ($body -is [System.Collections.IList]) { ConvertTo-Json -InputObject @($body) -Depth 10 } else { $body | ConvertTo-Json -Depth 10 }; $p.ContentType = $ct }
  Invoke-RestMethod @p
}
function CurrentSprint {
  $r = Api GET "$T/_apis/work/teamsettings/iterations?`$timeframe=current&api-version=7.1"
  if ($r.count -gt 0) { return $r.value[0] }
}
function GetItems([int[]]$ids) {
  $all = @()
  for ($i = 0; $i -lt $ids.Count; $i += 200) {
    $chunk = $ids[$i..([Math]::Min($i + 199, $ids.Count - 1))] -join ','
    $all += (Api GET "https://dev.azure.com/$Org/_apis/wit/workitems?ids=$chunk&`$expand=relations&api-version=7.1").value
  }
  $all
}
function ParentId($w) {
  $r = $w.relations | Where-Object rel -eq 'System.LinkTypes.Hierarchy-Reverse' | Select-Object -First 1
  if ($r) { [int]($r.url -split '/')[-1] }
}
function Patch([int]$wid, $ops) {
  if ($ops.Count) { Api PATCH "https://dev.azure.com/$Org/_apis/wit/workitems/$($wid)?api-version=7.1" ([System.Collections.ArrayList]$ops) 'application/json-patch+json' | Out-Null }
}
function Set-Field($ops, $f, $v) { [void]$ops.Add(@{ op = 'add'; path = "/fields/$f"; value = $v }) }
function Descendants([int]$root) {
  $q = @{ query = "SELECT [System.Id] FROM WorkItemLinks WHERE [Source].[System.Id] = $root AND [System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward' MODE (Recursive)" }
  (Api POST "$B/_apis/wit/wiql?api-version=7.1" $q).workItemRelations | ForEach-Object { [int]$_.target.id } | Sort-Object -Unique
}

switch ($Action) {
  'current' {
    $s = CurrentSprint; if (-not $s) { throw "No current sprint for team '$Team'. Run -Action ensure." }
    $s.path
  }
  'ensure' {
    $s = CurrentSprint
    if ($s) { $s.path; break }
    $now = (Get-Date).Date; $start = $now.AddDays(-(([int]$now.DayOfWeek + 6) % 7))
    $yr = $start.Year; $wk = [Globalization.ISOWeek]::GetWeekOfYear($start)
    try { Api GET "$B/_apis/wit/classificationnodes/iterations/$yr`?api-version=7.1" | Out-Null }
    catch { Api POST "$B/_apis/wit/classificationnodes/iterations?api-version=7.1" @{ name = "$yr" } | Out-Null }
    $name = ("Sprint $yr-{0:D2} $Suffix" -f $wk).Trim()
    $n = Api POST "$B/_apis/wit/classificationnodes/iterations/$yr`?api-version=7.1" @{ name = $name; attributes = @{ startDate = $start.ToString('yyyy-MM-ddT00:00:00Z'); finishDate = $start.AddDays($Days - 1).ToString('yyyy-MM-ddT00:00:00Z') } }
    Api POST "$T/_apis/work/teamsettings/iterations?api-version=7.1" @{ id = $n.identifier } | Out-Null
    (CurrentSprint).path
  }
  'assign' {
    $sp = (CurrentSprint).path; if (-not $sp) { throw 'No current sprint; run -Action ensure first.' }
    $ids = [System.Collections.Generic.List[int]]::new(); $Id | ForEach-Object { $ids.Add($_) }
    if ($WithChildren) {
      foreach ($w in GetItems $Id) { $w.relations | Where-Object rel -eq 'System.LinkTypes.Hierarchy-Forward' | ForEach-Object { $ids.Add([int]($_.url -split '/')[-1]) } }
    }
    foreach ($w in GetItems ([int[]]($ids | Sort-Object -Unique))) {
      if ($w.fields.'System.State' -eq 'Removed') { continue }
      if ($w.fields.'System.IterationPath' -ne $sp) {
        $o = [Collections.ArrayList]::new(); Set-Field $o 'System.IterationPath' $sp; Patch $w.id $o
        "AB#$($w.id) -> $sp"
      }
    }
  }
  'move' {
    $sp = (CurrentSprint).path
    foreach ($wid in $Id) {
      $w = (GetItems @($wid))[0]; $o = [Collections.ArrayList]::new()
      if ($State) { Set-Field $o 'System.State' $State }
      if ($Remaining -ge 0) { Set-Field $o 'Microsoft.VSTS.Scheduling.RemainingWork' $Remaining }
      elseif ($State -eq 'Done' -and $w.fields.'System.WorkItemType' -eq 'Task') { Set-Field $o 'Microsoft.VSTS.Scheduling.RemainingWork' 0 }
      if ($Activity) { Set-Field $o 'Microsoft.VSTS.Common.Activity' $Activity }
      if ($sp -and $w.fields.'System.IterationPath' -ne $sp) { Set-Field $o 'System.IterationPath' $sp }
      if ($AddTags -or $RemoveTags) {
        $tags = @(($w.fields.'System.Tags' -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($RemoveTags) { $rm = $RemoveTags -split ';' | ForEach-Object { $_.Trim() }; $tags = @($tags | Where-Object { $_ -notin $rm }) }
        if ($AddTags) { $tags += $AddTags -split ';' | ForEach-Object { $_.Trim() } }
        Set-Field $o 'System.Tags' (($tags | Sort-Object -Unique) -join '; ')
      }
      Patch $wid $o
      if ($Comment) { Api POST "$B/_apis/wit/workItems/$wid/comments?api-version=7.1-preview.4" @{ text = $Comment } | Out-Null }
      "AB#$wid $($w.fields.'System.State') -> $(if($State){$State}else{$w.fields.'System.State'})"
    }
  }
  'audit' {
    $sp = (CurrentSprint).path
    $items = @{}; GetItems (Descendants $Id[0]) | ForEach-Object { $items[[int]$_.id] = $_ }
    $issues = 0
    foreach ($w in $items.Values) {
      $f = $w.fields; $t = $f.'System.WorkItemType'; $s = $f.'System.State'
      $pid_ = ParentId $w; $p = if ($pid_) { $items[$pid_] }
      $ps = if ($p) { $p.fields.'System.State' }
      $o = [Collections.ArrayList]::new(); $why = @()
      if ($t -eq 'Task' -and $s -ne 'Done' -and $ps -eq 'Done') { $why += "Task $s under Done PBI"; Set-Field $o 'System.State' 'Done'; Set-Field $o 'Microsoft.VSTS.Scheduling.RemainingWork' 0 }
      if ($t -eq 'Task' -and $s -in 'In Progress', 'Done' -and $ps -in 'New', 'Approved') {
        $why += "Task $s under $ps PBI AB#$($p.id) (PBI -> Committed)"
        if ($Fix) { $po = [Collections.ArrayList]::new(); Set-Field $po 'System.State' 'Committed'; Patch $p.id $po; $p.fields.'System.State' = 'Committed' }
      }
      $active = $s -in 'Committed', 'In Progress' -or "$($f.'System.Tags')" -match 'agent-working|pr-open|changes-requested' -or $ps -eq 'Committed'
      if ($t -in 'Product Backlog Item', 'Task', 'Bug' -and $s -notin 'Done', 'Removed' -and $sp -and $active -and $f.'System.IterationPath' -ne $sp) {
        $why += "active but not in sprint"; Set-Field $o 'System.IterationPath' $sp
      }
      if ($why) { $issues++; "AB#$($w.id) [$t/$s] $($f.'System.Title'): $($why -join '; ')"; if ($Fix -and $o.Count) { Patch $w.id $o } }
    }
    "audit: $issues issue(s)$(if($Fix){' fixed'}) (sprint: $sp)"
  }
}
