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

# Which FS are OK for file-based backup
$FsTypeOk = @("ext2","ext3","ext4","xfs")
# Where to mount Target (Clone) volumes for File backup
$MountRoot= "/mnt/"
# Used as full path to backup command
$restic   = "/home/sean/bin/restic"

# SolidFire credentials are read from config.psd1 here; replace with other mechanism if you don't want to have them hard-coded in config.psd1
[SolidFire.Core.Objects.SFConnection]$prod = (Connect-SFCluster $configfile.Backends.prod.mvip -username $configfile.Backends.prod.username -password $configfile.Backends.prod.password)

$SfCluster  = Get-SFClusterInfo
$SfClusterId= $SfCluster.UniqueID
$SfSvip     = $sfcluster.Svip

function GetSbIscsiIqn {
    Param (
        [Parameter(Mandatory=$true)][array]$j
    )
    [array]$result = @()
    Start-Sleep 1

    try { $TgtName = (Get-SFVolume -VolumeId $j.TgtId -SFConnection $prod).Name
        Write-Log -Level DEBUG -Message "Volume Name for TgtId {0} is {1}" -Arguments $j.TgtId, $TgtName
        [string]$TgtIqn = "iqn.2010-01.com.solidfire:" + $SfClusterId + "." + $TgtName + "." + $j.TgtId
        Write-Log -Level DEBUG -Message "Device Name for TgtId {0} is {1}" -Arguments $j.TgtId, $TgtIqn
    } catch {
        Write-Log -Level ERROR -Message "Volume Id {0} cannot be found, returning null" -Arguments $j.TgtId
    }
    $TgtDevByPath = "/dev/disk/by-path/ip-" + $SfSvip + ":3260-iscsi-" + $TgtIqn + "-lun-0"
    Write-Log -Level DEBUG -Message "Target Device by Path w/o Partition: {0}" -Arguments $TgtDevByPath
    Write-Log -Level DEBUG -Message "Target Iqn: {0}" -Arguments $TgtIqn
    $result = @( $TgtName, $TgtIqn, $TgtDevByPath)
    return $result
}

function ConnectSbIscsiDevice {
    Param (
         [Parameter(Mandatory=$true, Position=0)]
         [int64]$TgtId,
         [Parameter(Mandatory=$true, Position=1)]
         [string]$TgtIqn
    )

    Write-Log -Level INFO -Message "Connecting to TgtId {0}" -Argument $TgtId
    $SbIscsiParams   = [PSCustomObject]@{
            login  = 'yes'
            target = $TgtIqn
    }
    $IscsiLoginFile = "01-iscsi-login-" + $TgtId + ".json"
    $SbIscsiParams | ConvertTo-JSON | Out-File ansible/$IscsiLoginFile
     
    Write-Log -Level INFO -Message "Running Ansible to login to obtained IQN {0}" -Arguments $SbIqn
    ansible-playbook 01-iscsi-login.yaml -e "login=yes" -e "@$IscsiLoginFile"
}

function NewSbFsMount {
    Param (
         [Parameter(Mandatory=$true, Position=0)]
         [int64]$SrcId,
         [Parameter(Mandatory=$true, Position=1)]
         [int64]$TgtId,
         [Parameter(Mandatory=$true, Position=2)]
         [int64]$Part,
         [Parameter(Mandatory=$true, Position=3)]
         [string]$FsType,
         [Parameter(Mandatory=$true, Position=4)]
         [string]$TgtIqn,
         [Parameter(Mandatory=$true, Position=5)]
         [string]$TgtDevByPath
    )

    Write-Log -Level DEBUG -Message "Device by Path w/o Partition: {0}" -Arguments $TgtDevByPath
    if ($Part -eq 0) {
        Write-Log -Level DEBUG -Message "Partition {0} specified for TgtId {1} - appending partition suffix to device" -Arguments $Part, $TgtId
        Write-Log -Level DEBUG -Message "Added partition {0} to device-by-path" -Arguments $Part
        Write-Log -Level DEBUG -Message "Device by Path without Partition: {0}" -Arguments $TgtDevbyPath
    } elseif ($Part -eq 1) {
        $TgtDevByPath = $TgtDevByPath + "-part" + $Part
    } else {
        Write-Log -Level DEBUG -Message "No partition specified for TgtId {0}, retaining Disk-By-Path value w/o partition" -Arguments $TgtId
    }
    Write-Log -Level INFO -Message "Mount: Disk-by-Path: {0}, Target Id: {1}, Partition: {2}, FS: {3}" -Arguments $TgtDevByPath, $TgtId, $Part, $FsType
    if ($FsTypeOk -contains $FsType) {
        Write-Log -Level INFO -Message "Supported filesystem type {0} specified" -Arguments $FsType
        $MountPath = $MountRoot + [String]$SrcId
        Write-Log -Level INFO -Message "Checking if mount path {0} exists" -Arguments $MountPath
        if (!(Test-Path $MountPath)) {
            try {
                Write-Log -Level INFO -Message "Directory {0} is missing; attempt to create it" -Arguments $MountPath
                $command = "New-Item -ItemType Directory -Path $MountRoot -Name $SrcId"
                Write-Log -Level INFO -Message "Command is {0}" -Arguments $command
                sudo pwsh -Command $command
            } catch  [system.exception] {
                Write-Host  "Error: " $_.Exception.Message
                Write-Error -Message "Mount path is missing, but cannot be created"
            }
        }
        Write-Log -Level INFO -Message "Using mountpath {0}" -Arguments $MountPath
        Start-Sleep 1
        $FsMountParams  = [PSCustomObject]@{
            opts  = 'ro'
            state = 'mounted'
            src   = $TgtDevByPath
            fstype= $FsType
            path  = $MountPath
        }
        $PosixMountFile = "02-posix-mount-" + [string]$SrcId + ".json"
        $FsMountParams | ConvertTo-JSON | Out-File ansible/$PosixMountFile
        Try {
            Write-Log -Level DEBUG -Message "Running Ansible POSIX mount with: state mounted, TgtId {0}, FStype {1} and TgtDevByPath {2}"  -Arguments $TgtId,$FsType, $TgtDevByPath
            ansible-playbook 02-fs-mount.yaml --extra-vars "@$PosixMountFile"
            Start-Sleep 1
        } Catch {
            Write-Log -Level WARNING -Message "Ansible POSIX mount may have failed - please check Ansible log"
        }
    } else {
        Write-Log -Level WARNING -Message "Skipping Mount Attempt: unknown or unsupported filesystem type {0} specified for TgtId {1}" -Arguments $FsType, $TgtId
        Write-Error -Message "Unknown or unsupported filesystem type specified for TgtId:" $TgtId
    }
}

function NewSbBackupConfig {
    if (Test-Path .\restic-image-backup.sh) { 
        $null = Remove-Item "restic-image-backup.sh"
    }
    if (Test-Path .\backup.txt) { 
        $null = Remove-Item "backup.txt"
    }
    # File for (1) simple Bash based backup script and (2) all stand-alone Restic backup commands
    New-Item "restic-image-backup.sh"
    New-Item "backup.txt"
    Add-Content .\restic-image-backup.sh "#!/bin/bash"
    Add-Content .\restic-image-backup.sh "source config/r.rc"
}

function NewSbBackupCommand {
    Param (
         [Parameter(Mandatory=$true, Position=0)]
         [int64]$SrcId,
         [Parameter(Mandatory=$true, Position=1)]
         [int64]$TgtId,
         [Parameter(Mandatory=$true, Position=2)]
         [int]$Part,
         [Parameter(Mandatory=$true, Position=3)]
         [string]$TgtIqn,
         [Parameter(Mandatory=$true, Position=4)]
         [string]$TgtDevByPath,
         [Parameter(Mandatory=$true, Position=5)]
         [string]$BkpType
    )
    if ($BkpType.ToLower() -eq "image") {
        $imgcmd1 = "sudo dd if=$TgtDevByPath bs=256kB status=none | gzip | "
        $imgcmd2 = "$restic --json --verbose backup --tag src-id-$SrcId --tag tgt-id-$TgtId "
        $imgcmd3 = "--stdin --stdin-filename "
        $imgcmd4 = $TgtIqn.Split(":",2)[1] + ".gz"
        $bkpcmd  = $imgcmd1 + $imgcmd2 + $imgcmd3 + $imgcmd4
    } elseif ($BkpType.ToLower() -eq "file") {
        $bkpcmd  = $restic + " --json --verbose backup --tag src-id-" + $SrcId + " " + "--tag tgt-id-" + $TgtId + " -e lost+found " + "/mnt/" + $SrcId
    } else {
        Write-Error -Message "Unknown backup type specified: $BkpType"
    }
    try { 
        Add-Content .\restic-image-backup.sh $bkpcmd
        Add-Content .\backup.txt $bkpcmd
    } catch [system.exception] {
        Write-Host  "Error: " $_.Exception.Message
        Write-Error -Message "Cannot write to backup script files"
    }
}

function GetSbConfig {
    [array]$BkpJobList = @()
    foreach ($ns in $configfile.Namespaces.Keys) {
        foreach ($app in $configfile.Namespaces.$ns.Keys) {
            [int64]$SrcId      = ($configfile.Namespaces.$ns.$app['SrcId'])
            [int64]$TgtId      = ($configfile.Namespaces.$ns.$app['TgtId'])
            [int]$Part         = ($configfile.Namespaces.$ns.$app['Part'])
            [string]$FsType    = ($configfile.Namespaces.$ns.$app['FsType'])
            [string]$BkpType   = ($configfile.Namespaces.$ns.$app['BkpType'])
            $BkpJob    = [ordered]@{
                'Ns'           = $ns
                'App'          = $app
                'SrcId'        = $SrcId
                'TgtId'        = $TgtId
                'Part'         = $Part
                'FsType'       = $FsType
                'BkpType'      = $BkpType
            }
            $Job = New-Object -TypeName psobject -Property $BkpJob
            $BkpJobList += $Job
        }
    }
    return $BkpJobList
}

$Job = GetSbConfig

Clear-Host
NewSbBackupConfig
foreach ($j in $Job) {
    Write-Host "NEW VOLUME PAIR: Working on Source and Target (clone) volumes:" $j.SrcId, $j.TgtId -ForegroundColor Black -BackgroundColor DarkRed
    Write-Host "Step 1: get Target (clone) Volume Name and Iqn for Volume Id" $j.TgtId -ForegroundColor Green 
    Start-Sleep 1
    $result = GetSbIscsiIqn $j
    $j | Add-Member -NotePropertyMembers @{ TgtName= $result[0]; TgtIqn = [string]$result[1]; TgtDevByPath = [string]$result[2] }
    Write-Host "Step 2: get iSCSI connection parameters for Target (clone) Volume Id" $j.TgtId -ForegroundColor Green
    Start-Sleep 1
    ConnectSbIscsiDevice -TgtId $j.TgtId -TgtIqn $j.TgtIqn
    Write-Host "Step 3: Mount FS for Target (clone) Volume Id" $j.TgtId -ForegroundColor Green
    if ($j.BkpType -eq "image") {
        Write-Host "Image type specified - skipping FS mount for" $j.SrcId, $j.TgtId
    } else {
        NewSbFsMount -SrcId $j.SrcId -TgtId $j.TgtId -Part $j.Part -FsType $j.FsType -TgtIqn $j.TgtIqn -TgtDevByPath $j.TgtDevByPath
    }
    Write-Host "Step 4: write out individual backup job commands" -ForegroundColor Green 
    Start-Sleep 1
    try {
        NewSbBackupCommand -SrcId $j.SrcId -TgtId $j.TgtId -Part $j.Part -TgtIqn $j.TgtIqn -TgtDevByPath $j.TgtDevByPath -BkpType $j.BkpType
    } catch [system.exception] {
	Write-Host  "Error: " $_.Exception.Message
    }
}
