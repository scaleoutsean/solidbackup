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

# Adjust for your directory layout and desired configuration; basically we apply
#   all SolidBackup-created JSON configuration files against their Ansible playbooks
[array]$logins = (Get-Item ansible/01*.json).Name
foreach ($l in $logins) { ansible-playbook ansible/01-iscsi-login.yaml -e @$l -e "login=yes"}
[array]$mounts = (Get-Item ansible/02*.json).Name
foreach ($m in $mounts) { ansible-playbook ansible/02-fs-mount.yaml -e @$m -e "state=mounted"}
