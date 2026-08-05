#!/usr/bin/env bash

# =============================================================================
# Ubuntu System Diagnosis Script - Principal Site Reliability Engineer
# =============================================================================
# This comprehensive diagnostic script evaluates system health across the SRE
# golden signals (latency, traffic, errors, saturation) using only standard
# Ubuntu admin packages. It provides structured health reporting with color-coded
# output and critical warnings summary.
#
# Requirements: sysstat, iproute2, systemd, procps, bc
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
            cpu_some=$(extract_pressure_value "/proc/pressure/cpu" "some")
            cpu_full=$(extract_pressure_value "/proc/pressure/cpu" "full")

            if [[ -n "$cpu_some" && "$cpu_some" != "0" ]]; then
                # Ensure we have a valid numeric value
                if [[ "$cpu_some" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    if (( $(echo "$cpu_some > 0.1" | bc -l) )); then
                        warn "High CPU some pressure detected: ${cpu_some}"
                    else
                        success "CPU some pressure is normal: ${cpu_some}"
                    fi
                else
                    info "CPU some pressure value invalid or not numeric: ${cpu_some}"
                fi
            else
                success "CPU some pressure is normal: 0.0"
            fi

            if [[ -n "$cpu_full" && "$cpu_full" != "0" ]]; then
                # Ensure we have a valid numeric value
                if [[ "$cpu_full" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    if (( $(echo "$cpu_full > 0.1" | bc -l) )); then
                        critical "High CPU full pressure detected: ${cpu_full}"
                    else
                        success "CPU full pressure is normal: ${cpu_full}"
                    fi
                else
                    info "CPU full pressure value invalid or not numeric: ${cpu_full}"
                fi
            else
                success "CPU full pressure is normal: 0.0"
            fi
        fi

        # Check memory pressure in detail
        if [[ -f "/proc/pressure/memory" ]]; then
            mem_some=$(extract_pressure_value "/proc/pressure/memory" "some")
            mem_full=$(extract_pressure_value "/proc/pressure/memory" "full")

            if [[ -n "$mem_some" && "$mem_some" != "0" ]]; then
                # Ensure we have a valid numeric value
                if [[ "$mem_some" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    if (( $(echo "$mem_some > 0.1" | bc -l) )); then
                        warn "High memory some pressure detected: ${mem_some}"
                    else
                        success "Memory some pressure is normal: ${mem_some}"
                    fi
                else
                    info "Memory some pressure value invalid or not numeric: ${mem_some}"
                fi
            else
                success "Memory some pressure is normal: 0.0"
            fi

            if [[ -n "$mem_full" && "$mem_full" != "0" ]]; then
                # Ensure we have a valid numeric value
                if [[ "$mem_full" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    if (( $(echo "$mem_full > 0.1" | bc -l) )); then
                        critical "High memory full pressure detected: ${mem_full}"
                    else
                        success "Memory full pressure is normal: ${mem_full}"
                    fi
                else
                    info "Memory full pressure value invalid or not numeric: ${mem_full}"
                fi
            else
                success "Memory full pressure is normal: 0.0"
            fi
        fi

        # Check I/O pressure in detail
        if [[ -f "/proc/pressure/io" ]]; then
            io_some=$(extract_pressure_value "/proc/pressure/io" "some")
            io_full=$(extract_pressure_value "/proc/pressure/io" "full")

            if [[ -n "$io_some" && "$io_some" != "0" ]]; then
                # Ensure we have a valid numeric value
                if [[ "$io_some" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    if (( $(echo "$io_some > 0.1" | bc -l) )); then
                        warn "High I/O some pressure detected: ${io_some}"
                    else
                        success "I/O some pressure is normal: ${io_some}"
                    fi
                else
                    info "I/O some pressure value invalid or not numeric: ${io_some}"
                fi
            else
                success "I/O some pressure is normal: 0.0"
            fi

            if [[ -n "$io_full" && "$io_full" != "0" ]]; then
                # Ensure we have a valid numeric value
                if [[ "$io_full" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    if (( $(echo "$io_full > 0.1" | bc -l) )); then
                        critical "High I/O full pressure detected: ${io_full}"
                    else
                        success "I/O full pressure is normal: ${io_full}"
                    fi
                else
                    info "I/O full pressure value invalid or not numeric: ${io_full}"
                fi
            else
                success "I/O full pressure is normal: 0.0"
            fi
        fi
    else
        info "Pressure Stall Information not available (kernel < 4.20)"
    fi

    # Check for high context switches and their source
    ctx_switches=$(cat /proc/stat | grep ctxt | awk '{print $2}')
    if [[ -n "$ctx_switches" ]]; then
        # Validate numeric value before comparison
        if [[ "$ctx_switches" =~ ^[0-9]+$ ]]; then
            if (( ctx_switches > 1000000 )); then
                critical "High context switching detected: ${ctx_switches} switches"
            elif (( ctx_switches > 500000 )); then
                warn "Moderate context switching detected: ${ctx_switches} switches"
            else
                success "Context switching is normal: ${ctx_switches} switches"
            fi
        else
            info "Context switching value invalid or not numeric: ${ctx_switches}"
        fi
    fi

    # Check for zombie processes and their origins
    zombie_count=$(ps -eo stat,comm | grep -c Z)
    if (( zombie_count > 0 )); then
        critical "${zombie_count} zombie processes detected"
        ps aux | grep -w Z | head -5
        info "Zombie process details:"
        ps -eo pid,ppid,stat,time,comm --no-headers | grep Z
    else
        success "No zombie processes found"
    fi
}

# Function to collect detailed CPU metrics
check_cpu_detailed() {
    info "Checking detailed CPU metrics..."

    # CPU utilization per core
    if command -v mpstat >/dev/null 2>&1; then
        info "CPU utilization per core:"
        mpstat -P ALL 1 1 | tail -n +3 | head -n -1 | while read cpu user nice system iowait steal idle; do
            if [[ "$cpu" != "CPU" ]]; then
                if [[ -n "$idle" && "$idle" != "IDLE" ]]; then
                    usage=$((100 - idle))
                    if (( usage > 85 )); then
                        critical "High CPU utilization on core ${cpu}: ${usage}%"
                    elif (( usage > 70 )); then
                        warn "Moderate CPU utilization on core ${cpu}: ${usage}%"
                    else
                        success "CPU utilization on core ${cpu}: ${usage}%"
                    fi
                fi
            fi
        done
    fi

    # Load average
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | tr -d ' ')
    load1=$(echo "$load_avg" | cut -d',' -f1)
    load5=$(echo "$load_avg" | cut -d',' -f2)
    load15=$(echo "$load_avg" | cut -d',' -f3)

    # Compare against CPU cores
    cpu_cores=$(nproc)
    load_per_core_1=$(echo "scale=2; $load1 / $cpu_cores" | bc -l)
    load_per_core_5=$(echo "scale=2; $load5 / $cpu_cores" | bc -l)

    if (( $(echo "$load_per_core_1 > 1.0" | bc -l) )); then
        critical "High load average per core (1min): ${load_per_core_1}"
    elif (( $(echo "$load_per_core_1 > 0.7" | bc -l) )); then
        warn "Moderate load average per core (1min): ${load_per_core_1}"
    else
        success "Load average per core (1min): ${load_per_core_1}"
    fi

    # Check for CPU hotspots
    top_processes=$(top -bn1 | grep "^%Cpu" | awk '{print $2}' | cut -d'%' -f1)
    if [[ -n "$top_processes" ]]; then
        success "CPU usage breakdown: ${top_processes}"
    fi
}

# Function to collect detailed memory metrics
check_memory_detailed() {
    info "Checking detailed memory metrics..."

    # Memory statistics from /proc/meminfo
    mem_info=$(cat /proc/meminfo)

    total_mem=$(echo "$mem_info" | grep "^MemTotal:" | awk '{print $2}')
    free_mem=$(echo "$mem_info" | grep "^MemFree:" | awk '{print $2}')
    buffers=$(echo "$mem_info" | grep "^Buffers:" | awk '{print $2}')
    cached=$(echo "$mem_info" | grep "^Cached:" | awk '{print $2}')

    # Calculate actual available memory
    available_mem=$((free_mem + buffers + cached))
    used_mem=$((total_mem - available_mem))
    mem_percent=$((used_mem * 100 / total_mem))

    if (( mem_percent > 90 )); then
        critical "High memory usage: ${mem_percent}%"
    elif (( mem_percent > 80 )); then
        warn "Moderate memory usage: ${mem_percent}%"
    else
        success "Memory usage is normal: ${mem_percent}%"
    fi

    # Check for memory fragmentation
    if [[ -f "/proc/zoneinfo" ]]; then
        info "Checking memory zone fragmentation..."
        awk '/pages free/ {free[$1] = $2} /pages min/ {min[$1] = $2} END {
            for (zone in free) {
                if (min[zone] > 0 && free[zone] < min[zone]) {
                    print "Zone " zone " has low free pages: " free[zone] " vs minimum " min[zone]
                }
            }
        }' /proc/zoneinfo
    fi

    # Check for memory pressure via memory cgroup stats
    if [[ -d "/sys/fs/cgroup/memory" ]]; then
        mem_stats=$(find /sys/fs/cgroup/memory -name "memory.stat" -exec cat {} \; 2>/dev/null | head -10)
        if [[ -n "$mem_stats" ]]; then
            info "Memory cgroup stats:"
            echo "$mem_stats"
        fi
    fi

    # Check for memory pressure in kernel logs
    mem_pressure=$(dmesg | grep -i "memory\|oom\|low\|swap" | wc -l)
    if (( mem_pressure > 0 )); then
        warn "Memory-related messages found in kernel log: ${mem_pressure}"
        dmesg | grep -i "memory\|oom\|low\|swap" | tail -5
    fi
}

# Function to collect detailed disk metrics
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
        info "I/O statistics:"
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
}

# Function to check detailed network metrics
check_network_detailed() {
    info "Checking detailed network metrics..."

    # Detailed socket statistics
    if [[ -f "/proc/net/sockstat" ]]; then
        info "Socket statistics:"
        cat /proc/net/sockstat
    fi

    # Network interface details
    info "Network interfaces:"
    ip addr show | grep -E "(inet|link)" | head -20

    # Check for network errors via ethtool if available
    if command -v ethtool >/dev/null 2>&1; then
        # Get first non-loopback interface
        interface=$(ip route | grep '^default' | head -1 | awk '{print $5}' | head -1)
        if [[ -n "$interface" ]]; then
            info "Network interface statistics for ${interface}:"
            ethtool -S "$interface" 2>/dev/null || echo "ethtool not available or interface not found"
        fi
    fi

    # Check for high network utilization
    if command -v sar >/dev/null 2>&1; then
        info "Network utilization:"
        sar -n DEV 1 1 | tail -n +3 | head -n -1 | while read iface rxpck txpck rxkB txkB rxcmp txcmp rxmcst; do
            if [[ "$iface" != "IFACE" ]]; then
                success "Network ${iface} - RX: ${rxkB}KB/s TX: ${txkB}KB/s"
            fi
        done
    fi

    # Check for connection limits
    max_connections=$(ulimit -n)
    info "Max connections limit: ${max_connections}"

    # Check for network-related kernel messages
    net_errors=$(dmesg | grep -i "network\|net\|connection" | wc -l)
    if (( net_errors > 0 )); then
        warn "Network-related messages found in kernel log: ${net_errors}"
        dmesg | grep -i "network\|net\|connection" | tail -5
    fi
}

# Function to check process and thread analysis
check_processes_detailed() {
    info "Checking detailed process and thread analysis..."

    # Top processes by CPU and memory usage
    info "Top 5 processes by CPU usage:"
    ps aux --sort=-%cpu | head -6 | column -t

    info "Top 5 processes by memory usage:"
    ps aux --sort=-%mem | head -6 | column -t

    # Check for long-running processes
    long_running=$(ps -eo pid,ppid,cmd,etime --no-headers | awk '$4 ~ /:/ && $4 !~ /00:00/ {print}' | head -5)
    if [[ -n "$long_running" ]]; then
        info "Long-running processes:"
        echo "$long_running"
    fi

    # Thread count analysis
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

    # Check for processes with high CPU usage
    cpu_processes=$(ps aux --sort=-%cpu | head -10 | tail -5)
    if [[ -n "$cpu_processes" ]]; then
        info "High CPU processes:"
        echo "$cpu_processes"
    fi
}

# Function to check detailed system logs and errors
check_system_logs() {
    info "Checking system logs for issues..."

    # Check recent system messages (last hour)
    recent_messages=$(journalctl --since="1 hour ago" | grep -i "error\|fail\|warning\|critical" | wc -l)
    if (( recent_messages > 0 )); then
        warn "Found ${recent_messages} potential issues in last hour"
        journalctl --since="1 hour ago" | grep -i "error\|fail\|warning\|critical" | head -5
    else
        success "No recent errors or warnings found"
    fi

    # Check for kernel panics or oopses
    kernel_panics=$(dmesg | grep -i "panic\|oops\|kernel" | wc -l)
    if (( kernel_panics > 0 )); then
        critical "Kernel panics or oopses detected: ${kernel_panics}"
        dmesg | grep -i "panic\|oops\|kernel" | tail -5
    else
        success "No kernel panics or oopses found"
    fi

    # Check for system resource limits being hit
    resource_limits=$(journalctl --since="1 hour ago" | grep -i "limit\|exceeded\|resource" | wc -l)
    if (( resource_limits > 0 )); then
        warn "Resource limit messages found: ${resource_limits}"
        journalctl --since="1 hour ago" | grep -i "limit\|exceeded\|resource" | head -5
    fi

    # Check for systemd service failures in last 24 hours
    systemctl_failures=$(systemctl list-failed --no-pager 2>/dev/null | wc -l)
    if (( systemctl_failures > 1 )); then
        critical "Failed systemd services found: ${systemctl_failures}"
        systemctl list-failed --no-pager
    else
        success "No failed systemd services"
    fi
}

# Function to check detailed service and container state
check_services_containers_detailed() {
    info "Checking detailed service and container runtime state..."

    # Check systemd units in detail
    info "Systemd unit status summary:"
    systemctl list-units --type=service --state=running | head -10

    # Detailed failed units analysis
    if systemctl list-failed | grep -q "failed"; then
        critical "Failed systemd units detected"
        systemctl list-failed
        info "Detailed failed unit information:"
        systemctl list-failed --no-pager | while read unit state description; do
            if [[ "$unit" != "UNIT" ]]; then
                systemctl status "$unit" 2>/dev/null | head -10
                echo "---"
            fi
        done
    else
        success "No failed systemd units"
    fi

    # Check for services that are restarting frequently
    info "Checking for frequently restarting services:"
    systemctl list-units --type=service --state=running --no-pager | tail -n +2 | while read unit state load active; do
        if [[ "$active" == "active" ]]; then
            restart_count=$(systemctl show "$unit" -p RestartCount 2>/dev/null | cut -d'=' -f2)
            if [[ -n "$restart_count" && "$restart_count" != "0" ]]; then
                success "Service $unit restarted $restart_count times"
            fi
        fi
    done

    # Docker container analysis
    if command -v docker >/dev/null 2>&1; then
        info "Docker container status:"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Command}}" | head -5

        # Check for containers that are OOM killed recently
        oom_killed=$(docker ps -aq --filter "status=exited" --filter "before=$(date -d '1 hour ago' -Iseconds)" | xargs -r docker inspect 2>/dev/null | grep -i "oom\|memory" | wc -l)
        if (( oom_killed > 0 )); then
            warn "${oom_killed} Docker containers have OOM issues"
            docker ps -aq --filter "status=exited" --filter "before=$(date -d '1 hour ago' -Iseconds)" | xargs -r docker inspect 2>/dev/null | grep -i "oom\|memory" | head -5
        fi

        # Check container resource usage
        if command -v docker stats >/dev/null 2>&1; then
            info "Docker container resource usage:"
            docker stats --no-stream | head -5
        fi
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

    # Check for systemd service timeouts
    timeout_services=$(systemctl list-timers --no-pager 2>/dev/null | grep -i timeout | wc -l)
    if (( timeout_services > 0 )); then
        warn "${timeout_services} systemd timers have timeouts"
        systemctl list-timers --no-pager | grep -i timeout
    fi
}

# Function to check advanced tracing readiness and performance metrics
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
    else
        info "Kernel config file not found"
    fi

    # Check for various tracing tools availability
    trace_tools=("bpftool" "bpftrace" "perf" "strace" "ltrace")

    for tool in "${trace_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            success "${tool} is available"
        else
            info "${tool} not installed (optional)"
        fi
    done

    # Check kernel performance parameters
    info "Kernel performance parameters:"
    echo "vm.swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo 'Not found')"
    echo "vm.dirty_ratio: $(cat /proc/sys/vm/dirty_ratio 2>/dev/null || echo 'Not found')"
    echo "vm.dirty_background_ratio: $(cat /proc/sys/vm/dirty_background_ratio 2>/dev/null || echo 'Not found')"

    # Check for performance monitoring tools
    if command -v perf >/dev/null 2>&1; then
        info "perf tool available for performance analysis"
        perf version
    else
        info "perf not installed (optional)"
    fi

    # Check for detailed process accounting
    if [[ -f "/proc/stat" ]]; then
        # CPU time spent in various states
        cpu_stats=$(cat /proc/stat | grep "^cpu ")
        info "CPU stats: $cpu_stats"
    fi
}

# Function to generate comprehensive system overview
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
}

# Function to generate critical warnings summary
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

    check_services_containers_detailed
    echo ""

    check_tracing_readiness_detailed
    echo ""

    # Generate performance metrics summary
    generate_performance_metrics

    # Generate critical warnings summary
    generate_critical_warnings_summary

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