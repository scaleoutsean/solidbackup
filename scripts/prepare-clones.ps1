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

Import-Module SolidFire.Core
# Change this for your environment
$null = Connect-SFCluster 192.168.1.30 -username admin -password admin

function SbNewClone {
    Param (
        [Parameter(Mandatory=$true, Position=0)]
        [int64]$SrcId,
        [Parameter(Mandatory=$true, Position=1)]
        [int64]$SbAccountId,
        [Parameter(Mandatory=$true, Position=2)]
        [int64]$SbQoSPolicyId,
        [Parameter(Mandatory=$true, Position=3)]
        [int64]$SbVagId
    )
    $VolumeOrig = (Get-SFVolume -VolumeID $SrcId)
    $VolumeCloneName = "solidbackup-" + $VolumeOrig.Name
    $VolumeClone = (New-SFClone -Name $VolumeCloneName -VolumeID $SrcId -NewAccountID $SbAccountId)

    $null = Add-SFVolumeToVolumeAccessGroup -VolumeID ($VolumeClone).VolumeID -VolumeAccessGroupID $SbVagId
    $null = Set-SFVolume -VolumeID ($VolumeClone).VolumeID -QoSPolicyID $SbQosPolicyId -Confirm:$False
    Write-Host "Src Id:" $SrcId
    Write-Host "Tgt Id:" ($VolumeClone).VolumeID
}

# It is not necessary to have Target (clone) Volumes added to a VAG, in fact it is recommended to 
#   use CHAP instead of VAG. But you can use VAG within limit of group members it supports

SbNewClone -SrcId $args[0] -SbAccountId $args[1] -SbQosPolicyId $args[2] -SbVagId $args[3]

