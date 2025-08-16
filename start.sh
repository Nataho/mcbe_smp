#!/bin/bash

SESSION="mcserver"
SERVER_DIR="./"
WORLD_NAME="Nataho"
BACKUP_DIR="BACKUP"
SERVER_EXEC="./bedrock_server"
BACKUP_INTERVAL=1800  # 30 minutes in seconds
STATUS_FILE="/var/home/Nataho/Documents/github/mcbe_smp/status/status.js"
PLAYERS_COUNT_FILE="/tmp/.mc_players_count"    # temp counter during runtime

mkdir -p "$BACKUP_DIR"
cd "$SERVER_DIR" || { echo "Server directory not found!"; exit 1; }

# --- helper: write status/players into status.js (robust to spacing) ---
set_status_line() {
  local bool="$1"  # true|false
  # Replace the whole line regardless of spaces
  sed -i 's/^export[[:space:]]\+var[[:space:]]\+status[[:space:]]*=.*/export var status = '"$bool"'/' "$STATUS_FILE"
}
set_players_line() {
  local n="$1"     # integer
  sed -i 's/^export[[:space:]]\+var[[:space:]]\+players[[:space:]]*=.*/export var players = '"$n"'/' "$STATUS_FILE"
}

# --- initialize status on start ---
echo 0 > "$PLAYERS_COUNT_FILE"
set_status_line true
set_players_line 0

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" bash -c "
    set -euo pipefail

    # Make sure our helper files/paths inside the tmux shell match
    STATUS_FILE=\"$STATUS_FILE\"
    BACKUP_DIR=\"$BACKUP_DIR\"
    WORLD_NAME=\"$WORLD_NAME\"
    SERVER_EXEC=\"$SERVER_EXEC\"
    BACKUP_INTERVAL=$BACKUP_INTERVAL
    PLAYERS_COUNT_FILE=\"$PLAYERS_COUNT_FILE\"

    # Functions inside tmux context
    set_status_line() {
      sed -i 's/^export[[:space:]]\\+var[[:space:]]\\+status[[:space:]]*=.*/export var status = '\"\$1\"'/' \"\$STATUS_FILE\"
    }
    set_players_line() {
      sed -i 's/^export[[:space:]]\\+var[[:space:]]\\+players[[:space:]]*=.*/export var players = '\"\$1\"'/' \"\$STATUS_FILE\"
    }

    # Start a watcher that tracks player connects/disconnects from the log
    # We also ensure the server output is logged via tee (see below).
    (
      # Ensure counter exists
      [ -f \"\$PLAYERS_COUNT_FILE\" ] || echo 0 > \"\$PLAYERS_COUNT_FILE\"
      tail -n 0 -F server.log | while IFS= read -r line; do
        if [[ \"\$line\" == *\"Player connected:\"* ]]; then
          count=\$(cat \"\$PLAYERS_COUNT_FILE\" 2>/dev/null || echo 0)
          count=\$((count+1))
          echo \"\$count\" > \"\$PLAYERS_COUNT_FILE\"
          set_players_line \"\$count\"
        elif [[ \"\$line\" == *\"Player disconnected:\"* ]]; then
          count=\$(cat \"\$PLAYERS_COUNT_FILE\" 2>/dev/null || echo 0)
          if (( count > 0 )); then
            count=\$((count-1))
          fi
          echo \"\$count\" > \"\$PLAYERS_COUNT_FILE\"
          set_players_line \"\$count\"
        fi
      done
    ) &

    # Periodic backup loop
    (
      while true; do
        sleep \"\$BACKUP_INTERVAL\"
        TIMESTAMP=\$(date +\"%y-%m-%d %H-%M\")
        BACKUP_FILE=\"\$BACKUP_DIR/\${TIMESTAMP} - Runtime.tar.gz\"

        echo \"[Backup] Initiating safe save at \$(date)...\"
        tmux send-keys -t $SESSION \"save hold\" Enter
        sleep 1
        tmux send-keys -t $SESSION \"save query\" Enter
        sleep 1
        echo \"[Backup] Compressing world folder...\"
        tar -czf \"\$BACKUP_FILE\" \"worlds/\$WORLD_NAME\"
        tmux send-keys -t $SESSION \"save resume\" Enter
        echo \"[Backup] Saved to \$BACKUP_FILE\"
      done
    ) &

    # Run the server with line-buffered stdout and also write server.log so the watcher can parse it.
    # stdbuf keeps lines flushing; tee shows in terminal AND appends to server.log
    stdbuf -oL -eL \"\$SERVER_EXEC\" 2>&1 | tee -a server.log

    # When server exits, do a final backup and flip status false/players 0
    TIMESTAMP=\$(date +\"%y-%m-%d %H-%M\")
    BACKUP_FILE=\"\$BACKUP_DIR/\${TIMESTAMP} - End.tar.gz\"
    echo \"[Final Backup] Initiating safe save...\"
    tmux send-keys -t $SESSION \"save hold\" Enter
    sleep 1
    tmux send-keys -t $SESSION \"save query\" Enter
    sleep 1
    tar -czf \"\$BACKUP_FILE\" \"worlds/\$WORLD_NAME\"
    tmux send-keys -t $SESSION \"save resume\" Enter
    echo \"[Final Backup] Saved to \$BACKUP_FILE\"

    set_players_line 0
    set_status_line false

    exec bash
  "
fi

tmux attach -t "$SESSION"
