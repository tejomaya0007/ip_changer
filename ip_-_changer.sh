#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tor IP Changer (Enhanced Edition)
# Inspired by: techchipnet/ip-changer
# Modified & Enhanced by: Tejomaya
# Features: logging + geolocation + rotation, flexible usage, retries, privacy checks,
# country rotation & anti-repeat logic.
# -----------------------------------------------------------------------------
set -Eeuo pipefail


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


banner() {
echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE} Tor IP Changer – Enhanced Edition${NC}"
echo -e "${YELLOW} Rotate Tor exit IPs with logs & checks${NC}"
echo -e "${GREEN} Developed & Enhanced by Tejomaya${NC}"
echo -e "${BLUE}=============================================${NC}\n"
}


usage() {
cat <<USAGE
Usage: $0 [interval_seconds] [--once] [--no-repeat=N] [--rotate-countries=CC,CC,...]


Options:
interval_seconds How often to change IP (default 10)
--once Change IP once and exit
--no-repeat=N Avoid same country repeating more than N times consecutively
--rotate-countries=LIST Prefer rotating exit countries (ISO-2 codes), e.g. DE,FR,SE,NL
This sets Tor ExitNodes dynamically (StrictNodes=1) per cycle.
Example: --rotate-countries=DE,FR,SE,NL
-h, --help Show this help


Enhanced version authored by: Tejomaya
USAGE
}

usage() {
  cat <<USAGE
Usage: $0 [interval_seconds] [--once] [--no-repeat N] [--rotate-countries=CC,CC,...]

Options:
  interval_seconds         How often to change IP (default 10)
  --once                   Change IP once and exit
  --no-repeat N            Avoid same country repeating more than N times consecutively
  --rotate-countries=LIST  Prefer rotating exit countries (ISO-2 codes), e.g. DE,FR,SE,NL
                           This sets Tor ExitNodes dynamically (StrictNodes=1) per cycle.
                           Example: --rotate-countries=DE,FR,SE,NL
  -h, --help               Show this help
USAGE
}

require_root() {
  if [[ ${UID:-$(id -u)} -ne 0 ]]; then
    echo -e "${RED}❌ Please run this script as root (sudo).${NC}"
    exit 1
  fi
}

# Detect distro from /etc/os-release
get_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

install_deps() {
  local distro="$1"
  echo -e "${BLUE}[*] Installing required packages...${NC}"
  case "$distro" in
    arch|manjaro|blackarch)
      pacman -S --needed --noconfirm curl tor jq xxd openbsd-netcat ;;
    debian|ubuntu|kali|parrot)
      apt update
      apt install -y curl tor jq xxd netcat-openbsd ;;
    fedora)
      dnf install -y curl tor jq xxd nmap-ncat ;;
    opensuse*|sles)
      zypper install -y curl tor jq xxd netcat-openbsd || zypper install -y ncat || zypper install -y netcat ;;
    *)
      echo -e "${RED}❌ Unsupported distro. Please install curl tor jq xxd netcat manually.${NC}"
      exit 1 ;;
  esac
}

ensure_tor_group() {
  local distro="$1"; local TOR_GROUP="tor"
  case "$distro" in
    debian|ubuntu|kali|parrot) TOR_GROUP="debian-tor" ;;
  esac
  getent group "$TOR_GROUP" >/dev/null || groupadd "$TOR_GROUP"
  id -nG "$SUDO_USER" 2>/dev/null | grep -q "\b$TOR_GROUP\b" || usermod -aG "$TOR_GROUP" "$SUDO_USER"
}

configure_tor() {
  local TORRC=/etc/tor/torrc
  touch "$TORRC"
  local needs=0
  grep -q '^ControlPort 9051' "$TORRC" || needs=1
  grep -q '^CookieAuthentication 1' "$TORRC" || needs=1
  grep -q '^CookieAuthFileGroupReadable 1' "$TORRC" || needs=1
  if (( needs == 1 )); then
    {
      echo ""; echo "# Added by tor-ip-changer (enhanced)"
      echo "ControlPort 9051"
      echo "CookieAuthentication 1"
      echo "CookieAuthFileGroupReadable 1"
    } >> "$TORRC"
    systemctl restart tor || service tor restart || true
  fi
}

wait_for_port() {
  local host="$1" port="$2" tries=30
  while ! (echo > /dev/tcp/$host/$port) &>/dev/null; do
    sleep 1; ((tries--)) || { echo -e "${RED}❌ Timeout waiting for $host:$port${NC}"; return 1; }
  done
}

setup_logging() {
  local DESKTOP="/home/$SUDO_USER/Desktop"
  mkdir -p "$DESKTOP"
  local DATE=$(date +%Y-%m-%d)
  LOG_FILE="$DESKTOP/tor-ip-log-$DATE.csv"
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "Timestamp,IP,Country" > "$LOG_FILE"
  fi
  echo "$LOG_FILE"
}

# ---------- Tor control helpers ----------
get_cookie_hex() {
  local cookie_file="/run/tor/control.authcookie"
  [[ -f "$cookie_file" ]] || cookie_file="/var/run/tor/control.authcookie"
  [[ -f "$cookie_file" ]] || { echo ""; return 1; }
  xxd -ps "$cookie_file" | tr -d '\n'
}

ctl_send() {
  # Usage: ctl_send "COMMAND"  (AUTH is handled here)
  local COOKIE_HEX
  COOKIE_HEX=$(get_cookie_hex) || return 1
  {
    printf 'AUTHENTICATE %s\r\n' "$COOKIE_HEX"
    printf '%s\r\n' "$1"
    printf 'QUIT\r\n'
  } | nc -w 3 127.0.0.1 9051 >/dev/null || true
}

signal_newnym() { ctl_send 'SIGNAL NEWNYM'; }

set_exit_country() {
  # expects ISO-2 code like DE, FR
  local cc="$1"
  [[ -z "$cc" ]] && return 0
  ctl_send "SETCONF ExitNodes=\{$cc\}"
  ctl_send "SETCONF StrictNodes=1"
}

reset_exit_nodes() {
  ctl_send 'RESETCONF ExitNodes'
  ctl_send 'RESETCONF StrictNodes'
}

# ---------- Data fetchers ----------
fetch_exit_ip() {
  local ip=""
  for i in {1..3}; do
    ip=$(curl -s --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip | jq -r '.IP // empty')
    [[ -n "$ip" ]] && break
    sleep 2
  done
  echo "$ip"
}

geo_country_code() {
  local ip="$1"; [[ -z "$ip" ]] && { echo "??"; return; }
  # returns ISO-2 (e.g., DE)
  curl -s "https://ipinfo.io/$ip/country" | tr -d '\r' | tr -d '\n'
}

# rudimentary privacy check placeholder
check_dns_leak() {
  local test_ip=$(curl -s --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip | jq -r '.IP // empty')
  echo -e "${BLUE}[*] DNS check sample exit IP via Tor: $test_ip${NC}"
}

main() {
  banner
  require_root
  local distro=$(get_distro)
  install_deps "$distro"
  ensure_tor_group "$distro"
  configure_tor

  wait_for_port 127.0.0.1 9050
  wait_for_port 127.0.0.1 9051

  local once=false
  local TIME_INTERVAL=10
  local NO_REPEAT=0
  local ROTATE_LIST=""

  # --- parse args ---
  if [[ $# -gt 0 ]]; then
    for arg in "$@"; do
      case "$arg" in
        --once) once=true ;;
        --no-repeat) echo -e "${RED}--no-repeat requires a value (e.g., --no-repeat 5)${NC}"; exit 1 ;;
        --no-repeat=*) NO_REPEAT=${arg#*=} ;;
        --rotate-countries=*) ROTATE_LIST=${arg#*=} ;;
        -h|--help) usage; exit 0 ;;
        [0-9]*) TIME_INTERVAL=$arg ;;
        *) echo -e "${YELLOW}[!] Unknown option: $arg${NC}" ;;
      esac
    done
  else
    read -rp "Enter Tor IP change interval in seconds (default 10): " input
    TIME_INTERVAL=${input:-10}
  fi

  # Normalize rotate list to array
  IFS=',' read -r -a ROTATE_ARR <<< "$ROTATE_LIST"

  LOG_FILE=$(setup_logging)
  echo -e "${GREEN}[*] Logging IPs to: $LOG_FILE${NC}"

  # state for anti-repeat
  local last_cc=""
  local repeat_count=0
  local rotate_index=0

  if $once; then
    [[ -n "${ROTATE_LIST}" ]] && set_exit_country "${ROTATE_ARR[0]}"
    signal_newnym
    sleep 2
    local ts ip cc
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    ip=$(fetch_exit_ip)
    cc=$(geo_country_code "$ip")
    echo "$ts,$ip,$cc" | tee -a "$LOG_FILE"
    check_dns_leak
    reset_exit_nodes || true
    exit 0
  fi

  echo -e "${GREEN}[*] Starting Tor IP changer every $TIME_INTERVAL seconds...${NC}"
  while true; do
    # If rotating countries, pick next target CC different from last_cc
    local target_cc=""
    if (( ${#ROTATE_ARR[@]} > 0 )); then
      # simple round-robin skipping if same as last_cc when possible
      for _ in "${ROTATE_ARR[@]}"; do
        target_cc=${ROTATE_ARR[$rotate_index]}
        rotate_index=$(( (rotate_index + 1) % ${#ROTATE_ARR[@]} ))
        if [[ "$target_cc" != "$last_cc" || ${#ROTATE_ARR[@]} == 1 ]]; then
          break
        fi
      done
      set_exit_country "$target_cc"
    fi

    signal_newnym
    sleep 2

    local ts ip cc
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    # Try to avoid repeating same country more than NO_REPEAT
    for attempt in {1..6}; do
      ip=$(fetch_exit_ip)
      cc=$(geo_country_code "$ip")
      [[ -z "$cc" ]] && cc="??"
      if (( NO_REPEAT > 0 )) && [[ "$cc" == "$last_cc" ]] && (( repeat_count >= NO_REPEAT )); then
        echo -e "${YELLOW}[!] $ts - Got same country $cc again (count=$repeat_count >= $NO_REPEAT). Retrying...${NC}"
        signal_newnym; sleep 3; continue
      fi
      break
    done

    if [[ -n "$ip" ]]; then
      echo "$ts - New Tor IP: $ip ($cc)"
      echo "$ts,$ip,$cc" >> "$LOG_FILE"
      if [[ "$cc" == "$last_cc" ]]; then
        repeat_count=$((repeat_count + 1))
      else
        repeat_count=1
        last_cc="$cc"
      fi
    else
      echo -e "${YELLOW}[!] $ts - Could not fetch IP${NC}"
      echo "$ts,FAILED,??" >> "$LOG_FILE"
    fi

    sleep "$TIME_INTERVAL"
  done
}

main "$@"
