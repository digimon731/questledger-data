<#
Quest Ledger data submissions.

  validate  Checks an issue body and writes a reply for the issue.
  merge     Validates, then adds the records to data/observations.txt and rebuilds data/SharedData.lua.
  build     Only rebuilds data/SharedData.lua from data/observations.txt.

Privacy: only the parsed numbers (quest ID, quest and player level, group size, XP, money, item IDs, faction letter)
are ever stored. Nothing else from the issue is saved, and the reply never quotes the issue text,
so anything a player pasted by mistake is not repeated anywhere.

Works in Windows PowerShell 5.1 and PowerShell 7.
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('validate', 'merge', 'build')][string] $Mode,
    [string] $BodyFile,
    [string] $CommentFile = 'comment.md',
    [string] $ResultFile = 'result.txt',
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$ObservationsPath = Join-Path $Root 'data/observations.txt'
$LuaPath = Join-Path $Root 'data/SharedData.lua'

# Plausibility limits. Anything outside them is rejected.
$MaxQuestID = 999999
$MaxLevel = 63
$MaxGroup = 40
$MaxXP = 200000
$MaxMoney = 10000000      # 1000 gold in copper
$MaxItemID = 9999999
$MaxCount = 1000
$MaxItems = 12
$MaxQuests = 5000         # per submission
$Fields = 'l', 'g', 'x', 'm', 'n', 't', 'r', 'c', 'f'

function Get-Checksum([string[]] $lines) {
    $sum = 0
    foreach ($line in $lines) {
        foreach ($b in [Text.Encoding]::UTF8.GetBytes($line + "`n")) { $sum = ($sum + $b) % 65536 }
    }
    return $sum
}

function Test-Int([string] $value, [int] $min, [int] $max) {
    if ($value -notmatch '^\d{1,9}$') { return $false }
    $n = [long]$value
    return ($n -ge $min -and $n -le $max)
}

# Item list "1234x2+5678" -> canonical string, or $null when invalid.
function ConvertTo-ItemList([string] $value) {
    $parts = $value -split '\+'
    if ($parts.Count -gt $MaxItems) { return $null }
    $out = @()
    foreach ($p in $parts) {
        if ($p -notmatch '^(\d{1,7})(?:x(\d{1,4}))?$') { return $null }
        $id = $Matches[1]; $count = $Matches[2]
        if (-not (Test-Int $id 1 $MaxItemID)) { return $null }
        if ($count) {
            if (-not (Test-Int $count 1 $MaxCount)) { return $null }
            if ([int]$count -gt 1) { $out += ('{0}x{1}' -f [int]$id, [int]$count); continue }
        }
        $out += [string][int]$id
    }
    return ($out -join '+')
}

# One quest line -> ordered dictionary of canonical field values, or $null when invalid.
function ConvertFrom-QuestLine([string] $line) {
    $tokens = $line -split ' '
    if ($tokens[0] -notmatch '^Q(\d{1,6})$') { return $null }
    $id = $Matches[1]
    if (-not (Test-Int $id 1 $MaxQuestID)) { return $null }
    $rec = [ordered]@{ id = [int]$id }
    for ($t = 1; $t -lt $tokens.Count; $t++) {
        if ($tokens[$t] -notmatch '^([lgxmntrcf])=(\S+)$') { return $null }
        $key = $Matches[1]; $value = $Matches[2]
        if ($rec.Contains($key)) { return $null }
        switch ($key) {
            'l' { if (-not (Test-Int $value 1 $MaxLevel)) { return $null }; $rec[$key] = [string][int]$value }
            'g' { if (-not (Test-Int $value 1 $MaxGroup)) { return $null }; $rec[$key] = [string][int]$value }
            'm' { if (-not (Test-Int $value 1 $MaxMoney)) { return $null }; $rec[$key] = [string][int]$value }
            'f' { if ($value -cnotmatch '^(A|H|AH)$') { return $null }; $rec[$key] = $value }
            'n' {
                # Money paid at max level (XP turned into gold), with that level.
                if ($value -notmatch '^(\d{1,8})@(\d{1,2})$') { return $null }
                $money = $Matches[1]; $at = $Matches[2]
                if (-not (Test-Int $money 1 $MaxMoney) -or -not (Test-Int $at 1 $MaxLevel)) { return $null }
                $rec[$key] = '{0}@{1}' -f [int]$money, [int]$at
            }
            't' {
                # A turn-in: player level, XP received, money received (either may be 0).
                if ($value -notmatch '^(\d{1,2}):(\d{1,6}):(\d{1,8})$') { return $null }
                $at = $Matches[1]; $xp = $Matches[2]; $money = $Matches[3]
                if (-not (Test-Int $at 1 $MaxLevel) -or -not (Test-Int $xp 0 $MaxXP) -or -not (Test-Int $money 0 $MaxMoney)) { return $null }
                $rec[$key] = '{0}:{1}:{2}' -f [int]$at, [int]$xp, [int]$money
            }
            'x' {
                if ($value -notmatch '^(\d{1,6})(?:@(\d{1,2}))?$') { return $null }
                $xp = $Matches[1]; $at = $Matches[2]
                if (-not (Test-Int $xp 1 $MaxXP)) { return $null }
                if ($at) {
                    if (-not (Test-Int $at 1 $MaxLevel)) { return $null }
                    $rec[$key] = '{0}@{1}' -f [int]$xp, [int]$at
                } else {
                    $rec[$key] = [string][int]$xp
                }
            }
            default {
                $items = ConvertTo-ItemList $value
                if (-not $items) { return $null }
                $rec[$key] = $items
            }
        }
    }
    # The addon only exports quests with XP, money or rewards.
    if (-not ($rec.Contains('x') -or $rec.Contains('m') -or $rec.Contains('n') -or $rec.Contains('t') -or
              $rec.Contains('r') -or $rec.Contains('c'))) { return $null }
    return $rec
}

# Finds every export block in the text. Returns records, problems and header details.
function Read-Submission([string] $text) {
    $result = [ordered]@{ Records = [ordered]@{}; Problems = New-Object Collections.ArrayList; Exports = 0; Versions = @{}; Clients = @{}; Locales = @{} }
    $lines = ($text -replace "`r", '') -split "`n"
    $inBlock = $false
    $body = $null
    $blockNo = 0
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if ($line -match '^QLX\d') {
            if ($inBlock) { [void]$result.Problems.Add("Export $blockNo has no END line, so the text was probably cut off. It was skipped.") }
            $blockNo++
            if ($line -notmatch '^QLX1 addon=([0-9A-Za-z.\-]{1,20}) client=(\d{1,6}|\?) locale=([A-Za-z]{4}|\?)$') {
                [void]$result.Problems.Add("Export ${blockNo}: the first line is not a Quest Ledger 1.5 export header. Please update Quest Ledger and export again.")
                $inBlock = $false
                continue
            }
            $result.Versions[$Matches[1]] = $true
            $result.Clients[$Matches[2]] = $true
            $result.Locales[$Matches[3]] = $true
            $inBlock = $true
            $body = New-Object Collections.ArrayList
            continue
        }
        if (-not $inBlock) { continue }   # form headings, code fences, the consent tick box
        if ($line -match '^END n=(\d{1,6}) sum=(\d{1,5})$') {
            $inBlock = $false
            $n = [int]$Matches[1]; $sum = [int]$Matches[2]
            if ($n -ne $body.Count -or $sum -ne (Get-Checksum ([string[]]$body.ToArray()))) {
                [void]$result.Problems.Add("Export ${blockNo}: the text was changed or only partly copied (the check line does not match). Please copy it again with Ctrl+C in the game. It was skipped.")
                continue
            }
            if ($body.Count -gt $MaxQuests) {
                [void]$result.Problems.Add("Export ${blockNo}: too many lines. It was skipped.")
                continue
            }
            $result.Exports++
            $lineNo = 0
            foreach ($q in $body) {
                $lineNo++
                $rec = ConvertFrom-QuestLine $q
                if (-not $rec) {
                    [void]$result.Problems.Add("Export ${blockNo}, quest line ${lineNo}: not a valid record. It was skipped.")
                } else {
                    $result.Records[[string]$rec.id] = $rec   # a later line for the same quest wins
                }
            }
            continue
        }
        if ($line -ne '') { [void]$body.Add($line) }
    }
    if ($inBlock) { [void]$result.Problems.Add("Export $blockNo has no END line, so the text was probably cut off. It was skipped.") }
    if ($blockNo -eq 0) { [void]$result.Problems.Add('No Quest Ledger export was found. The text starts with QLX1 and ends with an END line.') }
    return $result
}

# observations.txt: "<questID> <field> <value> <count>" per line, sorted. Each approved submission
# adds one to the count of every value it reports.
function Read-Observations {
    $obs = @{}
    if (-not (Test-Path $ObservationsPath)) { return $obs }
    foreach ($line in [IO.File]::ReadAllLines($ObservationsPath)) {
        if ($line -match '^(\d+) ([lgxmntrcf]) (\S+) (\d+)$') {
            $id = [int]$Matches[1]
            if (-not $obs.ContainsKey($id)) { $obs[$id] = @{} }
            if (-not $obs[$id].ContainsKey($Matches[2])) { $obs[$id][$Matches[2]] = @{} }
            $obs[$id][$Matches[2]][$Matches[3]] = [int]$Matches[4]
        }
    }
    return $obs
}

function Write-Observations($obs) {
    $out = New-Object Collections.ArrayList
    [void]$out.Add('# Quest Ledger shared observations: <quest ID> <field> <value> <times reported>')
    [void]$out.Add('# Fields: l level, g group size, x XP@player level, m money (copper), n money at max level@level,')
    [void]$out.Add('#         t turn-in level:XP:money, r rewards, c reward choices, f faction (A/H)')
    foreach ($id in ($obs.Keys | Sort-Object)) {
        foreach ($f in $Fields) {
            if (-not $obs[$id].ContainsKey($f)) { continue }
            foreach ($v in ($obs[$id][$f].Keys | Sort-Object)) {
                [void]$out.Add(('{0} {1} {2} {3}' -f $id, $f, $v, $obs[$id][$f][$v]))
            }
        }
    }
    $dir = Split-Path -Parent $ObservationsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [IO.File]::WriteAllText($ObservationsPath, (($out -join "`n") + "`n"))
}

function Add-Observations($obs, $records) {
    foreach ($rec in $records.Values) {
        $id = $rec.id
        if (-not $obs.ContainsKey($id)) { $obs[$id] = @{} }
        foreach ($f in $Fields) {
            if (-not $rec.Contains($f)) { continue }
            if ($f -eq 'f') {
                # Count each faction on its own, so Alliance and Horde reports add up.
                $values = @($rec[$f].ToCharArray() | ForEach-Object { [string]$_ })
            } else {
                $values = @($rec[$f])
            }
            if (-not $obs[$id].ContainsKey($f)) { $obs[$id][$f] = @{} }
            foreach ($v in $values) {
                if ($obs[$id][$f].ContainsKey($v)) { $obs[$id][$f][$v]++ } else { $obs[$id][$f][$v] = 1 }
            }
        }
    }
}

# Most reported value; ties go to the smallest number, then the first in text order.
function Get-Winner($votes) {
    $best = $null
    foreach ($v in $votes.Keys) {
        if ($null -eq $best) { $best = $v; continue }
        $a = $votes[$v]; $b = $votes[$best]
        if ($a -gt $b) { $best = $v; continue }
        if ($a -lt $b) { continue }
        $na = 0; $nb = 0
        $numeric = [long]::TryParse($v, [ref]$na) -and [long]::TryParse($best, [ref]$nb)
        if (($numeric -and $na -lt $nb) -or (-not $numeric -and [string]::CompareOrdinal($v, $best) -lt 0)) { $best = $v }
    }
    return $best
}

# XP drops once a player out-levels a quest, so the report from the lowest player level is the full XP.
function Get-XPWinner($votes) {
    $withLevel = @($votes.Keys | Where-Object { $_ -match '@' })
    if ($withLevel.Count -eq 0) { return Get-Winner $votes }
    $lowest = ($withLevel | ForEach-Object { [int]($_ -split '@')[1] } | Measure-Object -Minimum).Minimum
    $subset = @{}
    foreach ($v in $withLevel) { if ([int]($v -split '@')[1] -eq $lowest) { $subset[$v] = $votes[$v] } }
    return Get-Winner $subset
}

function ConvertTo-LuaItems([string] $value) {
    $items = foreach ($p in ($value -split '\+')) {
        $id, $count = $p -split 'x'
        if (-not $count) { $count = 1 }
        '{{link="item:{0}",count={1}}}' -f $id, $count
    }
    return '{' + ($items -join ',') + '}'
}

function Write-Lua($obs) {
    $out = New-Object Collections.ArrayList
    [void]$out.Add('-- Quest Ledger shared quest data, generated from data/observations.txt.')
    [void]$out.Add('-- Do not edit by hand: changes are overwritten by the next submission.')
    [void]$out.Add('local _, ns = ...')
    [void]$out.Add('ns.SharedQuests = {')
    foreach ($id in ($obs.Keys | Sort-Object)) {
        $o = $obs[$id]
        $parts = @()
        if ($o.ContainsKey('l')) { $parts += 'lvl=' + (Get-Winner $o['l']) }
        if ($o.ContainsKey('g')) { $parts += 'grp=' + (Get-Winner $o['g']) }
        if ($o.ContainsKey('x')) {
            $xp, $at = (Get-XPWinner $o['x']) -split '@'
            $parts += 'xp=' + $xp
            if ($at) { $parts += 'xpLvl=' + $at }
        }
        if ($o.ContainsKey('m')) { $parts += 'money=' + (Get-Winner $o['m']) }
        if ($o.ContainsKey('n')) {
            # Reports from the highest max level win (the cap could rise), then the most reported.
            $top = ($o['n'].Keys | ForEach-Object { [int]($_ -split '@')[1] } | Measure-Object -Maximum).Maximum
            $subset = @{}
            foreach ($v in $o['n'].Keys) { if ([int]($v -split '@')[1] -eq $top) { $subset[$v] = $o['n'][$v] } }
            $money, $at = (Get-Winner $subset) -split '@'
            $parts += 'moneyMax=' + $money
            $parts += 'moneyMaxLvl=' + $at
        }
        if ($o.ContainsKey('r')) { $parts += 'rew=' + (ConvertTo-LuaItems (Get-Winner $o['r'])) }
        if ($o.ContainsKey('c')) { $parts += 'choice=' + (ConvertTo-LuaItems (Get-Winner $o['c'])) }
        if ($o.ContainsKey('f')) {
            $fac = @()
            if ($o['f'].ContainsKey('A')) { $fac += 'Alliance=true' }
            if ($o['f'].ContainsKey('H')) { $fac += 'Horde=true' }
            $parts += 'fac={' + ($fac -join ',') + '}'
        }
        [void]$out.Add(('[{0}]={{{1}}},' -f $id, ($parts -join ',')))
    }
    [void]$out.Add('}')
    [IO.File]::WriteAllText($LuaPath, (($out -join "`n") + "`n"))
}

# Money checks for the maintainer, above all for max level, where XP is paid as gold:
#   a turn-in below max level pays the quest's own money (m),
#   a turn-in at max level pays the max-level money (n), which is at least m,
#   and (n - m) / XP at max level is a gold-per-XP rate that should be alike for every quest.
# Returns warnings and the rates found.
$MaxPlayerLevel = 60
function Get-XPAtLevel([int] $fullXP, [int] $questLevel, [int] $playerLevel) {
    $diff = $playerLevel - $questLevel
    if ($diff -le 5) { return $fullXP }
    $factor = @{ 6 = 0.8; 7 = 0.6; 8 = 0.4; 9 = 0.2 }[$diff]
    if ($null -eq $factor) { $factor = 0.1 }
    return [math]::Floor($fullXP * $factor / 5 + 0.5) * 5
}

function Get-MoneyChecks($records) {
    $warnings = New-Object Collections.ArrayList
    $rates = New-Object Collections.ArrayList
    foreach ($rec in $records.Values) {
        $id = $rec.id
        $m = $null; $n = $null; $nAt = $null
        if ($rec.Contains('m')) { $m = [long]$rec['m'] }
        if ($rec.Contains('n')) { $parts = $rec['n'] -split '@'; $n = [long]$parts[0]; $nAt = [int]$parts[1] }
        if ($null -ne $n -and $null -ne $m -and $n -lt $m) {
            [void]$warnings.Add("Quest ${id}: money at max level ($n) is lower than the quest's own money ($m).")
        }
        if ($rec.Contains('t')) {
            $parts = $rec['t'] -split ':'
            $tLevel = [int]$parts[0]; $tMoney = [long]$parts[2]
            if ($null -ne $nAt -and $tLevel -eq $nAt -and $tMoney -ne $n) {
                [void]$warnings.Add("Quest ${id}: the turn-in at level $tLevel paid $tMoney, but the max-level money is $n.")
            }
            if ($tLevel -lt $MaxPlayerLevel -and $null -ne $m -and $tMoney -gt 0 -and $tMoney -ne $m) {
                [void]$warnings.Add("Quest ${id}: the turn-in at level $tLevel paid $tMoney, but the quest's own money is $m.")
            }
            if ($tLevel -ge $MaxPlayerLevel -and $null -eq $n -and $tMoney -gt 0) {
                [void]$warnings.Add("Quest ${id}: a turn-in at level $tLevel has no max-level money.")
            }
        }
        # The rate needs the full XP: an XP report from no more than 5 levels above the quest.
        if ($null -ne $n -and $rec.Contains('x') -and $rec.Contains('l')) {
            $parts = $rec['x'] -split '@'
            $questLevel = [int]$rec['l']
            if ($parts.Count -eq 2 -and [int]$parts[1] -le $questLevel + 5) {
                $xpAtMax = Get-XPAtLevel ([int]$parts[0]) $questLevel $nAt
                if ($xpAtMax -ge 100) {
                    $rate = ($n - $(if ($null -ne $m) { $m } else { 0 })) / $xpAtMax
                    [void]$rates.Add($rate)
                    if ($rate -le 0 -or $rate -gt 50) {
                        [void]$warnings.Add([string]::Format([Globalization.CultureInfo]::InvariantCulture, "Quest {0}: max-level money gives {1:0.0} copper per XP, which is implausible.", $id, $rate))
                    }
                }
            }
        }
    }
    return @{ Warnings = $warnings; Rates = $rates }
}

function Write-Reply([string[]] $lines, [string] $result) {
    [IO.File]::WriteAllText($CommentFile, (($lines -join "`n") + "`n"))
    [IO.File]::WriteAllText($ResultFile, $result)
}

if ($Mode -eq 'build') {
    Write-Lua (Read-Observations)
    Write-Host "Rebuilt $LuaPath"
    return
}

if (-not $BodyFile -or -not (Test-Path $BodyFile)) { throw 'BodyFile is required for validate and merge.' }
$sub = Read-Submission ([IO.File]::ReadAllText($BodyFile))
$count = $sub.Records.Count
$noun = if ($count -eq 1) { 'quest record' } else { 'quest records' }
$details = 'Quest Ledger {0}, client {1}, {2}' -f (($sub.Versions.Keys | Sort-Object) -join '/'), (($sub.Clients.Keys | Sort-Object) -join '/'), (($sub.Locales.Keys | Sort-Object) -join '/')

$reply = New-Object Collections.ArrayList
$problems = @($sub.Problems | Select-Object -First 20)
$more = $sub.Problems.Count - $problems.Count

if ($count -eq 0) {
    [void]$reply.Add('**No quest records could be read from this submission.**')
    [void]$reply.Add('')
    foreach ($p in $problems) { [void]$reply.Add("- $p") }
    if ($more -gt 0) { [void]$reply.Add("- ...and $more more.") }
    [void]$reply.Add('')
    [void]$reply.Add('In game, click **Share data** in the Quest Ledger window (or type `/ql export all`), press Ctrl+C, then edit this issue and paste the text again. It is checked again automatically.')
    Write-Reply $reply 'invalid'
    Write-Host "Invalid: $($sub.Problems.Count) problems"
    return
}

if ($Mode -eq 'validate') {
    [void]$reply.Add("**Thank you!** This submission has **$count** valid $noun ($details).")
    [void]$reply.Add('')
    [void]$reply.Add('A maintainer will review it and add it to the shared database. Only the quest numbers are stored; nothing else from this issue is saved.')
    $withMoney = @($sub.Records.Values | Where-Object { $_.Contains('m') -or $_.Contains('n') -or $_.Contains('t') }).Count
    if ($withMoney -gt 0) {
        $checks = Get-MoneyChecks $sub.Records
        [void]$reply.Add('')
        [void]$reply.Add("**Money checks** ($withMoney quests with money):")
        if ($checks.Rates.Count -gt 0) {
            $sorted = @($checks.Rates | Sort-Object)
            $median = $sorted[[math]::Floor(($sorted.Count - 1) / 2)]
            [void]$reply.Add([string]::Format([Globalization.CultureInfo]::InvariantCulture, "- Max level: about {0:0.0} copper per XP, from {1} quests (range {2:0.0} to {3:0.0}).", $median, $sorted.Count, $sorted[0], $sorted[-1]))
        }
        if ($checks.Warnings.Count -eq 0) {
            [void]$reply.Add('- The money values agree with each other.')
        } else {
            foreach ($w in @($checks.Warnings | Select-Object -First 15)) { [void]$reply.Add("- $w") }
            if ($checks.Warnings.Count -gt 15) { [void]$reply.Add("- ...and $($checks.Warnings.Count - 15) more.") }
        }
    }
    if ($problems.Count -gt 0) {
        [void]$reply.Add('')
        [void]$reply.Add('Some parts were skipped:')
        foreach ($p in $problems) { [void]$reply.Add("- $p") }
        if ($more -gt 0) { [void]$reply.Add("- ...and $more more.") }
    }
    Write-Reply $reply 'valid'
    Write-Host "Valid: $count records, $($sub.Problems.Count) problems"
    return
}

# merge
$obs = Read-Observations
$new = @($sub.Records.Keys | Where-Object { -not $obs.ContainsKey([int]$_) }).Count
Add-Observations $obs $sub.Records
Write-Observations $obs
Write-Lua $obs
[void]$reply.Add("**Added to the shared database:** $count $noun, $new of them new. Thank you for contributing!")
[void]$reply.Add('')
[void]$reply.Add('They will be included in the next Quest Ledger release.')
Write-Reply $reply 'merged'
Write-Host "Merged: $count records, $new new"
