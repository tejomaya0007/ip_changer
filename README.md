# Tor IP Changer (Enhanced) + Hop Map

Rotate Tor exit IPs at a fixed interval and log each hop (with country).  
Includes a Python tool to **analyze and visualize** your hops on a world map (and as tables).

**Made by Tejomaya.** Inspired by the rotation concept in TechChip’s script, but rewritten and enhanced.

---

## What this does

- Sends Tor control-port command `SIGNAL NEWNYM` to request a new circuit/exit IP.
- Logs each exit IP to a CSV on your Desktop:  
  `~/Desktop/tor-ip-log-YYYY-MM-DD.csv` with columns: `Timestamp,IP,Country` (ISO-2).
- Optional **country variety**:
  - `--no-repeat=N` tries to avoid the same country repeating more than N times in a row.
  - `--rotate-countries=DE,FR,SE,...` rotates among preferred exit countries.
- `analysis.py` loads your CSV and produces:
  - **Tables** of steps (from→to with IPs/timestamps)
  - An **interactive map** with numbered hops and red bullets at endpoints (for Google Colab)

---

## Requirements

- Linux (tested on Kali) with:
  - `tor`, `curl`, `jq`, `xxd`, `netcat-openbsd` (or `ncat`)
- Tor service running locally (SOCKS **127.0.0.1:9050**, Control **127.0.0.1:9051**)

> The script will try to install dependencies for common distros, but you can install them yourself if you prefer.

---

## 1) Start Tor first

```bash
sudo service tor start
# or
sudo systemctl start tor


Verify Tor ports:

ss -ltnp | grep -E '9050|9051'


Quick check through Tor:

curl --socks5 127.0.0.1:9050 https://check.torproject.org/api/ip


If using a normal browser (not Tor Browser):
Set SOCKS5 proxy to 127.0.0.1 and port 9050 (Manual proxy settings).
Tor Browser includes its own Tor and does not require system proxy changes.

2) Run the IP changer

Make it executable once:

chmod +x ip_-_changer.sh

Common ways to run

A. Simple (prompt will ask for interval)

sudo ./ip_-_changer.sh
# Enter seconds (default is 10)


B. Fixed interval (no prompt)

sudo ./ip_-_changer.sh 15


C. Avoid too many repeats from the same country

sudo ./ip_-_changer.sh 15 --no-repeat=3


D. Rotate among specific countries

sudo ./ip_-_changer.sh 15 --rotate-countries=DE,FR,SE,NL


E. Do it once and exit

sudo ./ip_-_changer.sh --once


Tip: Tor rate-limits NEWNYM. An interval of 10–20s is more stable.
If you go faster, you might see occasional FAILED log entries or repeated exits.

3) Stop / Background / Verify

Stop (foreground run): press CTRL + C.

Run in background (quick & simple):

sudo nohup ./ip_-_changer.sh 15 --no-repeat=3 \
  > /var/log/tor-ip-changer.out 2>&1 &


Check if running:

ps aux | grep ip_-_changer.sh


Stop background run:

sudo pkill -f ip_-_changer.sh


Verify it’s working:

You see output lines like:
YYYY-mm-dd HH:MM:SS - New Tor IP: X.X.X.X (DE)

The log file on your Desktop is growing:

tail -f ~/Desktop/tor-ip-log-$(date +%F).csv


Curl via Tor shows a Tor exit IP:

curl --socks5 127.0.0.1:9050 https://check.torproject.org/api/ip

4) Where are the logs?

By default (running with sudo), this enhanced script writes to your user’s Desktop:

~/Desktop/tor-ip-log-YYYY-MM-DD.csv

5) Analyze & visualize (analysis.py)

analysis.py is meant to be run in Google Colab (works best there). It:

Prints tables first (steps, visit counts, transition counts).

Shows an interactive map with:

Red bullets at both ends of each hop segment (start/end)

Number badges (①, ②, ③, …) at the midpoint of each hop

Hover/click tooltips with IPs and timestamps

Saves a copy as tor_hops_map.html which you can download.

How to use in Colab

Open a new notebook at https://colab.research.google.com

Copy/paste the contents of analysis.py into a cell and run it.

When prompted, upload your CSV (e.g., tor-ip-log-2025-08-25.csv from your Desktop).

If you want to run locally (not Colab), you’ll need Python packages: geopandas, folium, pycountry.
On some systems, installing GeoPandas may require GDAL/GEOS/Proj dependencies.

Precautions (avoid de-anonymization)

Use Tor Browser when browsing. It reduces fingerprinting; normal browsers leak screen/OS details.

Don’t log into personal accounts (Google, Facebook, banking) while using Tor for anonymity.

Be cautious with downloads. Files (e.g., documents) opened outside Tor can connect directly and reveal your real IP.

Keep HTTPS on. Tor exits are untrusted—end-to-end encryption is essential.

Don’t mix Tor and non-Tor traffic in the same app session (no “half-proxy”).

Tor rate limits new circuits; prefer 10–20s interval to avoid instability.

DNS: Your browser/apps should resolve DNS over Tor. Tor Browser does this automatically.
If you use system apps, use torsocks or ensure they honor the SOCKS proxy.

Troubleshooting

“Password authentication is not supported for Git operations”
Use a Personal Access Token (PAT) or SSH keys for git push.

Apt/GPG key errors on Kali
Refresh Kali’s archive key and update mirrors, then install deps (netcat-openbsd or ncat).

Repeated same country even with --no-repeat
Tor can only use available exits; the script will retry a few times, but it can’t force an exit that isn’t available at that moment.
Consider --rotate-countries=... for stronger hints.

License / Attribution

Concept inspired by TechChip’s IP changer idea.

This repository contains an independent enhanced implementation by Tejomaya.

If you include upstream GPL code, keep the attribution and license.
