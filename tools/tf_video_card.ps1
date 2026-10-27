# Default mode only previews a validated write plan. Raw writes require -Write
# AND the exact target token printed by the plan. Never writes a partition table.
[CmdletBinding(DefaultParameterSetName='Plan')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='List')][switch]$List,
    [Parameter(Mandatory=$true,ParameterSetName='Verify')][switch]$Verify,
    [Parameter(Mandatory=$true,ParameterSetName='Write')][switch]$Write,
    [Parameter(Mandatory=$true,ParameterSetName='Plan')]
    [Parameter(Mandatory=$true,ParameterSetName='Verify')]
    [Parameter(Mandatory=$true,ParameterSetName='Write')]
    [ValidateRange(0,128)][int]$DiskNumber,
    [Parameter(ParameterSetName='Plan')]
    [Parameter(ParameterSetName='Verify')]
    [Parameter(ParameterSetName='Write')]
    [string]$InputFile=(Join-Path $PSScriptRoot 'video01.bin'),
    [Parameter(Mandatory=$true,ParameterSetName='Write')][string]$ConfirmTarget,
    [Parameter(ParameterSetName='Write')][string]$BackupDirectory=(Join-Path $PSScriptRoot '../backups/tf_media')
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-Token($disk) {
    return ('disk{0}:{1}:{2}' -f $disk.Number,([string]$disk.SerialNumber).Trim(),[int64]$disk.Size)
}
function Assert-Target($expected) {
    $now=Get-Disk -Number $expected.Number
    if($now.IsBoot -or $now.IsSystem -or $now.BusType.ToString() -notin @('USB','SD','MMC')) {
        throw 'Refusing a system/boot/non-removable-bus disk.'
    }
    if($now.IsOffline -or $now.IsReadOnly) {throw 'Disk is offline or read-only.'}
    if((Get-Token $now) -cne (Get-Token $expected)) {throw 'Disk identity/capacity changed. Run a fresh plan.'}
}
function Read-Exactly($stream,[byte[]]$buffer,[int]$count) {
    $total=0
    while($total -lt $count) {
        $n=$stream.Read($buffer,$total,$count-$total)
        if($n -le 0) {throw 'Unexpected end of device/file.'}
        $total+=$n
    }
}
function Read-RangeHash($stream,[int64]$offset,[int64]$length) {
    [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $buffer=[byte[]]::new(1048576)
        $remaining=$length
        while($remaining -gt 0) {
            $n=[int][Math]::Min($buffer.Length,$remaining)
            Read-Exactly $stream $buffer $n
            [void]$sha.TransformBlock($buffer,0,$n,$buffer,0)
            $remaining-=$n
        }
        [void]$sha.TransformFinalBlock([byte[]]::new(0),0,0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-','')
    } finally {$sha.Dispose()}
}
function Assert-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=[Security.Principal.WindowsPrincipal]::new($id)
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Raw disk access needs an Administrator PowerShell window. Plan mode needs no elevation.'
    }
}
function Compare-RawRange($card,$source,[int64]$offset,[int64]$length) {
    if(-not ('HxTfReadback' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class HxTfReadback {
    static void FullRead(Stream s, byte[] b, int count) {
        int have=0,n;
        while(have<count) {n=s.Read(b,have,count-have);if(n==0)throw new IOException("Short read");have+=n;}
    }
    public static string Compare(Stream card,Stream source,long offset,long length) {
        card.Position=offset;source.Position=0;
        byte[] a=new byte[1048576],b=new byte[1048576];
        long first=-1,last=-1,different=0,zeros=0,ffs=0;
        int samples=0;StringBuilder detail=new StringBuilder();
        for(long position=0;position<length;) {
            int n=(int)Math.Min(a.Length,length-position);
            FullRead(card,a,n);FullRead(source,b,n);
            for(int i=0;i<n;i++) if(a[i]!=b[i]) {
                long p=position+i;
                if(first<0)first=p;last=p;different++;
                if(a[i]==0)zeros++;if(a[i]==255)ffs++;
                if(samples++<12)detail.AppendFormat("relative={0} absolute=0x{1:X} expected={2:X2} actual={3:X2}\n",p,offset+p,b[i],a[i]);
            }
            position+=n;
        }
        return String.Format("Compare bytes={0} different={1} first_relative={2} last_relative={3} mismatches_read_zero={4} mismatches_read_ff={5}\n{6}",length,different,first,last,zeros,ffs,detail);
    }
}
'@
    }
    return [HxTfReadback]::Compare($card,$source,$offset,$length)
}

if($List) {
    Get-Disk | Where-Object {$_.BusType.ToString() -in @('USB','SD','MMC')} |
        Select-Object Number,FriendlyName,SerialNumber,Size,IsBoot,IsSystem,IsReadOnly | Format-List
    return
}
$file=Get-Item -LiteralPath $InputFile
if($file.PSIsContainer) {throw 'Input must be a media .bin file.'}
$header=[byte[]]::new(512)
$source=[IO.File]::OpenRead($file.FullName)
try {Read-Exactly $source $header 512} finally {$source.Dispose()}
if([Text.Encoding]::ASCII.GetString($header,0,8) -cne 'HXVIDEO3') {throw 'Not an HXVIDEO3 media file.'}
$taskFps=[BitConverter]::ToUInt32($header,20)
if($taskFps -eq 4) {$taskSamples=12000;$taskRecord=347;$taskAudio=47}
elseif($taskFps -eq 6) {$taskSamples=8000;$taskRecord=332;$taskAudio=32}
else {throw 'Supported native frame rates: 4 or 6.'}
$expectedFields=@{8=3;12=640;16=480;24=48000;28=$taskSamples;36=$taskRecord;40=300;44=$taskAudio}
foreach($field in $expectedFields.Keys) {
    if([BitConverter]::ToUInt32($header,[int]$field) -ne $expectedFields[$field]) {throw 'Unsupported media format.'}
}
[uint32]$crc=[uint32]::MaxValue
[uint32]$poly=[Convert]::ToUInt32('EDB88320',16)
for($i=0;$i -lt 52;$i++) {
    $crc=$crc -bxor [uint32]$header[$i]
    for($bit=0;$bit -lt 8;$bit++) {
        if(($crc -band 1) -ne 0) {$crc=($crc -shr 1) -bxor $poly} else {$crc=$crc -shr 1}
    }
}
$crc=$crc -bxor [uint32]::MaxValue
if($crc -ne [BitConverter]::ToUInt32($header,52)) {throw 'Media header CRC32 mismatch.'}
$frames=[BitConverter]::ToUInt32($header,32)
$slot=[BitConverter]::ToUInt32($header,48)
if($frames -lt 1 -or $frames -gt [Math]::Floor(1048575/$taskRecord) -or $slot -gt 31) {throw 'Invalid frame count / slot.'}
if($file.Length -ne (512+[int64]$frames*$taskRecord*512) -or $file.Length -gt 536870912) {throw 'Media length/slot limit mismatch.'}
$disk=Get-Disk -Number $DiskNumber
Assert-Target $disk
if($disk.Size -lt 4831838208 -or $disk.Size -gt 2199023255552 -or ($disk.Size%512) -ne 0) {
    throw 'Unsupported card capacity; need one full 512 MiB slot after absolute 4 GiB.'
}
[int64]$offset=4294967296+[int64]$slot*536870912
if(($offset+536870912) -gt $disk.Size) {throw 'Selected full 512 MiB slot exceeds card capacity.'}
Write-Warning 'Fixed 4 GiB layout. Reported capacity is NOT proof of real capacity. Never use failed media for important data.'
$token=Get-Token $disk
$sourceHash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
Write-Output ('Mode: '+$PSCmdlet.ParameterSetName)
Write-Output ('Target: '+$disk.FriendlyName+' / '+$token)
Write-Output ('File: '+$file.FullName+' / '+$file.Length+' bytes')
Write-Output ('Video slot: '+($slot+1)+' / byte offset: '+$offset+' / hex: 0x'+$offset.ToString('X')+' / LBA: '+($offset/512))
Write-Output ('Source SHA256: '+$sourceHash)
Write-Output ('Confirmation token: '+$token)
if($PSCmdlet.ParameterSetName -eq 'Plan') {
    Write-Output 'PLAN ONLY. No physical disk has been opened or written.'
    return
}
Assert-Admin
$device='\\.\PhysicalDrive'+$disk.Number
if($Verify) {
    $raw=[IO.FileStream]::new($device,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        [void]$raw.Seek($offset,[IO.SeekOrigin]::Begin)
        $readHeader=[byte[]]::new(512);Read-Exactly $raw $readHeader 512
        Write-Output ('Card header hex: '+[BitConverter]::ToString($readHeader,0,56))
        $hash=Read-RangeHash $raw $offset $file.Length
        Write-Output ('Card SHA256: '+$hash)
        if($hash -cne $sourceHash) {
            $source=[IO.File]::OpenRead($file.FullName)
            try {Write-Output (Compare-RawRange $raw $source $offset $file.Length)} finally {$source.Dispose()}
            Write-Output 'VERIFY FAILED: card bytes differ from the source video.'
            throw 'VERIFY FAILED: card bytes differ from the source video.'
        }
    } finally {$raw.Dispose()}
    Write-Output 'VERIFY PASS: every byte matches the source video.'
    return
}
if(-not $Write -or $ConfirmTarget -cne $token) {throw 'Write requires the exact current confirmation token.'}

# Only the explicitly selected write mode reaches any volume lock or raw write.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class HxVideoVolume {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string n,uint a,uint s,IntPtr p,uint c,uint f,IntPtr t);
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool DeviceIoControl(SafeFileHandle h,uint c,IntPtr i,uint n,IntPtr o,uint m,out uint b,IntPtr v);
}
'@
$locks=[Collections.Generic.List[Microsoft.Win32.SafeHandles.SafeFileHandle]]::new()
$raw=$null
try {
    foreach($partition in @(Get-Partition -DiskNumber $disk.Number)) {
        if(-not $partition.DriveLetter) {continue}
        $volume='\\.\'+$partition.DriveLetter+':'
        $handle=[HxVideoVolume]::CreateFile($volume,3221225472,3,[IntPtr]::Zero,3,0,[IntPtr]::Zero)
        if($handle.IsInvalid) {$handle.Dispose();throw ('Cannot open '+$volume+'; close WinHex and other disk tools.')}
        [uint32]$returned=0
        if(-not [HxVideoVolume]::DeviceIoControl($handle,589848,[IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$returned,[IntPtr]::Zero)) {
            $handle.Dispose();throw ('Cannot lock '+$volume+'; close WinHex and other programs using the card.')
        }
        $locks.Add($handle)
        if(-not [HxVideoVolume]::DeviceIoControl($handle,589856,[IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$returned,[IntPtr]::Zero)) {
            throw ('Cannot dismount '+$volume)
        }
    }
    Assert-Target $disk
    # Write-through + explicit flush; there is no partition-table write.
    $raw=[IO.FileStream]::new($device,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite,1048576,[IO.FileOptions]::WriteThrough)
    $backupRoot=[IO.Path]::GetFullPath($BackupDirectory)
    if(-not [IO.Path]::IsPathRooted($backupRoot)) {throw 'Backup directory must be local and absolute.'}
    $backupDrive=[IO.Path]::GetPathRoot($backupRoot).TrimEnd('\').TrimEnd(':')
    if($backupDrive.Length -ne 1) {throw 'Use a local fixed drive for backup.'}
    $backupPart=Get-Partition -DriveLetter $backupDrive
    if($backupPart.DiskNumber -eq $disk.Number) {throw 'Backup cannot be stored on the target card.'}
    [void][IO.Directory]::CreateDirectory($backupRoot)
    $backup=Join-Path $backupRoot ('disk'+$disk.Number+'_slot'+($slot+1)+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'.before.bin')
    $out=[IO.FileStream]::new($backup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    try {
        [void]$raw.Seek($offset,[IO.SeekOrigin]::Begin)
        $buffer=[byte[]]::new(1048576);$left=$file.Length
        while($left -gt 0) {
            $n=[int][Math]::Min($left,$buffer.Length);Read-Exactly $raw $buffer $n
            $out.Write($buffer,0,$n);$left-=$n
        }
        $out.Flush($true)
    } finally {$out.Dispose()}
    Write-Output ('Original target bytes backed up to: '+$backup)
    Assert-Target $disk
    $source=[IO.File]::OpenRead($file.FullName)
    try {
        if($source.Length -ne $file.Length -or (Read-RangeHash $source 0 $file.Length) -cne $sourceHash) {throw 'Source changed before write.'}
        $source.Position=0
        [void]$raw.Seek($offset,[IO.SeekOrigin]::Begin)
        $left=$file.Length
        while($left -gt 0) {
            $n=[int][Math]::Min($left,$buffer.Length);Read-Exactly $source $buffer $n
            $raw.Write($buffer,0,$n);$left-=$n
            Write-Progress -Activity 'Writing selected TF video slot' -PercentComplete (100*($file.Length-$left)/$file.Length)
        }
        $raw.Flush($true)
        Write-Progress -Activity 'Writing selected TF video slot' -Completed
    } finally {$source.Dispose()}
    $raw.Dispose();$raw=$null
    $raw=[IO.FileStream]::new($device,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $hash=Read-RangeHash $raw $offset $file.Length
    if($hash -cne $sourceHash) {throw 'READBACK FAILED after write. Preserve the backup and inspect card/reader errors.'}
    Write-Output ('WRITE + READBACK PASS. Card SHA256: '+$hash)
    Write-Output 'Safely eject/reinsert, then run the same command with -Verify (no -Write/-ConfirmTarget) to test persistence.'
} finally {
    if($null -ne $raw) {$raw.Dispose()}
    foreach($handle in $locks) {
        [uint32]$returned=0
        [void][HxVideoVolume]::DeviceIoControl($handle,589852,[IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$returned,[IntPtr]::Zero)
        $handle.Dispose()
    }
}
