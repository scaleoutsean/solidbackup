#!/usr/bin/env pwsh

# Original author: @scaleoutSean
#
# Copyright (c) 2021 NetApp, Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

$ErrorActionPreference = "Stop"

Import-Module SolidFire.Core
Import-Module Logging

$global:configfile = Import-PowerShellDataFile -Path config/config.psd1
$global:Job        = $null

# SolidFire credentials are read from config.psd1 here; replace with other mechanism if you don't want to have them hard-coded in config.psd1
[SolidFire.Core.Objects.SFConnection]$prod = (Connect-SFCluster $configfile.Backends.prod.mvip -username $configfile.Backends.prod.username -password $configfile.Backends.prod.password)

Set-LoggingDefaultLevel -Level 'INFO'
Set-LoggingDefaultFormat -Format '[%{timestamp:+yyyy/MM/dd HH:mm:ss.fff}]'
Add-LoggingTarget -Name Console -Configuration @{Level = 'INFO'; Format = '[%{level:-7}] %{message}'}
Add-LoggingTarget -Name File -Configuration @{Level = 'INFO'; Format = '[%{timestamp:+%Y-%m-%d %T%Z}] [%{level:-7}] %{message}'; Path = 'logs/solidsync_%{+%Y%m%d}.txt'}

# SolidFire QoS Id used by SolidBackup for Tgt (Clones)
$SfQosId      = 4
# SolidFire storage account for SolidBackup and access to Target volumes by backup scripts
$SfAcctId     = 23
# SolidFire maximum age (in hours) for a snapshot named "solidbackup*" to be automatically used as source in CopyVolume
$SbMaxSnapAge = 6
$jfail    = New-Object System.Collections.ArrayList($null)
$jing     = New-Object System.Collections.ArrayList($null)
$js       = New-Object System.Collections.ArrayList($null)
$jasid    = New-Object System.Collections.ArrayList($null)
$jok      = New-Object System.Collections.ArrayList($null)
$jokay    = New-Object System.Collections.ArrayList($null)
$tstartu  = [DateTime](Get-Date).ToUniversalTime()

$SfCap    = (Get-SFClusterCapacity -SFConnection $prod)
$SfCapMdFullness = [MATH]::Round(($SfCap.UsedMetadataSpace / $SfCap.MaxUsedMetadataSpace),3)
Write-Log -Level INFO -Message "SolidFire Metadata Capacity Fullness ratio:" $SfCapMdFullness 
if ($SfCapMdFullness -gt 0.4) {
    Write-Log -Level WARNING -Message "Cluster metadata fullness ratio over 0.4: {0}" -Arguments $SfCapMdFullness
    Write-Host "With less than half metadata capacity free, you MUST ensure you have enough free space to run this script" -ForegroundColor Red
    Write-Error -Message "Stopped due to high metadata capacity utilization"
    Write-Log -Level ERROR -Message "Stopped due to high metadata full ratio {0}" -Arguments $SfCapMdFullness
} else {
    Write-Log -Level DEBUG -Message "Cluster metadata fullness ratio is below 0.4: {0}" -Arguments $SfCapMdFullness
}

function GetSbLatestSnapshot {
    Param
    (
         [Parameter(Mandatory=$true, Position=0)]
         [Int64]$SrcId
    )
    $SrcSnap = (Get-SFSnapshot -VolumeID $SrcId -SFConnection $prod | Select-Object -Property SnapshotID, Name, CreateTime | Where-Object -Property "Name" -like "solidbackup*" | Sort-Object -Property CreateTime -Descending | Select-Object -First 1)
    if ($SrcSnapId =  $SrcSnap.SnapshotID) {
        [DateTime]$SrcSnapTime =  $SrcSnap.CreateTime
        if (((Get-Date) - $SrcSnapTime).Hours -gt $SbMaxSnapAge) {
            Write-Log -Level WARNING -Message "Snapshot {0} for SrcId {1} exists, `
                but snapshot is old: {2}. Skipping in favor of on-demand snapshot..." -Arguments $SrcSnap,$SrcId,$SrcSnapTime
            return 0
        } else {
            Write-Log -Level INFO -Message "Snapshot {0} for SrcId {1} returned" -Arguments $SrcSnapId,$SrcId
            return [Int64]$SrcSnapId
        }
    } else {
            Write-Log -Level INFO -Message "Snapshot for SrcId {0} not found" -Arguments $SrcId
            return 0
    }
}

function CopySbSrcToTgt {
    Param
    (
         [Parameter(Mandatory=$true, Position=0)]
         [Int64]$SrcId,
         [Parameter(Mandatory=$true, Position=1)]
         [Int64]$TgtId,
         [Parameter(Mandatory=$false, Position=2)]
         [Int64]$SrcSnapId
    )
    Write-Log -Level INFO -Message "Using Src Id {0} and Tgt Id {1}:" -Arguments $SrcId,$TgtId
    if ($null -eq $SrcSnapId) {
        Write-Log -Level DEBUG -Message "Cloning SrcId {0} with temp ad-hoc snapshot" -Arguments $SrcId
        $ja = Copy-SFVolume -VolumeID $SrcId -DstVolumeID $TgtId
    } else {
        Write-Log -Level DEBUG -Message "Cloning SrcId {0} from (latest) Snapshot Id {1}" -Arguments $SrcId, $SrcSnapId
        $ja = Copy-SFVolume -VolumeID $SrcId -DstVolumeID $TgtId -SnapshotID $SrcSnapId
    }
    $null = Get-SFASyncResult -SFConnection $prod $ja.AsyncHandle -KeepResult
    Write-Log -Level DEBUG -Message 'AsyncHandle: {0}' -Arguments $ja.AsyncHandle -Body @{SrcId="$SrcId"; TgtId="$TgtId"; AsyncHandle="$ja.AsyncHandle"}
    [void]($jasid.Add($ja.AsyncHandle))
}

function GetLastEventId {
    $ev  = Get-SFEvent -MaxEvents 1 -SFConnection $prod
    [int64]$evid= $ev.EventID
    Write-Log -Level INFO "GetLastEventId function returning Event ID: {0}" $evid
    return $evid
}

function GetFailedCloneJobs {
    foreach ($job in $jasid) {
        Write-Log -Level DEBUG -Message "Checking clone result for async job {0}" -Arguments $job
        $r = (Get-SFASyncResult -SFConnection $prod $job -KeepResult)
        if (($r.status) -eq "complete") {
            Write-Log -Level DEBUG -Message "Successful job for volume {0}" -Arguments ($r.result.volumeID)
        } elseif ($r.status -eq "running") {
            Write-Log -Level DEBUG -Message "VolId {0}, current status {1}, time {2}" `
                -Arguments $r.details.volumeID,$r.status,$r.lastUpdateTime
            [void]($jing.Add($r.details.volumeID))
        } else {
            Write-Log -Level DEBUG -Message "VolId {0}, status {1}, time {2}" `
                -Arguments $r.details.volumeID,$r.status,$r.lastUpdateTime
            [void]($jfail.Add($r.details.volumeID))
        }
    }
    return $jfail
}

function GetResultsOfCloneJobs {
    $endeventid = GetLastEventId
    Write-Log -Level DEBUG -Message "Got last event ID: {0}" -Arguments $endeventid
    $evt         = Get-SFEvent -SFConnection $prod -StartEventID $starteventid -EndEventID $endeventid | Sort-Object -Property EventID
    foreach ($e in $evt) { 
        if ($e.EventInfoType -eq "cloneEvent" -and $e.Message -eq "Clone volume succeeded") {
        $jsrcvid = $e.Details.srcVolumeID
        Write-Log -Level DEBUG -Message "Found successfully cloned Src Volume Id {0}" -Arguments $jsrcvid
        [void]($jokay.Add($jsrcvid))
        foreach ($j in $jokay) {
            Write-Log -Level DEBUG "Job in still in progress. Job: {0}" -Arguments $j
        }
            Write-Log -Level DEBUG -Message "Added Src Volume ID {0} to array of successful jobs" -Arguments $jsrcvid
        }
    }
    Write-Log -Level DEBUG -Message "Returning array of successfully completed clone jobs with {0} items" -Arguments $jokay.Length
    return $jokay
}

function SetSfAcctQoSPolicyID($TgtId) {
    Try {
        $null = (Set-SFVolume -VolumeID $TgtId -QoSPolicyID $sfqosid -AccountID $sfacctid -Confirm:$False)
        Write-Log -Level DEBUG -Message "Set QoS Policy ID {0} on Volume ID: {1}" `
            -Arguments $sfqosid,$TgtId
    } Catch {
        Write-Log -Level ERROR -Message "Failed to set QoS Policy ID {0} on Volume ID: {1}" `
            -Arguments $sfqosid,$TgtId
    } Finally {
        Write-Log -Level INFO -Message "Continuing after trying to apply QoS Policy {0} to Volume ID: {1}" `
            -Arguments $sfqosid,$TgtId
    } 
}

function GetSbTimeStats {
    $tstopu  = [DateTime](Get-Date).ToUniversalTime()
    Write-Log -Level DEBUG "Jobs started at {0}" -Arguments $tstartu
    Write-Log -Level DEBUG "Jobs completed at {0}" -Arguments $tstopu
    Write-Log -Level DEBUG "Sync jobs starting at {0}" -Arguments $tstopu
    $ttaken  = [int32]($tstopu - $tstartu).TotalSeconds
    Write-Log -Level INFO "Time taken (in seconds) {0}" -Arguments $ttaken
}

function StartSbSyncSleep($longtimesrcid) {
    $running = $True
    while ($running) {
        $syncjobs = Invoke-SFApi -Method ListSyncJobs
        $res = Compare-Object -ReferenceObject $syncjobs.syncJobs.srcVolumeID -DifferenceObject $c -PassThru 
        if ($null -eq $res ) {
            Write-Log -Level DEBUG -Message "Sync job on volume Src Id {0} no longer running. Resuming..." -Arguments: $longtimesrcid
            $running = $False
        } else {
            Write-Log -Level INFO -Message "Sync job on volume Src Id {0} is still running. Sleep 10 seconds" -Arguments: $longtimesrcid
        }
    }
}

function TestSfVolume {
    Param
    (
         [Parameter(Mandatory=$true, Position=0)]
         [Int64]$VolId
    )
    Write-Log -Level INFO "Checking if Volume Id {0} exists..." -Arguments $VolId
    try {
        $r = Get-SFVolume -VolumeID $VolId -SFConnection $prod
    } catch {
        return $False
    }
    if ($r.VolumeID -ne $VolId ) {
        Write-Error -Message "Nothing returned, volume does not exist!"
    } else {
        return $True
    }
}

$starteventid  = (GetLastEventId + 1)
Write-Log -Level INFO -Message "Start Event ID: {0}" -Arguments $starteventid

function GetSbConfig {
    [array]$SyncJobList = @()
    foreach ($ns in $configfile.Namespaces.Keys) {
        foreach ($app in $configfile.Namespaces.$ns.Keys) {
            [int64]$SrcId      = ($configfile.Namespaces.$ns.$app['SrcId'])
            [int64]$TgtId      = ($configfile.Namespaces.$ns.$app['TgtId'])
            [int64]$SrcSnapId  = GetSbLatestSnapshot -SrcId $SrcId
            $SyncJob    = [ordered]@{
                'SrcId'        = $SrcId
                'TgtId'        = $TgtId
                'SrcSnapId'    = $SrcSnapId
            }
            $SyncJobList += $SyncJob
        }
    }
    return $SyncJobList
}

$Job = GetSbConfig

foreach ($j in $Job) {
    if (TestSfVolume -VolId $j.SrcId) {
        if (TestSfVolume -VolId $j.TgtId) {
        }
    } else  {
        Write-Host "At least one volume does not exist. Please check your config file. Exiting..."
        Write-Error -Message "Missing one or both volumes in a pair"
    }
    CopySbSrcToTgt -SrcId $j.SrcId -TgtId $j.TgtId -SrcSnapId $j.SrcSnapId    
}

$endeventid = GetLastEventId

Write-Log -Level INFO -Message "End Event ID: {0}" -Arguments $endeventid

$jfail = $null 
if ($jfail.Count -gt 0) {
    Write-Log -Level ERROR -Message "Jobs failed running: {0}" -Arguments $jfail
} else { 
    Write-Log -Level INFO -Message "No jobs failed, but some may still be running"
}

$jok = GetResultsOfCloneJobs

GetSbTimeStats

Write-Log -Level DEBUG -Message "Successfully completed clone job items:" $jok.Length
Write-Log -Level DEBUG -Message "Successfully cloned volume IDs {0}" -Arguments ($jok -join ',')
Write-Log -Level DEBUG -Message "One more check as some volume copy jobs may still be running"
$res   = Invoke-SFApi -Method ListSyncJobs
if ($res.syncJobs.Count -gt 0) {
    Write-Log -Level DEBUG -Message "Found running copy voume jobs"
    $r = 0; $longtime = 0; $longtimesrcid
    foreach ($r in $res.syncJobs) {
        if ($js -NotContains $res.syncJobs[$r].srcVolumeID) {
            Write-Log -Level INFO -Message "Ignoring sync job on unrelated volume Src Id {0}" -Arguments ($res.syncJobs[$r].srcVolumeID)
        } else {
            Write-Log -Level DEBUG -Message "Checking remaining time for remaining running sync job(s)"
            $w = $res.syncJobs[$r].remainingTime
            if ($w -gt $longtime) { $longtime = $w; $longtimesrcid = $res.syncJobs[$r].srcVolumeID }
            Write-Log -Level INFO "Longest estimated remaining time {0} (s) for SrcId {1}" -Arguments $res.syncJobs[$r].remainingTime,$res.syncJobs[$r].srcVolumeID
        }
    $r += 1
    }
    Write-Log -Level INFO "We will check every 10s but it can take {0} seconds to finish" -Arguments ([MATH]::Round($longtime,0))
    StartSbSyncSleep $longtimesrcid
} else {
    Write-Log -Level INFO -Message "No volume sync jobs found running"
}

Wait-Logging
