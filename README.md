# System Performance Analyzer

A lightweight Bash-based system monitoring tool that tracks CPU, memory, GPU, and network usage in real time.  
It displays system metrics in the terminal using progress bars and trend graphs while also generating an auto-refreshing HTML dashboard.

## Features
- Real-time CPU usage monitoring
- Memory utilization tracking
- GPU usage detection using `nvidia-smi`
- Network upload and download speed monitoring
- Terminal progress bars and trend graphs
- Auto-refreshing HTML dashboard
- Continuous system performance logging

## Technologies Used
- Bash scripting
- Linux system files (`/proc/stat`, `/sys/class/net`)
- Standard Unix utilities (`top`, `awk`, `free`)
- HTML for dashboard visualization

## Files Generated
- `dashboard.html` – Live system performance dashboard
- `system_monitor.log` – Log file containing recorded system metrics

## How to Run

1. Make the script executable:

```bash
chmod +x system_monitor.sh
