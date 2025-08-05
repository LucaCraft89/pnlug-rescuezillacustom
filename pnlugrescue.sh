#!/bin/bash
echo "PNLUG Rescue Script"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script requires root privileges."
    echo "Attempting to run with sudo..."
    exec sudo "$0" "$@"
fi

# Check and kill any running rescuezilla processes
echo "Checking for running rescuezilla processes..."
for process_name in rescuezilla rescuezillapy; do
    if pgrep -f "$process_name" > /dev/null; then
        echo "Found running $process_name processes. Terminating..."
        pkill -f "$process_name"
        sleep 2
        # Force kill if still running
        if pgrep -f "$process_name" > /dev/null; then
            echo "Force killing remaining $process_name processes..."
            pkill -9 -f "$process_name"
        fi
    fi
done

function cleanup {
    echo "Cleaning up..."
    if mountpoint -q "$mountPath"; then
        umount "$mountPath"
        echo "Unmounted $mountPath"
    fi
    exit 0
}

# Function to wait for device to appear
wait_for_device() {
    local device_path="$1"
    local max_wait=30
    local wait_count=0
    
    echo "Waiting for device $device_path to appear..."
    
    while [ $wait_count -lt $max_wait ]; do
        if test -b "$device_path"; then
            echo "Device $device_path found!"
            return 0
        fi
        
        echo "Waiting... ($((wait_count + 1))/$max_wait)"
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    echo "Timeout waiting for device $device_path"
    return 1
}

# Parse command line arguments
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--ventoypath)
      dataPartPath="$2"
      shift # past argument
      shift # past value
      ;;
    -*|--*)
      echo "Unknown option $1 "
      echo "Usage: $0 [-p|--ventoypath <path>]"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Set default values if not provided via command line
if [ -z "$dataPartPath" ]; then
    # First wait for /dev/dm-1 to appear if it doesn't exist
    if ! test -b "/dev/dm-1"; then
        echo "Waiting for Ventoy devices to be ready..."
        wait_for_device "/dev/dm-1"
    fi
    
    # Try to find ventoy data partition automatically
    for device in sda sdb sdc sdd sde sdf sdg sdh; do
        dataPartPath="/dev/mapper/${device}1"
        if test -b "$dataPartPath"; then
            echo "found ventoy data partition on $dataPartPath"
            break
        fi
    done
    
    # Also check /dev/dm-1 if not found yet
    if [ -z "$dataPartPath" ] || ! test -b "$dataPartPath"; then
        if test -b "/dev/dm-1"; then
            dataPartPath="/dev/dm-1"
            echo "found ventoy data partition on $dataPartPath"
        fi
    fi
fi

mountPath="/mnt/ventoy"
restoreImgPath="$mountPath/restoreimg"

# Check if ventoy data partition exists
if ! test -b "$dataPartPath"; then
    echo "ventoy data partition not found on any device."
    echo "Please make sure you have a Ventoy USB drive connected."
    while ! test -b "$dataPartPath"; do
        read -p "Specify the path like this: /dev/mapper/sdX1 (where sdX is the device name) or press Enter to exit: " dataPartPath
        if [ -z "$dataPartPath" ]; then
            echo "Exiting."
            exit 0
        fi
        echo "Using specified path: $dataPartPath"
        if ! test -b "$dataPartPath"; then
            echo "The specified path does not exist or is not a block device. Please try again."
        fi
    done
else
    echo "Ventoy data partition found at $dataPartPath."
fi

# Mount the ventoy partition
mkdir -p $mountPath

if mountpoint -q $mountPath; then
    echo "$mountPath is already mounted."
    umount $mountPath
    if [ $? -ne 0 ]; then
        echo "Failed to unmount $mountPath. Please check if it is in use."
        exit 1
    fi
else
    echo "Mounting $dataPartPath to $mountPath"
fi

mount "$dataPartPath" $mountPath

if [ $? -ne 0 ]; then
    echo "Failed to mount $dataPartPath to $mountPath"
    exit 1
fi
# Check for restoreimg directory
if ! test -d "$restoreImgPath"; then
    echo "can't find restoreimg directory at $restoreImgPath."
    
    while ! test -d "$restoreImgPath"; do
        ls $mountPath
        read -p "Specify the path to the restoreimg directory or press Enter to exit: " restoreImgPath
        if [ -z "$restoreImgPath" ]; then
            echo "Exiting."
            cleanup
        fi
        restoreImgPath="$mountPath/$restoreImgPath"
        echo "Using specified path: $restoreImgPath"
        if ! test -d "$restoreImgPath"; then
            echo "The specified path does not exist or is not a directory. Please try again."
        fi
    done
else
    echo "Restoreimg directory found at $restoreImgPath."
fi

if ! command -v rescuezilla >/dev/null 2>&1
then
    echo "rescuezilla could not be found"
    cleanup
fi

echo "Select Destination disk"
select disk in /dev/sd* /dev/nvme* /dev/mmcblk*; do
    if [ -n "$disk" ]; then
        echo "You selected $disk"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

echo "WARNING: This will completely wipe all partitions on $disk!"
echo "All data on $disk will be permanently lost."
read -p "Are you sure you want to continue? Type 'YES' to confirm: " confirmation

if [[ "$confirmation" != "YES" ]]; then
    echo "Operation cancelled."
    cleanup
fi

echo "Wiping partition table from $disk..."
sgdisk --zap-all "$disk"
partprobe "$disk"
sleep 1
echo "Disk $disk partition table has been wiped clean."

rescuezilla restore --source "$restoreImgPath" --destination "$disk" --overwrite-partition-table

# Find the largest partition on the selected disk and grow it to use all unallocated space
echo "Finding largest partition on $disk..."

# Get partition information and find the largest one
largest_partition=""
largest_size=0

# Use lsblk to get partitions for the selected disk
for partition in $(lsblk -lnpo NAME,TYPE "$disk" | awk '$2=="part" {print $1}'); do
    if test -b "$partition"; then
        # Get partition size in blocks
        size=$(blockdev --getsz "$partition" 2>/dev/null)
        if [[ $? -eq 0 ]] && [[ $size -gt $largest_size ]]; then
            largest_size=$size
            largest_partition=$partition
        fi
    fi
done

if [[ -n "$largest_partition" ]]; then
    echo "Largest partition found: $largest_partition"
    
    # Extract partition number
    partition_num=$(lsblk -lnpo PARTN,NAME | grep "$largest_partition" | awk '{print $1}')
    
    echo "Growing partition $partition_num to use all available space..."
    
    # Use parted to resize the partition to 100%
    parted -s -- "$disk" resizepart "$partition_num" 100%
    
    if [[ $? -eq 0 ]]; then
        echo "Partition resized successfully."
        
        # Inform the kernel about the partition table change
        partprobe "$disk"
        sleep 2
        
        # Resize the filesystem to match the new partition size
        echo "Resizing filesystem on $largest_partition..."
        
        # Check filesystem type and use the appropriate tool
        fs_type=$(lsblk -no FSTYPE "$largest_partition")
        echo "Detected filesystem type: $fs_type"
        
        resize_success=1
        case "$fs_type" in
            ext2|ext3|ext4)
                e2fsck -f -p "$largest_partition"
                resize2fs "$largest_partition"
                resize_success=$?
                ;;
            btrfs)
                btrfs filesystem resize max "$largest_partition"
                resize_success=$?
                ;;
            xfs)
                # xfs_growfs needs a mounted filesystem
                temp_mount="/mnt/resize_temp"
                mkdir -p "$temp_mount"
                if mount "$largest_partition" "$temp_mount"; then
                    xfs_growfs "$temp_mount"
                    resize_success=$?
                    umount "$temp_mount"
                else
                    echo "Failed to mount $largest_partition to resize XFS filesystem."
                    resize_success=1
                fi
                rmdir "$temp_mount"
                ;;
            ntfs)
                ntfsresize -f "$largest_partition"
                resize_success=$?
                ;;
            *)
                echo "Unsupported filesystem type: $fs_type. Filesystem not resized."
                resize_success=1
                ;;
        esac

        if [[ $resize_success -eq 0 ]]; then
            echo "Filesystem resized successfully."
        else
            echo "Warning: Partition was resized but filesystem resize may have failed."
        fi
    else
        echo "Failed to resize partition."
    fi
else
    echo "No partitions found on $disk"
fi

echo "Rescue completed successfully. You can now reboot your system."

cleanup

echo "Reboot now? (y/n)"
read -r answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    echo "Rebooting..."
    reboot
else
    echo "You can reboot later."
fi  
exit 0