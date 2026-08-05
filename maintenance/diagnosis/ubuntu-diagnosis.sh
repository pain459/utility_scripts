#!/usr/bin/env bash

# =============================================================================
# Ubuntu System Diagnosis Script - Principal Site Reliability Engineer
# =============================================================================
# This comprehensive diagnostic script evaluates system health across the SRE
# golden signals (latency, traffic, errors, saturation) using only standard
# Ubuntu admin packages. It provides structured health reporting with color-coded
# output and critical warnings summary.
#
# Requirements: sysstat, iproute2, systemd, procps
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
# DIAGNOSTIC FUNCTIONS
# =============================================================================

# Function to check pressure stall information (PSI)
check_pressure_stall() {
    info "Checking Pressure Stall Information (PSI)..."

    if [[ -d "/proc/pressure" ]]; then
        # Check CPU pressure
        if [[ -f "/proc/pressure/cpu" ]]; then
            cpu_pressure=$(cat /proc/pressure/cpu | awk '{print $2}' | cut -d'=' -f2)
            if (( $(echo "$cpu_pressure > 0.1" | bc -l) )); then
                warn "High CPU pressure detected: ${cpu_pressure}"
            else
                success "CPU pressure is normal: ${cpu_pressure}"
            fi
        fi

        # Check memory pressure
        if [[ -f "/proc/pressure/memory" ]]; then
            mem_pressure=$(cat /proc/pressure/memory | awk '{print $2}' | cut -d'=' -f2)
            if (( $(echo "$mem_pressure > 0.1" | bc -l) )); then
                warn "High memory pressure detected: ${mem_pressure}"
            else
                success "Memory pressure is normal: ${mem_pressure}"
            fi
        fi

        # Check I/O pressure
        if [[ -f "/proc/pressure/io" ]]; then
            io_pressure=$(cat /proc/pressure/io | awk '{print $2}' | cut -d'=' -f2)
            if (( $(echo "$io_pressure > 0.1" | bc -l) )); then
                warn "High I/O pressure detected: ${io_pressure}"
            else
                success "I/O pressure is normal: ${io_pressure}"
            fi
        fi
    else
        info "Pressure Stall Information not available (kernel < 4.20)"
    fi

    # Check for high context switches
    ctx_switches=$(cat /proc/stat | grep ctxt | awk '{print $2}')
    if [[ -n "$ctx_switches" ]]; then
        if (( ctx_switches > 1000000 )); then
            warn "High context switching detected: ${ctx_switches} switches"
        else
            success "Context switching is normal: ${ctx_switches} switches"
        fi
    fi

    # Check for zombie processes
    zombie_count=$(ps -eo stat | grep -c Z)
    if (( zombie_count > 0 )); then
        warn "${zombie_count} zombie processes detected"
        ps aux | grep -w Z | head -5
    else
        success "No zombie processes found"
    fi
}

# Function to check kernel, memory, and disk health
check_kernel_memory_disk() {
    info "Checking Kernel, Memory, and Disk Health..."

    # Check dmesg for OOM kills
    oom_count=$(dmesg | grep -i "killed\|oom" | wc -l)
    if (( oom_count > 0 )); then
        critical "OOM kills detected in kernel logs: ${oom_count}"
        dmesg | grep -i "killed\|oom" | tail -10
    else
        success "No OOM kills found"
    fi

    # Check for CPU throttling
    cpu_throttle=$(dmesg | grep -i "throttling\|turbo\|boost" | wc -l)
    if (( cpu_throttle > 0 )); then
        warn "CPU throttling detected in kernel logs"
        dmesg | grep -i "throttling\|turbo\|boost" | tail -5
    else
        success "No CPU throttling detected"
    fi

    # Check for hardware/temperature faults
    hw_faults=$(dmesg | grep -i "hardware\|temperature\|fault" | wc -l)
    if (( hw_faults > 0 )); then
        warn "Hardware/temperature faults detected: ${hw_faults}"
        dmesg | grep -i "hardware\|temperature\|fault" | tail -5
    else
        success "No hardware faults detected"
    fi

    # Check swap utilization
    swap_info=$(free | grep Swap)
    swap_total=$(echo "$swap_info" | awk '{print $2}')
    swap_used=$(echo "$swap_info" | awk '{print $3}')

    if (( swap_total > 0 )); then
        swap_percent=$(( (swap_used * 100) / swap_total ))
        if (( swap_percent > 80 )); then
            critical "High swap usage: ${swap_percent}%"
        elif (( swap_percent > 50 )); then
            warn "Moderate swap usage: ${swap_percent}%"
        else
            success "Swap usage is normal: ${swap_percent}%"
        fi
    fi

    # Check page faults
    page_faults=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
    if [[ -n "$page_faults" ]]; then
        if (( page_faults > 100000 )); then
            warn "High page fault count: ${page_faults}"
        else
            success "Page faults are normal: ${page_faults}"
        fi
    fi

    # Check inode usage on primary mount points
    df -i | grep -v "Filesystem" | while read filesystem size used available percent mountpoint; do
        if [[ -n "$percent" && "$percent" != "Mounted" ]]; then
            percent_clean=${percent%\%}
            if (( percent_clean > 90 )); then
                critical "High inode usage on ${mountpoint}: ${percent_clean}%"
            elif (( percent_clean > 80 )); then
                warn "Moderate inode usage on ${mountpoint}: ${percent_clean}%"
            else
                success "Inode usage on ${mountpoint} is normal: ${percent_clean}%"
            fi
        fi
    done
}

# Function to check network and socket state
check_network_sockets() {
    info "Checking Network & Socket State..."

    # Check TCP queue drops (if available)
    if [[ -f "/proc/net/sockstat" ]]; then
        tcp_drop=$(cat /proc/net/sockstat | grep -i "TCP:" | awk '{print $7}' 2>/dev/null || echo "0")
        if (( tcp_drop > 0 )); then
            warn "TCP queue drops detected: ${tcp_drop}"
        else
            success "No TCP queue drops detected"
        fi
    fi

    # Check TIME_WAIT socket count
    time_wait_count=$(ss -s | grep -i timewait | awk '{print $2}' 2>/dev/null || echo "0")
    if [[ -n "$time_wait_count" && "$time_wait_count" != "0" ]]; then
        if (( time_wait_count > 1000 )); then
            warn "High TIME_WAIT socket count: ${time_wait_count}"
        else
            success "TIME_WAIT socket count is normal: ${time_wait_count}"
        fi
    fi

    # Check for port exhaustion indicators (high number of established connections)
    established_count=$(ss -s | grep -i established | awk '{print $2}' 2>/dev/null || echo "0")
    if [[ -n "$established_count" && "$established_count" != "0" ]]; then
        if (( established_count > 10000 )); then
            warn "High number of established connections: ${established_count}"
        else
            success "Established connection count is normal: ${established_count}"
        fi
    fi

    # Check interface rx/tx error drops
    ip -s link show | grep -E "(RX|TX).*drop" | while read line; do
        if [[ -n "$line" ]]; then
            drops=$(echo "$line" | awk '{print $4}' 2>/dev/null || echo "0")
            if (( drops > 0 )); then
                warn "Interface error drops detected: ${drops}"
            else
                success "No interface error drops"
            fi
        fi
    done
}

# Function to check service and container runtime state
check_services_containers() {
    info "Checking Service & Container Runtime State..."

    # Check failed systemd units
    failed_units=$(systemctl --failed | grep -v "0 loaded units listed" | wc -l)
    if (( failed_units > 1 )); then
        critical "Failed systemd units detected: ${failed_units}"
        systemctl --failed
    else
        success "No failed systemd units"
    fi

    # Check for Docker containers with OOM or memory issues
    if command -v docker >/dev/null 2>&1; then
        docker_containers=$(docker ps -aq | wc -l)
        if (( docker_containers > 0 )); then
            info "Checking Docker container status..."
            docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Command}}" | head -5

            # Check for containers that have recently exited with OOM
            oom_containers=$(docker ps -aq --filter "status=exited" --filter "before=$(date -d '1 hour ago' -Iseconds)" | xargs -r docker inspect | grep -i "oom\|memory" | wc -l)
            if (( oom_containers > 0 )); then
                warn "${oom_containers} Docker containers have OOM issues"
            fi
        else
            info "No Docker containers found"
        fi
    else
        info "Docker not installed"
    fi

    # Check containerd status if available
    if command -v crictl >/dev/null 2>&1; then
        info "Checking containerd status..."
        crictl ps -a | head -5
    else
        info "containerd not installed"
    fi

    # Check kubelet service status if this is a Kubernetes node
    if systemctl list-unit-files | grep -q kubelet; then
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
    else
        info "Not a Kubernetes node (kubelet not installed)"
    fi
}

# Function to check advanced tracing readiness
check_tracing_readiness() {
    info "Checking Advanced Tracing Readiness..."

    # Check for eBPF support
    if [[ -f "/boot/config-$(uname -r)" ]]; then
        bpf_support=$(grep -c CONFIG_BPF_SYSCALL /boot/config-$(uname -r) 2>/dev/null || echo "0")
        if (( bpf_support > 0 )); then
            success "eBPF support available (CONFIG_BPF_SYSCALL)"
        else
            warn "eBPF support not enabled in kernel configuration"
        fi
    else
        info "Kernel config file not found"
    fi

    # Check for bpftool availability
    if command -v bpftool >/dev/null 2>&1; then
        success "bpftool is available"
    else
        info "bpftool not installed (optional)"
    fi

    # Check for bcc-tools availability
    if command -v bpftrace >/dev/null 2>&1; then
        success "bpftrace (BCC tools) is available"
    else
        info "bpftrace (BCC tools) not installed (optional)"
    fi
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

# Function to generate system overview
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
    echo ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Create output directory
    mkdir -p "${DIAGNOSIS_DIR}"

    info "Starting Ubuntu System Diagnosis"
    info "Output will be saved to: ${REPORT_FILE}"

    # Clear the log file
    > "${LOG_FILE}"

    # Start with system overview
    generate_system_overview

    # Run all diagnostic checks
    check_pressure_stall
    echo ""

    check_kernel_memory_disk
    echo ""

    check_network_sockets
    echo ""

    check_services_containers
    echo ""

    check_tracing_readiness
    echo ""

    # Generate critical warnings summary
    generate_critical_warnings_summary

    # Final report
    success "Diagnosis complete. Report saved to: ${REPORT_FILE}"

    # Copy log file to report
    cp "${LOG_FILE}" "${REPORT_FILE}"
}

# =============================================================================
# EXECUTE MAIN FUNCTION
# =============================================================================

main "$@"