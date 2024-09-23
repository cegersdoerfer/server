#!/bin/bash

# Check for Bash version 4 or higher
if ((BASH_VERSINFO[0] < 4)); then
    echo "This script requires Bash version 4 or higher."
    exit 1
fi

# Check for required commands
for cmd in lctl lsblk findmnt; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: '$cmd' command not found."
        exit 1
    fi
done

# Get the time interval and logging directory from the arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <time_interval_in_seconds> <logging_directory>"
    exit 1
fi

INTERVAL=$1
LOG_DIR=$2

# Validate and prepare the logging directory
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create logging directory '$LOG_DIR'"
        exit 1
    fi
fi

# Ensure the script has write permission to the log directory
if [ ! -w "$LOG_DIR" ]; then
    echo "Error: No write permission for logging directory '$LOG_DIR'"
    exit 1
fi

# Function to map major:minor to device names
declare -A majmin_to_dev
while read -r line; do
    MAJMIN=$(echo "$line" | awk -F'"' '{print $2}')
    NAME=$(echo "$line" | awk -F'"' '{print $4}')
    majmin_to_dev[$MAJMIN]=$NAME
done < <(lsblk -P -o MAJ:MIN,NAME)

# Function to get OST devices
get_devices() {
    local type=$1
    declare -n dev_array=$2
    while read -r line; do
        name=$(echo "$line" | awk -F '[.=]' '{print $2}')
        majmin=$(echo "$line" | awk -F '=' '{print $2}')
        device=${majmin_to_dev[$majmin]}
        if [ -n "$device" ]; then
            dev_array[$name]=$device
        else
            echo "Warning: Device not found for $type $name with major:minor $majmin"
        fi
    done < <(lctl get_param "$type".*.dev_name 2>/dev/null)
}

# Function to get MDT devices from the 'mount' command
get_mdt_devices_from_mount() {
    declare -n dev_array=$1
    while read -r device mount_point fs_type options; do
        if [[ "$fs_type" == "lustre" ]]; then
            # Extract svname from options
            svname=$(echo "$options" | tr ',' '\n' | grep '^svname=' | cut -d'=' -f2)
            if [[ "$svname" == *MDT* ]]; then
                name="$svname"
                device_name=$(basename "$device")
                dev_array[$name]=$device_name
            fi
        fi
    done < <(findmnt -n -t lustre -o SOURCE,TARGET,FSTYPE,OPTIONS)
}

# Get OST devices
declare -A ost_device
get_devices "obdfilter" ost_device

# Get MDT devices
declare -A mdt_device
get_mdt_devices_from_mount mdt_device

# Check if any devices were found
if [ ${#ost_device[@]} -eq 0 ] && [ ${#mdt_device[@]} -eq 0 ]; then
    echo "No OST or MDT devices found on this server."
    exit 1
fi

echo "Monitoring the following devices:"
for ost in "${!ost_device[@]}"; do
    echo "OST $ost on device ${ost_device[$ost]}"
done
for mdt in "${!mdt_device[@]}"; do
    echo "MDT $mdt on device ${mdt_device[$mdt]}"
done

# Main loop to collect statistics
while true; do
    # Include milliseconds in the timestamp
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S.%3N')

    # Collect stats for OSTs
    for ost in "${!ost_device[@]}"; do
        device=${ost_device[$ost]}
        stats=$(grep "\b$device\b" /proc/diskstats)
        if [ -n "$stats" ]; then
            echo "$TIMESTAMP $stats" >> "$LOG_DIR/${ost}.log"
        else
            echo "$TIMESTAMP Device $device not found for OST $ost" >> "$LOG_DIR/${ost}.log"
        fi
    done

    # Collect stats for MDTs
    for mdt in "${!mdt_device[@]}"; do
        device=${mdt_device[$mdt]}
        stats=$(grep "\b$device\b" /proc/diskstats)
        if [ -n "$stats" ]; then
            echo "$TIMESTAMP $stats" >> "$LOG_DIR/${mdt}.log"
        else
            echo "$TIMESTAMP Device $device not found for MDT $mdt" >> "$LOG_DIR/${mdt}.log"
        fi
    done

    sleep "$INTERVAL"
done
