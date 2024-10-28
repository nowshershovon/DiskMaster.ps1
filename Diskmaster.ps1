# Function to check if the script is running as an administrator
function Test-IsAdmin {
    try {
        $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# Function to restart the script with administrative privileges
function Start-ProcessAsAdmin {
    param (
        [string]$FilePath,
        [string]$Arguments
    )
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$FilePath`" $Arguments" -Verb RunAs
}

# Check if running as admin, if not, restart as admin
if (-not (Test-IsAdmin)) {
    Write-Host "This script requires administrative privileges. Restarting as Administrator..."
    Start-ProcessAsAdmin -FilePath $MyInvocation.MyCommand.Path -Arguments $args
    exit
}

# Welcome Message
Write-Host "Welcome to DiskMaster"

# Define maximum length for the bar
$maxBarLength = 20

# Function to create a bar representation of space
function Get-Bar {
    param (
        [Parameter(Mandatory=$true)]
        [double]$UsedValue,
        [Parameter(Mandatory=$true)]
        [double]$TotalValue
    )
    
    $percentage = [math]::Min(1, $UsedValue / $TotalValue)
    $usedBarLength = [math]::Round($percentage * $maxBarLength)
    $freeBarLength = $maxBarLength - $usedBarLength

    return ("#" * $usedBarLength) + ("." * $freeBarLength)
}

# Function to list disks and partitions
Function List-DisksAndPartitions {
    # Retrieve and process partitions and volumes
    Get-Partition | ForEach-Object {
        $partition = $_
        $volume = Get-Volume -Partition $partition -ErrorAction SilentlyContinue
        $driveLetter = if ($volume) { $volume.DriveLetter } else { "" }
        $totalSizeGB = [math]::Round($partition.Size / 1GB, 2)

        if ($volume) {
            $freeSizeGB = [math]::Round($volume.SizeRemaining / 1GB, 2)
            $usedSizeGB = [math]::Round(($volume.Size - $volume.SizeRemaining) / 1GB, 2)
            $usedPercent = [math]::Round(($usedSizeGB / $totalSizeGB) * 100, 2)
            $name = $volume.FileSystemLabel
        } else {
            $freeSizeGB = ""
            $usedSizeGB = ""
            $usedPercent = ""
            $name = ""
        }

        if (($totalSizeGB -gt 1) -and ($freeSizeGB -eq "") -and ($usedSizeGB -eq "") -and ($usedPercent -eq "") -and ($name -eq "")) {
            $bitLockerStatus = "Enabled"
        } else {
            $bitLockerStatus = ""
        }

        [PSCustomObject]@{
            Disk        = $partition.DiskNumber
            Part        = if ($partition.PartitionNumber) { "{0,-1}" -f $partition.PartitionNumber } else { "" }
            Letter      = if ($driveLetter) { "{0,-1}" -f $driveLetter } else { "" }
            Total       = if ($totalSizeGB) { "{0,-8}" -f $totalSizeGB } else { "" }
            Used        = if ($usedSizeGB) { "{0,-8}" -f $usedSizeGB } else { "" }
            Free        = if ($freeSizeGB) { "{0,-8}" -f $freeSizeGB } else { "" }
            Percent     = if ($usedPercent) { "{0,-5}%" -f $usedPercent } else { "" }
            Name        = $name
            BitLocker   = $bitLockerStatus
        }
    } | Sort-Object Disk, Part | Format-Table -Property Disk, Part, Letter, Total, Used, Free, Percent, Name, BitLocker -AutoSize
}
# Function to check if a drive is unlocked
function Is-DriveUnlocked {
    param (
        [string]$DriveLetter
    )

    try {
        # Get the BitLocker volume status
        $bitlockerStatus = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction Stop
        return ($bitlockerStatus.ProtectionStatus -eq 'Off')
    } catch {
        Write-Host
        Write-Host "Wrong drive letter. Please ensure the drive letter is correct and try again."
        Write-Host
        return $false
    }
}

# Function to unlock a BitLocker-enabled drive
function Unlock-Drive {
    param (
        [string]$DriveLetter,
        [string]$Password
    )

    if (Is-DriveUnlocked -DriveLetter $DriveLetter) {
        Write-Host
        Write-Host "${DriveLetter} is already unlocked."
        Write-Host
        return
    }

    try {
        $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
        Unlock-BitLocker -MountPoint $DriveLetter -Password $securePassword -ErrorAction Stop | Out-Null

        # Check if the drive was successfully unlocked
        $driveInfo = Get-PSDrive -Name $DriveLetter.TrimEnd(':')
        $totalSpace = [math]::Round($driveInfo.Used / 1GB + $driveInfo.Free / 1GB, 2)
        $usedSpace = [math]::Round($driveInfo.Used / 1GB, 2)
        $freeSpace = [math]::Round($driveInfo.Free / 1GB, 2)

        Write-Host
        Write-Host "${DriveLetter} is now unlocked."
        Write-Host "Total: ${totalSpace} GB  Used: ${usedSpace} GB   Remaining: ${freeSpace} GB"
        Write-Host
    } catch {
        if ($_.Exception.Message -match "The drive cannot be unlocked with the key provided") {
            Write-Host
            Write-Host "Password is incorrect."
            Write-Host
        } else {
            Write-Host
            Write-Host "Error unlocking ${DriveLetter}: $_"
            Write-Host
        }
    }
}

# Function to lock a BitLocker-enabled drive
function Lock-Drive {
    param (
        [string]$DriveLetter
    )

    try {
        Lock-BitLocker -MountPoint $DriveLetter -ErrorAction Stop | Out-Null
        Write-Host
        Write-Host "${DriveLetter} is now locked."
        Write-Host
    } catch {
        if ($_.Exception.Message -match "The drive cannot be found") {
            Write-Host
            Write-Host "Wrong drive letter. Please ensure the drive letter is correct and try again."
            Write-Host
        } else {
            Write-Host
            Write-Host "Error locking ${DriveLetter}: $_"
            Write-Host
        }
    }
}
# Main loop to keep the script running until the user chooses to exit
while ($true) {
    # Display the list of disks and partitions
    List-DisksAndPartitions

    # Display menu options
    Write-Host "`nPlease Enter options:"
    Write-Host "1. Add drive letter"
    Write-Host "2. Remove drive letter"
    Write-Host "3. Unlock drive"
    Write-Host "4. Lock drive"
    Write-Host "0. Exit"

    # Read user input
    $option = Read-Host "Enter your choice"

    # Process user input
    switch ($option) {
        1 {
            $diskNumber = Read-Host "Enter Disk Number"
            
            # Check if the disk exists
            $disk = Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue
            if (-not $disk) {
                Write-Host "Disk $diskNumber does not exist. Please enter a valid disk number."
                continue
            }

            $partitionNumber = Read-Host "Enter Partition Number"
            
            # Check if the partition exists
            $partition = Get-Partition -DiskNumber $diskNumber | Where-Object { $_.PartitionNumber -eq $partitionNumber }
            if (-not $partition) {
                Write-Host "Partition $partitionNumber on disk $diskNumber does not exist. Please enter a valid partition number."
                continue
            }

            # Check if the partition already has a drive letter
            if ($partition.DriveLetter) {
                Write-Host "Partition $partitionNumber on disk $diskNumber already has a drive letter ($($partition.DriveLetter))."
                continue
            }

            $driveLetter = Read-Host "Enter Drive Letter"
            
            # Check if the drive letter is already occupied
            $occupiedVolume = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
            if ($occupiedVolume) {
                Write-Host "Drive letter $driveLetter is occupied. Please choose a different letter."
                continue
            }

            try {
                Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $partitionNumber -AccessPath "$driveLetter`:\" -ErrorAction Stop
                Write-Host "Drive letter $driveLetter added to partition $partitionNumber on disk $diskNumber."
            } catch {
                Write-Host "Error adding drive letter: $_"
            }
        }
        2 {
            $driveLetter = Read-Host "Enter Drive Letter"
            
            # Check if the drive letter exists
            $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
            if (-not $volume) {
                Write-Host "Drive letter $driveLetter not found. Please enter a valid drive letter."
                continue
            }

            $partition = Get-Partition | Where-Object { $_.DriveLetter -eq $driveLetter }
            
            if ($partition) {
                try {
                    Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath "$driveLetter`:\" -ErrorAction Stop
                    Write-Host "Drive letter $driveLetter removed from partition $($partition.PartitionNumber) on disk $($partition.DiskNumber)."
                } catch {
                    Write-Host "Error removing drive letter: $_"
                }
            } else {
                Write-Host "Drive letter $driveLetter not associated with any partition."
            }
        }
        3 {
            $driveLetter = Read-Host "Enter Drive Letter"
            $password = Read-Host "Enter password" -AsSecureString
            $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
            Unlock-Drive -DriveLetter $driveLetter -Password $plainPassword
        }
        4 {
            $driveLetter = Read-Host "Enter Drive Letter"
            Lock-Drive -DriveLetter $driveLetter
        }
        0 {
            Write-Host "Exiting DiskMaster. Goodbye!"
            exit # Use exit to ensure script termination
        }
        default {
            Write-Host "Invalid option selected. Please try again."
        }
    }
}

# Pause the script before exiting
Read-Host -Prompt "Press Enter to exit"
