#!/bin/bash

# System Performance Analyzer
# Authors: Piyush Panwar

# Basic color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
LOG_FILE="system_monitor.log"
HTML_FILE="dashboard.html"
REFRESH_RATE=2
INTERFACE="eth0" # RESTORED: Strictly set to eth0 as requested

# Previous CPU values for calculation
PREV_IDLE=0
PREV_TOTAL=0

# Previous network values
PREV_RX=0
PREV_TX=0

# History arrays for sparklines
CPU_HIST=()
MEM_HIST=()

# Function 1: Get CPU Usage
get_cpu() {
    # Try using top command for better WSL compatibility
    if command -v top &> /dev/null; then
        # Use top command which works better in WSL
        local cpu_usage=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -1 | awk '{print $2}' | cut -d'%' -f1)
        
        # If top gives us a value, use it
        if [[ "$cpu_usage" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            # Convert to integer
            CPU_USAGE=$(printf "%.0f" "$cpu_usage")
            echo $CPU_USAGE
            return
        fi
    fi
    
    # Fallback to /proc/stat method
    local cpu_line=$(grep "^cpu " /proc/stat)
    local cpu_array=($cpu_line)
    
    # Extract values (positions 1-7)
    local user=${cpu_array[1]}
    local nice=${cpu_array[2]}
    local system=${cpu_array[3]}
    local idle=${cpu_array[4]}
    local iowait=${cpu_array[5]:-0}
    local irq=${cpu_array[6]:-0}
    local softirq=${cpu_array[7]:-0}
    
    # Calculate total and idle time
    local IDLE=$idle
    local TOTAL=$((user + nice + system + idle + iowait + irq + softirq))
    
    # Calculate percentage if we have previous values
    if [ $PREV_TOTAL -ne 0 ]; then
        local DIFF_IDLE=$((IDLE - PREV_IDLE))
        local DIFF_TOTAL=$((TOTAL - PREV_TOTAL))
        
        if [ $DIFF_TOTAL -gt 0 ]; then
            local DIFF_USED=$((DIFF_TOTAL - DIFF_IDLE))
            CPU_USAGE=$((100 * DIFF_USED / DIFF_TOTAL))
            
            # Ensure it's between 0 and 100
            if [ $CPU_USAGE -lt 0 ]; then CPU_USAGE=0; fi
            if [ $CPU_USAGE -gt 100 ]; then CPU_USAGE=100; fi
        else
            CPU_USAGE=0
        fi
    else
        # First run - do initial calculation
        CPU_USAGE=0
    fi
    
    # Store current values for next iteration
    PREV_IDLE=$IDLE
    PREV_TOTAL=$TOTAL
    
    echo $CPU_USAGE
}

# Function 2: Get Memory Usage
get_memory() {
    
    # Use free command and awk to parse
    local mem_line=$(free | grep Mem)
    local mem_array=($mem_line)
    local total=${mem_array[1]}
    local used=${mem_array[2]}
    
    if [ $total -gt 0 ]; then
        MEM_USAGE=$((100 * used / total))
    else
        MEM_USAGE=0
    fi
    
    echo $MEM_USAGE
}

# Function 3: Get GPU Usage (FIXED: Hardened against non-numeric output)
get_gpu() {
    # Check if nvidia-smi exists
    if command -v nvidia-smi &> /dev/null; then
        # Suppress errors (2>/dev/null) and use || echo 0 to return a 0 if the command fails
        GPU_USAGE=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
        
        if [[ "$GPU_USAGE" =~ ^[0-9]+$ ]]; then
            echo $GPU_USAGE
        else
            # If command ran but returned garbage (e.g., blank or error text)
            echo "0"
        fi
    else
        # Tool is not installed
        echo "N/A"
    fi
}

# Function 4: Get Network Usage (FIXED: Hardened against intermittent read failures)
get_network() {
    
    # Check if the mandatory interface directory exists
    if [ ! -d "/sys/class/net/$INTERFACE" ]; then
        # If eth0 is missing, but it was forced, we return 0.0 0.0
        echo "0.0 0.0"
        return
    fi
    
    local rx_file="/sys/class/net/$INTERFACE/statistics/rx_bytes"
    local tx_file="/sys/class/net/$INTERFACE/statistics/tx_bytes"
    
    # Read current bytes - CRITICAL: Ensure output is exactly 0 if cat fails
    local current_rx=$(cat "$rx_file" 2>/dev/null || echo 0)
    local current_tx=$(cat "$tx_file" 2>/dev/null || echo 0)
    
    # Calculate speed in KB/s using awk for floating-point precision
    local rx_speed=$(awk -v crx="$current_rx" -v prx="$PREV_RX" -v rate="$REFRESH_RATE" \
        "BEGIN {printf \"%.1f\", (crx - prx) / rate / 1024}")
        
    local tx_speed=$(awk -v ctx="$current_tx" -v ptx="$PREV_TX" -v rate="$REFRESH_RATE" \
        "BEGIN {printf \"%.1f\", (ctx - ptx) / rate / 1024}")

    # Store current values for next iteration
    PREV_RX=$current_rx
    PREV_TX=$current_tx
    
    # Handle first run
    if [ $PREV_RX -eq 0 ]; then
        echo "0.0 0.0"
    else
        # Success: Output the calculated speeds
        echo "$rx_speed $tx_speed"
    fi
}

# Function 5: Draw Progress Bar
draw_bar() {
    local VALUE=$1
    local LABEL=$2
    
    # Validate VALUE is a number
    if ! [[ "$VALUE" =~ ^[0-9]+$ ]]; then
        VALUE=0
    fi
    
    # Ensure VALUE is between 0 and 100
    if [ $VALUE -lt 0 ]; then VALUE=0; fi
    if [ $VALUE -gt 100 ]; then VALUE=100; fi
    
    # Choose color based on value
    local COLOR
    if [ $VALUE -gt 70 ]; then
        COLOR=$RED
    elif [ $VALUE -gt 50 ]; then
        COLOR=$YELLOW
    else
        COLOR=$GREEN
    fi
    
    # Calculate filled and empty blocks
    local FILLED=$((VALUE / 2))
    local EMPTY=$((50 - FILLED))
    
    # Print label
    printf "%-12s [" "$LABEL"
    
    # Print filled portion
    printf "${COLOR}"
    for ((i=0; i<FILLED; i++)); do printf "█"; done
    printf "${NC}"
    
    # Print empty portion
    for ((i=0; i<EMPTY; i++)); do printf "░"; done
    
    # Print percentage
    printf "] %3d%%\n" $VALUE
}

# Function 6: Draw Simple Graph
draw_simple_graph() {
    local LABEL=$1
    local VALUE=$2
    
    # Show last 10 values only
    shift 2
    local HISTORY=("$@")
    
    # Keep only last 10
    local display_count=10
    local start_index=$((${#HISTORY[@]} - display_count))
    if [ $start_index -lt 0 ]; then start_index=0; fi
    local DISPLAY_HIST=("${HISTORY[@]:$start_index}")
    
    printf "%-12s [" "$LABEL"
    
    # Draw simple bars
    for VAL in "${DISPLAY_HIST[@]}"; do
        if [[ "$VAL" =~ ^[0-9]+$ ]]; then
            if [ $VAL -ge 75 ]; then
                printf "#"
            elif [ $VAL -ge 50 ]; then
                printf "+"
            elif [ $VAL -ge 25 ]; then
                printf "-"
            else
                printf "."
            fi
        else
            printf "."
        fi
    done
    
    printf "] Last 10: "
    
    # Show trend
    if [ ${#DISPLAY_HIST[@]} -ge 2 ]; then
        local FIRST=${DISPLAY_HIST[0]}
        local LAST=${DISPLAY_HIST[-1]}
        
        if [[ "$FIRST" =~ ^[0-9]+$ ]] && [[ "$LAST" =~ ^[0-9]+$ ]]; then
            if [ $LAST -gt $((FIRST + 5)) ]; then
                printf "↗ Rising"
            elif [ $LAST -lt $((FIRST - 5)) ]; then
                printf "↘ Falling"
            else
                printf "→ Stable"
            fi
        fi
    fi
    printf "\n"
}

# Function 7: Generate HTML Dashboard (FIXED: Uses 6 clean arguments)
generate_html() {
    local CPU=$1
    local MEM=$2
    local GPU_WIDTH=$3     # Numeric width (0 if N/A)
    local GPU_TEXT=$4      # Display text ("N/A", "10%", etc.)
    local RX=$5            # Download float (guaranteed clean, e.g., 0.0 or 10.5)
    local TX=$6            # Upload float (guaranteed clean)
    
    # Create HTML file
    cat > $HTML_FILE << EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="$REFRESH_RATE">
    <title>System Monitor</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            margin: 0;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background: rgba(0,0,0,0.3);
            padding: 30px;
            border-radius: 15px;
        }
        h1 { text-align: center;
        }
        .metric {
            margin: 20px 0;
        }
        .label {
            font-size: 1.2em;
            margin-bottom: 5px;
        }
        .bar {
            background: rgba(255,255,255,0.2);
            border-radius: 10px;
            height: 30px;
            position: relative;
            overflow: hidden;
        }
        .fill {
            height: 100%;
            border-radius: 10px;
            text-align: right;
            padding-right: 10px;
            line-height: 30px;
            font-weight: bold;
        }
        .cpu-fill { background: #4CAF50;
        }
        .mem-fill { background: #2196F3;
        }
        .gpu-fill { background: #FF9800;
        }
        .network {
            display: flex;
            justify-content: space-around;
            margin-top: 20px;
        }
        .net-box {
            background: rgba(255,255,255,0.2);
            padding: 15px;
            border-radius: 10px;
            text-align: center;
            flex: 1;
            margin: 0 10px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>System Performance Monitor</h1>
        <p style="text-align:center; opacity:0.8;">Updated: $(date '+%H:%M:%S')</p>
        
        <div class="metric">
            <div class="label">CPU Usage</div>
            <div class="bar">
                <div class="fill cpu-fill" style="width:${CPU}%">${CPU}%</div>
            </div>
        </div>
        
        <div class="metric">
            <div class="label">Memory Usage</div>
            <div class="bar">
                <div class="fill mem-fill" style="width:${MEM}%">${MEM}%</div>
            </div>
        </div>
        
        <div class="metric">
            <div class="label">GPU Usage</div>
            <div class="bar">
                <div class="fill gpu-fill" style="width:${GPU_WIDTH}%">${GPU_TEXT}</div>
            </div>
        </div>
        
        <div class="network">
            <div class="net-box">
                <div>Download</div>
                <h2>${RX} KB/s</h2>
            </div>
            <div class="net-box">
                <div>Upload</div>
                <h2>${TX} KB/s</h2>
            </div>
        </div>
    </div>
</body>
</html>
EOF
}

# Function 8: Log Data
log_data() {
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    # Note: Log uses GPU_DISPLAY_TEXT for the log file
    echo "$TIMESTAMP | CPU:$1% MEM:$2% GPU:$3 RX:$4KB/s TX:$5KB/s" >> $LOG_FILE
}

# Function 9: Cleanup on Exit
cleanup() {
    echo -e "\n${BLUE}Stopping monitor...${NC}"
    tput cnorm
    exit 0
}

# Trap Ctrl+C signal
trap cleanup SIGINT SIGTERM

# Main Program
echo "=== System Monitor Started at $(date) ===" > $LOG_FILE
clear
tput civis

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}  System Performance Analyzer  ${NC}"
echo -e "${BLUE}  JIIT Noida - Unix Project    ${NC}"
echo -e "${BLUE}================================${NC}"
echo ""
sleep 1

# Main monitoring loop
while true; do
    tput cup 0 0 
    
    echo -e "${BLUE}=== System Monitor - $(date '+%H:%M:%S') ===${NC}\n"
    
    # Get all metrics
    CPU=$(get_cpu)
    MEM=$(get_memory)
    GPU_RAW=$(get_gpu)
    
    # CRITICAL FIX: Use a temporary variable for network data to ensure clean input to read
    NETWORK_DATA=$(get_network)
    read RX TX <<< "$NETWORK_DATA" 
    
    # ----------------------------------------------------
    # PHASE 1: Validation and Preparation
    # ----------------------------------------------------
    
    # 1. Validate CPU/MEM are numeric
    if ! [[ "$CPU" =~ ^[0-9]+$ ]]; then CPU=0; fi
    if ! [[ "$MEM" =~ ^[0-9]+$ ]]; then MEM=0; fi
    
    # 2. Validate RX/TX are clean floats (FIX for 'to KB/s' issue)
    if ! [[ "$RX" =~ ^[0-9]+\.?[0-9]*$ ]]; then RX="0.0"; fi
    if ! [[ "$TX" =~ ^[0-9]+\.?[0-9]*$ ]]; then TX="0.0"; fi
    
    # 3. Prepare GPU variables for HTML/Logging (FIX for 'Failed%' issue)
    GPU_WIDTH=0
    if [[ "$GPU_RAW" =~ ^[0-9]+$ ]]; then
        GPU_WIDTH=$GPU_RAW # Set width to the percentage
        GPU_DISPLAY_TEXT="${GPU_RAW}%"
    else
        # Use the raw output (e.g., "N/A") for display text
        GPU_DISPLAY_TEXT="$GPU_RAW"
    fi
    
    # ----------------------------------------------------
    
    # Store in history arrays (skip first reading which is 0)
    if [ ${#CPU_HIST[@]} -gt 0 ] || [ $CPU -gt 0 ]; then
        CPU_HIST+=($CPU)
        MEM_HIST+=($MEM)
    fi
    
    # Keep only last 50 values
    if [ ${#CPU_HIST[@]} -gt 50 ]; then
        CPU_HIST=("${CPU_HIST[@]:1}")
        MEM_HIST=("${MEM_HIST[@]:1}")
    fi
    
    # Display bars
    draw_bar $CPU "CPU"
    
    # Check GPU_RAW for terminal bar (uses different logic than HTML for color)
    if [[ "$GPU_RAW" =~ ^[0-9]+$ ]]; then
        draw_bar $GPU_RAW "GPU"
    else
        printf "%-12s [${YELLOW}Not Available${NC}]\n" "GPU"
    fi
    
    draw_bar $MEM "Memory"
    
    echo ""
    # Display network info based on the fixed INTERFACE variable
    if [ -d "/sys/class/net/$INTERFACE" ]; then
        echo "Network (interface: $INTERFACE):"
        # Print the float values
        echo "  Download: ${RX} KB/s"
        echo "  Upload:    ${TX} KB/s"
    else
        echo "Network: Interface ${INTERFACE} not found/active."
    fi
    echo ""
    echo -e "${YELLOW}Tip: Run 'curl -o /dev/null http://speedtest.tele2.net/10MB.zip' to test network${NC}"
    
    # Show simple graphs if enough history
    if [ ${#CPU_HIST[@]} -gt 5 ]; then
        echo ""
        echo -e "${BLUE}Trend (Last 10 readings):${NC}"
        draw_simple_graph "CPU" $CPU "${CPU_HIST[@]}"
        draw_simple_graph "Memory" $MEM "${MEM_HIST[@]}"
    fi
    
    echo -e "\n${BLUE}================================${NC}"
    echo -e "Files: ${GREEN}$HTML_FILE${NC} | ${GREEN}$LOG_FILE${NC}"
    echo -e "Press ${RED}Ctrl+C${NC} to stop"
    
    # Generate HTML and log (passing the clean, prepared variables)
    generate_html $CPU $MEM $GPU_WIDTH "$GPU_DISPLAY_TEXT" $RX $TX
    log_data $CPU $MEM $GPU_DISPLAY_TEXT $RX $TX
    
    sleep $REFRESH_RATE
done
