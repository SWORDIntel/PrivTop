#!/bin/bash

# Define target IP and number of pings
TARGET_IP="38.102.87.235"
PING_COUNT=6
LOG_FILE="/var/log/ping_target.log"

# Get current date and time for logging
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

echo "[$TIMESTAMP] Pinging $TARGET_IP $PING_COUNT times..." >> "$LOG_FILE"
ping -c "$PING_COUNT" "$TARGET_IP" >> "$LOG_FILE" 2>&1
echo "[$TIMESTAMP] Ping finished." >> "$LOG_FILE"
echo "----------------------------------------------------" >> "$LOG_FILE"
