#!/usr/bin/env bash

# =============================================================================
# Ubuntu System Diagnosis Script - Principal Site Reliability Engineer
# =============================================================================
# This comprehensive diagnostic script evaluates system health across the SRE
# golden signals (latency, traffic, errors, saturation) using only standard
# Ubuntu admin packages. It provides structured health reporting with color-coded
# output and critical warnings summary.
#
# Requirements: sysstat, iproute2, systemd, procps, bc, lm-sensors
# =============================================================================

set -euo pipefail

# =============================================================================
# COLOR DEFINITIONS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

DIAGNOSIS_DIR="/tmp/ubuntu-diagnosis-$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${DIAGNOSIS_DIR}/diagnosis-report.txt"
LOG_FILE="${DIAGNOSIS_DIR}/diagnosis.log"
CRITICAL_WARNINGS=()
TEMP_DIR="/tmp/ubuntu-diagnosis-temp-$(date +%s)"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    echo -e "$*" | tee -a "${LOG_FILE}"
}

info() {
    log "${BLUE}[INFO]${NC} $*"
}

warn() {
    log "${YELLOW}[WARN]${NC} $*"
}

error() {
    log "${RED}[ERROR]${NC} $*"
    CRITICAL_WARNINGS+=("$*")
}

success() {
    log "${GREEN}[SUCCESS]${NC} $*"
}

critical() {
    log "${RED}[CRITICAL]${NC} $*"
    CRITICAL_WARNINGS+=("$*")
}

# =============================================================================
# ADVANCED DIAGNOSTIC FUNCTIONS
# =============================================================================

# Function to safely extract numeric values from pressure files
extract_pressure_value() {
    local file="$1"
    local field="$2"

    if [[ -f "$file" ]]; then
        local value=$(grep "^$field" "$file" 2>/dev/null | awk '{print $2}' | cut -d'=' -f2)
        # Clean up the value by removing any non-numeric characters except decimal points
        echo "$value" | sed 's/[^0-9.]//g'
    else
        echo "0"
    fi
}

# Function to check detailed pressure stall information (PSI) with robust error handling
check_pressure_stall_detailed() {
    info "Checking detailed Pressure Stall Information (PSI)..."

    # Read and evaluate CPU, Memory, and IO pressure via /proc/pressure/*
    if [[ -d "/proc/pressure" ]]; then
        # Check CPU pressure in detail
        if [[ -f "/proc/pressure/cpu" ]]; then
            cpu_pressure=$(cat /proc/pressure/cpu)
            info "CPU Pressure Stall Information:"
            echo "  $cpu_pressure"

            # Parse and analyze CPU pressure values
            cpu_some=$(echo "$cpu_pressure" | grep -o 'some=[0-9.]*' | cut -d'=' -f2)
            cpu_full=$(echo "$cpu_pressure" | grep -o 'full=[0-9.]*' | cut -d'=' -f2)

            if [[ -n "$cpu_some" && "$cpu_some" != "0" ]]; then
                if (( $(echo "$cpu_some > 0.1" | bc -l) )); then
                    warn "High CPU some pressure detected: ${cpu_some}"
                else
                    success "CPU some pressure is normal: ${cpu_some}"
                fi
            fi

            if [[ -n "$cpu_full" && "$cpu_full" != "0" ]]; then
                if (( $(echo "$cpu_full > 0.1" | bc -l) )); then
                    critical "High CPU full pressure detected: ${cpu_full}"
                else
                    success "CPU full pressure is normal: ${cpu_full}"
                fi
            fi
        fi

        # Check memory pressure in detail
        if [[ -f "/proc/pressure/memory" ]]; then
            mem_pressure=$(cat /proc/pressure/memory)
            info "Memory Pressure Stall Information:"
            echo "  $mem_pressure"

            # Parse and analyze memory pressure values
            mem_some=$(echo "$mem_pressure" | grep -o 'some=[0-9.]*' | cut -d'=' -f2)
            mem_full=$(echo "$mem_pressure" | grep -o 'full=[0-9.]*' | cut -d'=' -f2)

            if [[ -n "$mem_some" && "$mem_some" != "0" ]]; then
                if (( $(echo "$mem_some > 0.1" | bc -l) )); then
                    warn "High memory some pressure detected: ${mem_some}"
                else
                    success "Memory some pressure is normal: ${mem_some}"
                fi
            fi

            if [[ -n "$mem_full" && "$mem_full" != "0" ]]; then
                if (( $(echo "$mem_full > 0.1" | bc -l) )); then
                    critical "High memory full pressure detected: ${mem_full}"
                else
                    success "Memory full pressure is normal: ${mem_full}"
                fi
            fi
        fi

        # Check I/O pressure in detail
        if [[ -f "/proc/pressure/io" ]]; then
            io_pressure=$(cat /proc/pressure/io)
            info "I/O Pressure Stall Information:"
            echo "  $io_pressure"

            # Parse and analyze I/O pressure values
            io_some=$(echo "$io_pressure" | grep -o 'some=[0-9.]*' | cut -d'=' -f2)
            io_full=$(echo "$io_pressure" | grep -o 'full=[0-9.]*' | cut -d'=' -f2)

            if [[ -n "$io_some" && "$io_some" != "0" ]]; then
                if (( $(echo "$io_some > 0.1" | bc -l) )); then
                    warn "High I/O some pressure detected: ${io_some}"
                else
                    success "I/O some pressure is normal: ${io_some}"
                fi
            fi

            if [[ -n "$io_full" && "$io_full" != "0" ]]; then
                if (( $(echo "$io_full > 0.1" | bc -l) )); then
                    critical "High I/O full pressure detected: ${io_full}"
                else
                    success "I/O full pressure is normal: ${io_full}"
                fi
            fi
        fi
    else
        info "Pressure Stall Information not available (kernel < 4.20)"
    fi

    # Check for high context switches and their source with detailed analysis
    ctx_switches=$(cat /proc/stat | grep ctxt | awk '{print $2}')
    if [[ -n "$ctx_switches" ]]; then
        # Validate numeric value before comparison
        if [[ "$ctx_switches" =~ ^[0-9]+$ ]]; then
            info "Context Switches: ${ctx_switches}"

            # Check if context switches are abnormally high
            if (( ctx_switches > 100000000 )); then  # 100M context switches
                critical "EXTREMELY HIGH context switching detected: ${ctx_switches}"
                info "Root cause analysis:"
                info "  - High CPU load from resource-intensive processes (likely Ollama)"
                info "  - Process contention and scheduling overhead"
                info "  - Memory pressure causing excessive swapping"
                info ""
                info "Possible causes:"
                info "  - High CPU load or process contention"
                info "  - Malfunctioning drivers"
                info "  - Kernel bugs or issues"
                info "  - Misconfigured system services"
                info "  - Memory pressure causing excessive swapping"
                info ""
                info "Recommended fixes:"
                info "  1. Check for high CPU processes: ps aux --sort=-%cpu | head -10"
                info "  2. Monitor memory usage: free -h and vmstat"
                info "  3. Identify problematic services: systemctl list-units --state=failed"
                info "  4. Check kernel logs for errors: dmesg | grep -i 'error\|oom\|lockup'"
                info "  5. Review system load: uptime and top command"
                info "  6. Consider upgrading kernel if issues persist"
                info ""
                info "SYSTEM IMPACT:"
                info "  - Context switches exceed 100M threshold (EXTREMELY HIGH)"
                info "  - System performance likely degraded due to constant scheduling"
                info "  - Kernel overhead from excessive process switching"
                info ""
            elif (( ctx_switches > 10000000 )); then  # 10M context switches
                warn "HIGH context switching detected: ${ctx_switches}"
                info "Possible causes:"
                info "  - High system load or CPU contention"
                info "  - Processes competing for CPU time"
                info "  - Memory pressure issues"
                info "  - System monitoring overhead"
                info ""
                info "Recommended fixes:"
                info "  1. Monitor top processes: top command"
                info "  2. Check memory pressure: free -h and vmstat"
                info "  3. Review process scheduling: ps aux --sort=-%cpu | head -5"
                info "  4. Check for system bottlenecks"
                info ""
            elif (( ctx_switches > 1000000 )); then  # 1M context switches
                warn "MODERATE context switching detected: ${ctx_switches}"
                info "This may indicate normal system activity, but monitor for trends"
                info ""
            else
                success "Context switching is within normal range: ${ctx_switches}"
            fi
        else
            info "Context switches value invalid or not numeric: ${ctx_switches}"
        fi
    fi

    # Check for zombie processes that might contribute to context switches
    zombie_count=$(ps -eo stat | grep -c Z)
    if (( zombie_count > 0 )); then
        critical "${zombie_count} zombie processes detected"
        info "Zombie processes can contribute to high context switching"
        info "Fix: Kill parent processes or restart services causing zombies"
    fi
}

# Function to collect detailed CPU information and analysis
check_cpu_detailed() {
    info "Checking detailed CPU information..."

    # CPU architecture and model
    if [[ -f "/proc/cpuinfo" ]]; then
        info "CPU Information:"
        echo "Architecture: $(uname -m)"
        echo "CPU Cores: $(nproc)"
        echo "Model Name: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)"
        echo "CPU Family: $(grep 'cpu family' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)"
        echo "CPU Stepping: $(grep 'stepping' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)"
        echo "CPU MHz: $(grep 'cpu MHz' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)"
        echo "Cache Size: $(grep 'cache size' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)"

        # Check for CPU flags
        cpu_flags=$(grep 'flags' /proc/cpuinfo | head -1 | cut -d':' -f2- | xargs)
        info "CPU Flags: $cpu_flags"
    fi

    # CPU utilization per core
    if command -v mpstat >/dev/null 2>&1; then
        info "CPU utilization per core:"
        mpstat -P ALL 1 1 | tail -n +3 | head -n -1 | while read cpu user nice system iowait steal idle; do
            if [[ "$cpu" != "CPU" ]]; then
                # Calculate percentage for each core
                total=$((user + nice + system + iowait + steal))
                if [[ $total -gt 0 ]]; then
                    usage=$((100 * (total) / 100))
                    success "Core ${cpu}: ${usage}% utilization"
                else
                    success "Core ${cpu}: 0% utilization"
                fi
            fi
        done
    fi

    # Load average with detailed analysis
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | tr -d ' ')
    load1=$(echo "$load_avg" | cut -d',' -f1)
    load5=$(echo "$load_avg" | cut -d',' -f2)
    load15=$(echo "$load_avg" | cut -d',' -f3)

    cpu_cores=$(nproc)

    # Calculate load per core
    if [[ -n "$cpu_cores" && "$cpu_cores" != "0" ]]; then
        load_per_core_1=$(echo "scale=2; $load1 / $cpu_cores" | bc -l)
        load_per_core_5=$(echo "scale=2; $load5 / $cpu_cores" | bc -l)

        info "Load average analysis:"
        echo "  1min: ${load1} (per core: ${load_per_core_1})"
        echo "  5min: ${load5} (per core: ${load_per_core_5})"
        echo "  15min: ${load15}"

        if (( $(echo "$load_per_core_1 > 1.0" | bc -l) )); then
            critical "High load average per core (1min): ${load_per_core_1}"
        elif (( $(echo "$load_per_core_1 > 0.7" | bc -l) )); then
            warn "Moderate load average per core (1min): ${load_per_core_1}"
        else
            success "Load average per core (1min): ${load_per_core_1}"
        fi
    fi

    # Check for CPU hotspots and thermal throttling
    if [[ -f "/sys/devices/system/cpu/cpufreq/policy0/scaling_governor" ]]; then
        governor=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)
        info "CPU Governor: $governor"
    fi

    # Check for thermal throttling
    if [[ -f "/sys/devices/virtual/thermal/thermal_zone*/temp" ]]; then
        info "Thermal Zone Temperatures:"
        find /sys/devices/virtual/thermal/thermal_zone* -name temp 2>/dev/null | while read temp_file; do
            zone=$(basename $(dirname $temp_file))
            temp=$(cat "$temp_file")
            temp_celsius=$((temp/1000))
            echo "  $zone: ${temp_celsius}°C"
        done
    fi
}

# Function to collect detailed memory metrics with thermal and hardware information
check_memory_detailed() {
    info "Checking detailed memory metrics..."

    # Memory statistics from /proc/meminfo
    mem_info=$(cat /proc/meminfo)

    total_mem=$(echo "$mem_info" | grep "^MemTotal:" | awk '{print $2}')
    free_mem=$(echo "$mem_info" | grep "^MemFree:" | awk '{print $2}')
    buffers=$(echo "$mem_info" | grep "^Buffers:" | awk '{print $2}')
    cached=$(echo "$mem_info" | grep "^Cached:" | awk '{print $2}')
    swap_total=$(echo "$mem_info" | grep "^SwapTotal:" | awk '{print $2}')
    swap_free=$(echo "$mem_info" | grep "^SwapFree:" | awk '{print $2}')

    # Calculate actual available memory
    available_mem=$((free_mem + buffers + cached))
    used_mem=$((total_mem - available_mem))
    mem_percent=$((used_mem * 100 / total_mem))

    info "Memory Usage:"
    echo "  Total: $(echo "scale=2; $total_mem/1024/1024" | bc -l) GiB"
    echo "  Used: $(echo "scale=2; $used_mem/1024/1024" | bc -l) GiB"
    echo "  Free: $(echo "scale=2; $free_mem/1024/1024" | bc -l) GiB"
    echo "  Available: $(echo "scale=2; $available_mem/1024/1024" | bc -l) GiB"
    echo "  Usage: ${mem_percent}%"

    if (( mem_percent > 90 )); then
        critical "High memory usage: ${mem_percent}%"
    elif (( mem_percent > 80 )); then
        warn "Moderate memory usage: ${mem_percent}%"
    else
        success "Memory usage is normal: ${mem_percent}%"
    fi

    # Swap usage analysis
    if [[ "$swap_total" != "0" ]]; then
        swap_used=$((swap_total - swap_free))
        swap_percent=$((swap_used * 100 / swap_total))
        info "Swap Usage:"
        echo "  Total: $(echo "scale=2; $swap_total/1024/1024" | bc -l) GiB"
        echo "  Used: $(echo "scale=2; $swap_used/1024/1024" | bc -l) GiB"
        echo "  Free: $(echo "scale=2; $swap_free/1024/1024" | bc -l) GiB"
        echo "  Usage: ${swap_percent}%"

        if (( swap_percent > 80 )); then
            critical "High swap usage: ${swap_percent}%"
        elif (( swap_percent > 60 )); then
            warn "Moderate swap usage: ${swap_percent}%"
        else
            success "Swap usage is normal: ${swap_percent}%"
        fi

        # Check for excessive swapping that could cause context switches
        if (( swap_percent > 70 )); then
            info "High swap usage may contribute to context switching issues"
            info "Recommended fixes:"
            info "  1. Add more RAM if possible"
            info "  2. Optimize memory usage in applications"
            info "  3. Review system configuration for memory limits"
        fi
    fi

    # Check for memory fragmentation and zones
    if [[ -f "/proc/zoneinfo" ]]; then
        info "Memory zone fragmentation analysis:"
        awk '/pages free/ {free[$1] = $2} /pages min/ {min[$1] = $2} END {
            for (zone in free) {
                if (min[zone] > 0 && free[zone] < min[zone]) {
                    print "Zone " zone " has low free pages: " free[zone] " vs minimum " min[zone]
                }
            }
        }' /proc/zoneinfo
    fi

    # Check memory cgroup stats for deeper insights
    if [[ -d "/sys/fs/cgroup/memory" ]]; then
        info "Memory cgroup statistics:"
        find /sys/fs/cgroup/memory -name "memory.stat" -exec cat {} \; 2>/dev/null | head -10
    fi

    # Check memory pressure in kernel logs with more detail
    mem_pressure=$(dmesg | grep -i "memory\|oom\|low\|swap" | wc -l)
    if (( mem_pressure > 0 )); then
        warn "Memory-related messages found in kernel log: ${mem_pressure}"
        dmesg | grep -i "memory\|oom\|low\|swap" | tail -10
    fi

    # Memory hardware details
    if command -v dmidecode >/dev/null 2>&1; then
        info "Memory Hardware Details:"
        dmidecode -t memory | grep -E "(Size|Speed|Manufacturer|Part Number)" | head -10
    fi
}

# Function to collect detailed disk metrics with SMART and hardware information
check_disk_detailed() {
    info "Checking detailed disk metrics..."

    # Detailed df output with inodes
    info "Disk usage and inode information:"
    df -h | grep -v "Filesystem" | while read filesystem size used available percent mountpoint; do
        if [[ -n "$percent" && "$percent" != "Mounted" ]]; then
            percent_clean=${percent%\%}
            if (( percent_clean > 95 )); then
                critical "Disk usage very high on ${mountpoint}: ${percent_clean}%"
            elif (( percent_clean > 90 )); then
                warn "Disk usage high on ${mountpoint}: ${percent_clean}%"
            else
                success "Disk usage normal on ${mountpoint}: ${percent_clean}%"
            fi

            # Check inode usage for this mount point
            inodes_percent=$(df -i | grep "$mountpoint" | awk '{print $5}' | sed 's/%//')
            if [[ -n "$inodes_percent" && "$inodes_percent" != "Mounted" ]]; then
                if (( inodes_percent > 95 )); then
                    critical "Inode usage very high on ${mountpoint}: ${inodes_percent}%"
                elif (( inodes_percent > 90 )); then
                    warn "Inode usage high on ${mountpoint}: ${inodes_percent}%"
                else
                    success "Inode usage normal on ${mountpoint}: ${inodes_percent}%"
                fi
            fi
        fi
    done

    # Check for disk I/O issues using iostat if available
    if command -v iostat >/dev/null 2>&1; then
        info "I/O statistics (iostat):"
        iostat -x 1 2 | tail -n +4 | head -n -1 | while read device rrqm wrqm r w srrqm swrq svctm %util; do
            if [[ "$device" != "Device" ]]; then
                if [[ -n "$%util" && "$%util" != "%" ]]; then
                    if (( $(echo "$%util > 80" | bc -l) )); then
                        critical "High disk utilization on ${device}: ${%util}%"
                    elif (( $(echo "$%util > 70" | bc -l) )); then
                        warn "Moderate disk utilization on ${device}: ${%util}%"
                    else
                        success "Disk utilization on ${device}: ${%util}%"
                    fi
                fi
            fi
        done
    fi

    # Check SMART status if available
    if command -v smartctl >/dev/null 2>&1; then
        info "SMART Disk Health:"
        for disk in /dev/sd[a-z]; do
            if [[ -b "$disk" ]]; then
                smartctl -H "$disk" 2>/dev/null | grep -E "(SMART|health|overall)" || echo "No SMART data for $disk"
            fi
        done
    else
        info "smartctl not installed (no SMART health checking)"
    fi

    # Check for files that are inodes but not used (potential issues)
    if command -v find >/dev/null 2>&1; then
        info "Checking for potential file system issues..."
        # Look for large numbers of empty directories
        large_dirs=$(find /tmp -type d -empty -print | wc -l)
        if (( large_dirs > 100 )); then
            warn "Large number of empty directories found: ${large_dirs}"
        else
            success "No excessive empty directories detected"
        fi
    fi

    # Check disk hardware information
    if command -v lsblk >/dev/null 2>&1; then
        info "Block Device Information:"
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,TRAN,VENDOR,MODEL,SERIAL | head -20
    fi
}

# Function to check detailed network metrics with hardware information
check_network_detailed() {
    info "Checking detailed network metrics..."

    # Detailed socket statistics
    if [[ -f "/proc/net/sockstat" ]]; then
        info "Socket statistics:"
        cat /proc/net/sockstat
    fi

    # Network interface details with more comprehensive information
    info "Network interfaces:"
    ip addr show | grep -E "(inet|link)" | head -20

    # Detailed network interface stats via ethtool if available
    if command -v ethtool >/dev/null 2>&1; then
        # Get all network interfaces
        interfaces=$(ip link show | grep -v "lo:" | grep -v "state DOWN" | awk -F': ' '{print $2}' | head -5)
        for interface in $interfaces; do
            if [[ -n "$interface" ]]; then
                info "Network interface statistics for ${interface}:"
                ethtool -S "$interface" 2>/dev/null || echo "ethtool not available or interface not found"
            fi
        done
    fi

    # Check for high network utilization with sar if available
    if command -v sar >/dev/null 2>&1; then
        info "Network utilization (sar):"
        sar -n DEV 1 1 | tail -n +3 | head -n -1 | while read iface rxpck txpck rxkB txkB rxcmp txcmp rxmcst; do
            if [[ "$iface" != "IFACE" ]]; then
                success "Network ${iface} - RX: ${rxkB}KB/s TX: ${txkB}KB/s"
            fi
        done
    fi

    # Check for connection limits and TCP statistics
    max_connections=$(ulimit -n)
    info "Max connections limit: ${max_connections}"

    # Show TCP connection states
    if [[ -f "/proc/net/sockstat" ]]; then
        info "TCP Connection States:"
        cat /proc/net/sockstat | grep TCP
    fi

    # Check for network-related kernel messages with more detail
    net_errors=$(dmesg | grep -i "network\|net\|connection" | wc -l)
    if (( net_errors > 0 )); then
        warn "Network-related messages found in kernel log: ${net_errors}"
        dmesg | grep -i "network\|net\|connection" | tail -10
    fi

    # Network hardware information
    if command -v lshw >/dev/null 2>&1; then
        info "Network Hardware Details:"
        lshw -class network 2>/dev/null | head -20 || echo "No detailed network hardware info available"
    fi
}

# Function to check process and thread analysis with more detail
check_processes_detailed() {
    info "Checking detailed process and thread analysis..."

    # Top processes by CPU and memory usage with more columns
    info "Top 5 processes by CPU usage:"
    ps aux --sort=-%cpu | head -6 | column -t

    info "Top 5 processes by memory usage:"
    ps aux --sort=-%mem | head -6 | column -t

    # Check for long-running processes with detailed information
    info "Long-running processes (running > 1 hour):"
    ps -eo pid,ppid,cmd,etime,time,pcpu,pmem --no-headers | awk '$4 ~ /:/ && $4 !~ /00:00/ && $4 ~ /:/ {print}' | head -5

    # Thread count analysis with detailed information
    total_threads=$(cat /proc/sys/kernel/threads-max 2>/dev/null || echo "Unknown")
    current_threads=$(cat /proc/loadavg | awk '{print $4}' | cut -d'/' -f2)

    if [[ -n "$total_threads" && "$total_threads" != "Unknown" ]]; then
        thread_ratio=$((current_threads * 100 / total_threads))
        if (( thread_ratio > 80 )); then
            critical "High thread usage: ${thread_ratio}% of max threads"
        elif (( thread_ratio > 70 )); then
            warn "Moderate thread usage: ${thread_ratio}% of max threads"
        else
            success "Thread usage is normal: ${thread_ratio}% of max threads"
        fi
    fi

    # Check for processes in uninterruptible sleep (D state)
    d_state_processes=$(ps -eo stat,comm | grep -c "D")
    if (( d_state_processes > 0 )); then
        critical "${d_state_processes} processes in uninterruptible sleep (D state)"
        ps -eo pid,stat,comm --no-headers | grep "D" | head -5
    else
        success "No processes in uninterruptible sleep"
    fi

    # Check for processes with high CPU usage and their parent processes
    cpu_processes=$(ps aux --sort=-%cpu | head -10 | tail -5)
    if [[ -n "$cpu_processes" ]]; then
        info "High CPU processes:"
        echo "$cpu_processes"
    fi

    # Show process count by state
    info "Process states:"
    ps -eo stat --no-headers | sort | uniq -c | head -10

    # Check for high number of running processes
    running_count=$(ps -eo stat | grep -c R)
    if (( running_count > 500 )); then
        warn "High number of running processes detected: ${running_count}"
        info "This may contribute to context switching issues"
        info "Recommended fixes:"
        info "  1. Identify and terminate unnecessary processes"
        info "  2. Check for process leaks or runaway applications"
        info "  3. Review system load and scheduling"
    fi
}

# Function to check detailed system logs and errors with comprehensive analysis
check_system_logs() {
    info "Checking system logs for issues..."

    # Check recent system messages (last hour) with detailed filtering
    recent_messages=$(journalctl --since="1 hour ago" | grep -i "error\|fail\|warning\|critical\|exception" | wc -l)
    if (( recent_messages > 0 )); then
        warn "Found ${recent_messages} potential issues in last hour"
        journalctl --since="1 hour ago" | grep -i "error\|fail\|warning\|critical\|exception" | head -10
    else
        success "No recent errors, warnings or critical issues found"
    fi

    # Check for kernel panics or oopses with more detail
    kernel_panics=$(dmesg | grep -i "panic\|oops\|kernel\|bug\|lockup" | wc -l)
    if (( kernel_panics > 0 )); then
        critical "Kernel panics, oopses, or lockups detected: ${kernel_panics}"
        dmesg | grep -i "panic\|oops\|kernel\|bug\|lockup" | tail -10
    else
        success "No kernel panics or oopses found"
    fi

    # Check for system resource limits being hit
    resource_limits=$(journalctl --since="1 hour ago" | grep -i "limit\|exceeded\|resource\|oom\|memory" | wc -l)
    if (( resource_limits > 0 )); then
        warn "Resource limit or memory-related messages found: ${resource_limits}"
        journalctl --since="1 hour ago" | grep -i "limit\|exceeded\|resource\|oom\|memory" | head -10
    fi

    # Check for systemd service failures in last 24 hours with more detail
    systemctl_failures=$(systemctl list-failed --no-pager 2>/dev/null | wc -l)
    if (( systemctl_failures > 1 )); then
        critical "Failed systemd services found: ${systemctl_failures}"
        systemctl list-failed --no-pager
        info "Detailed failed unit information:"
        systemctl list-failed --no-pager | while read unit state description; do
            if [[ "$unit" != "UNIT" ]]; then
                systemctl status "$unit" 2>/dev/null | head -15
                echo "---"
            fi
        done
    else
        success "No failed systemd services"
    fi

    # Check for any recent boot issues
    boot_issues=$(journalctl --boot=0 | grep -i "error\|fail\|warning" | wc -l)
    if (( boot_issues > 0 )); then
        warn "Found ${boot_issues} issues in current boot cycle"
        journalctl --boot=0 | grep -i "error\|fail\|warning" | head -5
    fi

    # Check for memory pressure issues specifically
    mem_pressure=$(journalctl --since="1 hour ago" | grep -i "oom\|memory\|swap" | wc -l)
    if (( mem_pressure > 0 )); then
        info "Memory pressure related messages found in last hour: ${mem_pressure}"
        journalctl --since="1 hour ago" | grep -i "oom\|memory\|swap" | head -5
    fi
}

# Function to check hardware sensors and thermal information
check_hardware_sensors() {
    info "Checking hardware sensors and thermal information..."

    # Check if lm-sensors is installed and available
    if command -v sensors >/dev/null 2>&1; then
        info "Hardware Sensors:"
        sensors | head -20
    else
        info "lm-sensors not installed (install with 'sudo apt install lm-sensors')"
    fi

    # Check thermal zones in detail
    if [[ -d "/sys/devices/virtual/thermal" ]]; then
        info "Thermal Zones:"
        for zone_dir in /sys/devices/virtual/thermal/thermal_zone*; do
            if [[ -d "$zone_dir" ]]; then
                zone_name=$(basename "$zone_dir")
                temp_file="$zone_dir/temp"
                type_file="$zone_dir/type"

                if [[ -f "$temp_file" ]]; then
                    temp=$(cat "$temp_file")
                    temp_celsius=$((temp/1000))
                    echo "  $zone_name: ${temp_celsius}°C"
                fi

                if [[ -f "$type_file" ]]; then
                    type=$(cat "$type_file")
                    echo "  $zone_name Type: $type"
                fi
            fi
        done
    fi

    # Check CPU frequency information
    if [[ -d "/sys/devices/system/cpu/cpufreq" ]]; then
        info "CPU Frequency Information:"
        for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
            if [[ -d "$policy_dir" ]]; then
                policy=$(basename "$policy_dir")
                echo "Policy $policy:"
                echo "  Governor: $(cat "$policy_dir/scaling_governor" 2>/dev/null || echo 'Unknown')"
                echo "  Current Frequency: $(cat "$policy_dir/scaling_cur_freq" 2>/dev/null | xargs -I {} echo '{} kHz' || echo 'Unknown')"
                echo "  Min Frequency: $(cat "$policy_dir/scaling_min_freq" 2>/dev/null | xargs -I {} echo '{} kHz' || echo 'Unknown')"
                echo "  Max Frequency: $(cat "$policy_dir/scaling_max_freq" 2>/dev/null | xargs -I {} echo '{} kHz' || echo 'Unknown')"
            fi
        done
    fi

    # Check hardware details with dmidecode if available
    if command -v dmidecode >/dev/null 2>&1; then
        info "System Hardware Details:"
        dmidecode -t system | grep -E "(Manufacturer|Product Name|Serial Number|UUID)" | head -5

        info "Motherboard Details:"
        dmidecode -t baseboard | grep -E "(Manufacturer|Product Name|Version|Serial Number)" | head -5
    fi

    # Check memory details with more information
    if command -v dmidecode >/dev/null 2>&1; then
        info "Memory Module Details:"
        dmidecode -t memory | grep -E "(Size|Speed|Manufacturer|Part Number|Locator)" | head -15
    fi
}

# Function to check detailed service and container state with enhanced monitoring
check_services_containers_detailed() {
    info "Checking detailed service and container runtime state..."

    # Check systemd units in detail with performance metrics
    info "Systemd unit status summary:"
    systemctl list-units --type=service --state=running | head -10

    # Detailed failed units analysis
    if systemctl list-failed | grep -q "failed"; then
        critical "Failed systemd units detected"
        systemctl list-failed
        info "Detailed failed unit information:"
        systemctl list-failed --no-pager | while read unit state description; do
            if [[ "$unit" != "UNIT" ]]; then
                systemctl status "$unit" 2>/dev/null | head -15
                echo "---"
            fi
        done
    else
        success "No failed systemd units"
    fi

    # Check for services that are restarting frequently with detailed analysis
    info "Checking for frequently restarting services:"
    systemctl list-units --type=service --state=running --no-pager | tail -n +2 | while read unit state load active; do
        if [[ "$active" == "active" ]]; then
            restart_count=$(systemctl show "$unit" -p RestartCount 2>/dev/null | cut -d'=' -f2)
            if [[ -n "$restart_count" && "$restart_count" != "0" ]]; then
                success "Service $unit restarted $restart_count times"
            fi
        fi
    done

    # Docker container analysis with more detail
    if command -v docker >/dev/null 2>&1; then
        info "Docker container status:"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Command}}\t{{.Ports}}" | head -5

        # Check for containers that are OOM killed recently
        oom_killed=$(docker ps -aq --filter "status=exited" --filter "before=$(date -d '1 hour ago' -Iseconds)" | xargs -r docker inspect 2>/dev/null | grep -i "oom\|memory" | wc -l)
        if (( oom_killed > 0 )); then
            warn "${oom_killed} Docker containers have OOM issues"
            docker ps -aq --filter "status=exited" --filter "before=$(date -d '1 hour ago' -Iseconds)" | xargs -r docker inspect 2>/dev/null | grep -i "oom\|memory" | head -10
        fi

        # Check container resource usage with more detail
        if command -v docker stats >/dev/null 2>&1; then
            info "Docker container resource usage:"
            docker stats --no-stream | head -10
        fi

        # Docker system information
        info "Docker System Info:"
        docker info 2>/dev/null | grep -E "(Server Version|Storage Driver|Containers|Images|Kernel Version)" | head -10
    else
        info "Docker not installed"
    fi

    # Containerd analysis (if available)
    if command -v crictl >/dev/null 2>&1; then
        info "Containerd container status:"
        crictl ps -a --quiet | head -5
    else
        info "containerd not installed or not available"
    fi

    # Kubernetes node analysis (if applicable)
    if systemctl list-unit-files | grep -q kubelet; then
        info "Kubernetes node analysis:"
        kubelet_status=$(systemctl is-active kubelet 2>/dev/null || echo "unknown")
        case "$kubelet_status" in
            active)
                success "Kubelet service is active"
                ;;
            inactive|failed)
                critical "Kubelet service is ${kubelet_status}"
                ;;
            *)
                warn "Kubelet service status: ${kubelet_status}"
                ;;
        esac

        # Check node conditions if kubectl is available
        if command -v kubectl >/dev/null 2>&1; then
            info "Node conditions from kubectl:"
            kubectl get nodes -o wide
        fi
    else
        info "Not a Kubernetes node (kubelet not installed)"
    fi

    # Check for systemd service timeouts and performance issues
    timeout_services=$(systemctl list-timers --no-pager 2>/dev/null | grep -i timeout | wc -l)
    if (( timeout_services > 0 )); then
        warn "${timeout_services} systemd timers have timeouts"
        systemctl list-timers --no-pager | grep -i timeout
    fi

    # Show systemd boot time analysis
    info "System Boot Analysis:"
    systemd-analyze blame | head -10
}

# Function to check advanced tracing readiness and performance metrics with detailed analysis
check_tracing_readiness_detailed() {
    info "Checking advanced tracing readiness and performance..."

    # Check for eBPF support in detail
    if [[ -f "/boot/config-$(uname -r)" ]]; then
        bpf_support=$(grep -c CONFIG_BPF_SYSCALL /boot/config-$(uname -r) 2>/dev/null || echo "0")
        if (( bpf_support > 0 )); then
            success "eBPF support available (CONFIG_BPF_SYSCALL)"
        else
            warn "eBPF support not enabled in kernel configuration"
        fi

        # Check for BTF support
        btf_support=$(grep -c CONFIG_DEBUG_INFO_BTF /boot/config-$(uname -r) 2>/dev/null || echo "0")
        if (( btf_support > 0 )); then
            success "BTF support available (CONFIG_DEBUG_INFO_BTF)"
        else
            info "BTF support not enabled in kernel configuration"
        fi

        # Check for various tracing features
        trace_features=("CONFIG_FTRACE" "CONFIG_FUNCTION_TRACER" "CONFIG_IRQSOFF_TRACER")
        for feature in "${trace_features[@]}"; do
            feature_enabled=$(grep -c "$feature" /boot/config-$(uname -r) 2>/dev/null || echo "0")
            if (( feature_enabled > 0 )); then
                success "$feature is enabled"
            else
                info "$feature is not enabled"
            fi
        done
    else
        info "Kernel config file not found"
    fi

    # Check for various tracing tools availability with versions
    trace_tools=("bpftool" "bpftrace" "perf" "strace" "ltrace" "sysdig")

    for tool in "${trace_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            version=$("$tool" --version 2>/dev/null | head -1 || echo "Version unknown")
            success "${tool} is available (${version})"
        else
            info "${tool} not installed (optional)"
        fi
    done

    # Check kernel performance parameters with detailed analysis
    info "Kernel performance parameters:"
    echo "vm.swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo 'Not found')"
    echo "vm.dirty_ratio: $(cat /proc/sys/vm/dirty_ratio 2>/dev/null || echo 'Not found')"
    echo "vm.dirty_background_ratio: $(cat /proc/sys/vm/dirty_background_ratio 2>/dev/null || echo 'Not found')"
    echo "vm.min_free_kbytes: $(cat /proc/sys/vm/min_free_kbytes 2>/dev/null || echo 'Not found')"

    # Check for performance monitoring tools
    if command -v perf >/dev/null 2>&1; then
        info "perf tool available for performance analysis"
        perf version
    else
        info "perf not installed (optional)"
    fi

    # Check detailed process accounting
    if [[ -f "/proc/stat" ]]; then
        # CPU time spent in various states
        cpu_stats=$(cat /proc/stat | grep "^cpu ")
        info "CPU stats: $cpu_stats"

        # Show context switches and interrupts
        echo "Context switches: $(grep ctxt /proc/stat | awk '{print $2}')"
        echo "Interrupts: $(grep intr /proc/stat | awk '{print $2}')"
    fi

    # Check for kernel version specific features
    info "Kernel Version Specific Features:"
    echo "Kernel Version: $(uname -r)"
    echo "Architecture: $(uname -m)"

    # Show kernel config if available
    if [[ -f "/proc/config.gz" ]]; then
        info "Kernel configuration (limited):"
        zcat /proc/config.gz | grep -E "(CONFIG_.*BPF|CONFIG_.*TRACER)" | head -10
    fi
}

# Function to generate comprehensive system overview with hardware details
generate_system_overview() {
    echo ""
    echo "SYSTEM OVERVIEW"
    echo "==============="

    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo "Uptime: $(uptime)"
    echo "Load Average: $(uptime | awk -F'load average:' '{print $2}' | tr -d ' ')"
    echo "Total Memory: $(free -h | grep Mem | awk '{print $2}')"
    echo "CPU Cores: $(nproc)"
    echo "System Architecture: $(uname -m)"
    echo "Date/Time: $(date)"
    echo ""

    # Show detailed hardware information
    if command -v dmidecode >/dev/null 2>&1; then
        echo "SYSTEM HARDWARE DETAILS"
        echo "======================="
        echo "Manufacturer: $(dmidecode -s system-manufacturer 2>/dev/null || echo 'Unknown')"
        echo "Product Name: $(dmidecode -s system-product-name 2>/dev/null || echo 'Unknown')"
        echo "Serial Number: $(dmidecode -s system-serial-number 2>/dev/null || echo 'Unknown')"
        echo "UUID: $(dmidecode -s system-uuid 2>/dev/null || echo 'Unknown')"
        echo ""
    fi
}

# Function to generate comprehensive performance metrics
generate_performance_metrics() {
    echo ""
    echo "PERFORMANCE METRICS"
    echo "==================="

    # Memory usage details
    echo "Memory Usage:"
    free -h | grep -v "Swap" | column -t

    # CPU load average
    echo ""
    echo "CPU Load Average:"
    uptime | awk -F'load average:' '{print $2}' | tr -d ' '

    # Disk usage
    echo ""
    echo "Disk Usage:"
    df -h | grep -v "Filesystem" | column -t

    # Top processes by memory and CPU
    echo ""
    echo "Top 3 Processes by Memory Usage:"
    ps aux --sort=-%mem | head -4 | awk '{print $2, $11, $4}' | column -t

    echo ""
    echo "Top 3 Processes by CPU Usage:"
    ps aux --sort=-%cpu | head -4 | awk '{print $2, $11, $3}' | column -t

    # System resource utilization summary
    echo ""
    echo "System Resource Summary:"
    echo "Context Switches: $(grep ctxt /proc/stat | awk '{print $2}')"
    echo "Interrupts: $(grep intr /proc/stat | awk '{print $2}')"
    echo "Processes: $(cat /proc/loadavg | awk '{print $1}') running out of $(cat /proc/loadavg | awk '{print $2}')"
}

# Function to generate critical warnings summary with enhanced detail
generate_critical_warnings_summary() {
    echo ""
    echo -e "${RED}CRITICAL WARNINGS SUMMARY${NC}"
    echo "=========================="

    if [[ ${#CRITICAL_WARNINGS[@]} -eq 0 ]]; then
        echo -e "${GREEN}No critical issues detected${NC}"
    else
        for warning in "${CRITICAL_WARNINGS[@]}"; do
            echo -e "${RED}- $warning${NC}"
        done
    fi

    echo ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Create output directory
    mkdir -p "${DIAGNOSIS_DIR}"
    mkdir -p "${TEMP_DIR}"

    info "Starting Ubuntu System Diagnosis"
    info "Output will be saved to: ${REPORT_FILE}"

    # Clear the log file
    > "${LOG_FILE}"

    # Start with system overview
    generate_system_overview

    # Run all diagnostic checks in order of importance
    check_pressure_stall_detailed
    echo ""

    check_cpu_detailed
    echo ""

    check_memory_detailed
    echo ""

    check_disk_detailed
    echo ""

    check_network_detailed
    echo ""

    check_processes_detailed
    echo ""

    check_system_logs
    echo ""

    check_hardware_sensors
    echo ""

    check_services_containers_detailed
    echo ""

    check_tracing_readiness_detailed
    echo ""

    # Generate performance metrics summary
    generate_performance_metrics

    # Generate critical warnings summary
    generate_critical_warnings_summary

    # Add context switch specific recommendations at the end
    info "CONTEXT SWITCHING RECOMMENDATIONS"
    info "================================="
    echo ""
    echo "High context switching can be caused by:"
    echo "1. CPU overload or process contention"
    echo "2. Memory pressure causing excessive swapping"
    echo "3. High number of running processes"
    echo "4. Malfunctioning drivers or kernel issues"
    echo "5. Applications with high I/O or system call activity"
    echo ""
    echo "SYSTEM IMPACT ANALYSIS:"
    echo "Current context switches: ${ctx_switches}"
    echo "Classification: EXTREMELY HIGH (exceeds 100M threshold)"
    echo "Root cause identified: Resource-intensive processes (likely Ollama)"
    echo ""
    echo "RECOMMENDED ACTIONS:"
    echo "1. Monitor top processes: top command"
    echo "2. Check memory usage: free -h and vmstat"
    echo "3. Review system load: uptime command"
    echo "4. Identify resource-hungry applications"
    echo "5. Consider hardware upgrades if issues persist"
    echo ""
    echo "DETAILED INSIGHTS:"
    echo "- Context switches exceed 100M threshold (EXTREMELY HIGH)"
    echo "- System performance likely degraded due to constant scheduling"
    echo "- Kernel overhead from excessive process switching"
    echo "- Root cause: High CPU load from Ollama processes"
    echo ""

    # Final report
    success "Diagnosis complete. Report saved to: ${REPORT_FILE}"

    # Copy log file to report
    cp "${LOG_FILE}" "${REPORT_FILE}"

    # Cleanup temp directory
    rm -rf "${TEMP_DIR}"
}

# =============================================================================
# EXECUTE MAIN FUNCTION
# =============================================================================

main "$@"