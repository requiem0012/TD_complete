# Read-only diagnostic: fixed 4 GiB layout, first two slot headers.
$ErrorActionPreference='Stop'
$disk=Get-Disk -Number 1
if($disk.IsBoot -or $disk.IsSystem -or $disk.BusType.ToString() -ne 'USB' -or
   $disk.Size -ne 33607909376 -or ([string]$disk.SerialNumber).Trim() -ne '121220160204') {
    throw 'Target identity changed; refuse raw access.'
}
$raw=[IO.FileStream]::new('\\.\PhysicalDrive1',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
try {
    for($slot=0;$slot -lt 2;$slot++) {
        [int64]$offset=4294967296+[int64]$slot*536870912
        [void]$raw.Seek($offset,[IO.SeekOrigin]::Begin)
        $bytes=[byte[]]::new(512);$read=0
        while($read -lt 512) {
            $n=$raw.Read($bytes,$read,512-$read)
            if($n -eq 0) {throw 'Short raw read'}
            $read+=$n
        }
        Write-Output ('Slot '+($slot+1)+' offset=0x'+$offset.ToString('X'))
        Write-Output ('Header='+[BitConverter]::ToString($bytes,0,56))
        Write-Output ('Magic='+[Text.Encoding]::ASCII.GetString($bytes,0,8)+' frames='+[BitConverter]::ToUInt32($bytes,32)+' header_slot_zero_based='+[BitConverter]::ToUInt32($bytes,48))
    }
} finally {$raw.Dispose()}
