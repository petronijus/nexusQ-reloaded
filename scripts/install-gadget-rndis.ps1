# Elevated: make Windows recognize the Nexus Q RNDIS USB gadget.
# The device now advertises Microsoft OS descriptors (os_desc enabled on the
# gadget), but Windows caches "no MS descriptor" per VID/PID in usbflags and
# never re-queries. So: clear that cache, remove the stale device node, rescan
# (forces a fresh MS-OS-descriptor query -> inbox signed RNDIS driver binds),
# then assign the host gadget-net IP.
$ErrorActionPreference = 'Continue'
$log = 'D:\nexusQ-reloaded\gadget-install.log'
"=== elevated RNDIS gadget install (started) ===" | Out-File $log
function L($m) { ($m | Out-String).TrimEnd() | Tee-Object -FilePath $log -Append | Out-Null }

# admin check
$adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
L "elevated=$adm"

# 1) clear cached MS-OS-descriptor verdict for VID_18D1 PID_4EE2 (all bcd variants)
$uf = 'HKLM:\SYSTEM\CurrentControlSet\Control\usbflags'
Get-ChildItem $uf -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '18D14EE2*' } | ForEach-Object {
    L "removing usbflags cache: $($_.PSChildName)"
    Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
}

# 2) remove stale device nodes so Windows re-enumerates and re-reads descriptors
$ids = Get-PnpDevice | Where-Object { $_.InstanceId -like '*VID_18D1&PID_4EE2*' } | Select-Object -ExpandProperty InstanceId
foreach ($id in $ids) {
    L "remove-device $id"
    pnputil /remove-device "$id" 2>&1 | ForEach-Object { L $_ }
}

# 3) rescan -> fresh enumeration -> MS OS descriptor query -> RNDIS auto-install
L "scan-devices..."
pnputil /scan-devices 2>&1 | ForEach-Object { L $_ }
Start-Sleep -Seconds 6

# 4) report device + find the RNDIS NIC
L "=== devices after ==="
Get-PnpDevice | Where-Object { $_.InstanceId -like '*VID_18D1&PID_4EE2*' } | Select-Object Status, Class, FriendlyName, InstanceId | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }

$nic = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'RNDIS|Remote NDIS' } | Select-Object -First 1
if ($nic) {
    L "RNDIS NIC: $($nic.Name) [$($nic.InterfaceDescription)] status=$($nic.Status)"
    # 5) assign host gadget-net IP 172.16.42.2/24 (device side is 172.16.42.1)
    Get-NetIPAddress -InterfaceAlias $nic.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '172.16.42.2' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    try {
        New-NetIPAddress -InterfaceAlias $nic.Name -IPAddress 172.16.42.2 -PrefixLength 24 -ErrorAction Stop | Out-Null
        L "assigned 172.16.42.2/24 to $($nic.Name)"
    } catch {
        L "IP assign note: $($_.Exception.Message)"
    }
    Get-NetIPAddress -InterfaceAlias $nic.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
} else {
    L "NO RNDIS NIC FOUND yet"
}
L "=== DONE ==="
