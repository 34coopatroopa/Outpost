#!/usr/bin/env bash
# =============================================================================
#  OUTPOST — MASTER DOWNLOAD SCRIPT  v3.0
#  Downloads all offline survival content for the Pi 5 survival computer
#
#  FIXES in v3.0:
#    - Correct Stack Exchange ZIM naming: subdomain.stackexchange.com_en_all_YYYY-MM
#    - Correct iFixit naming: ifixit_en_all_YYYY-MM (not ifixit_en_maxi)
#    - HEAD-verify every URL before attempting download — no more blind 404s
#    - Scrapes live Kiwix directory listing to always get the latest date
#    - Skips files already downloaded (resume-safe, re-run anytime)
#    - Auto-detects D:\Outpost if running in WSL
#    - Bonus: armypubs ZIM — entire US Army publications archive (~7.7GB)
#
#  Usage:
#    chmod +x survival_pi_download.sh
#    ./survival_pi_download.sh                        # auto-detects D:\Outpost
#    ./survival_pi_download.sh --dir /mnt/d/Outpost   # explicit path
#    ./survival_pi_download.sh --skip-games           # skip retro games
#    ./survival_pi_download.sh --skip-ai              # skip Ollama model pull
#    ./survival_pi_download.sh --skip-maps            # skip OSM map data
#
#  Safe to re-run — all downloads resume where they left off
# =============================================================================

set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()     { echo -e "${GREEN}[✔]${RESET} $*"; }
info()    { echo -e "${CYAN}[i]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✘]${RESET} $*"; }
section() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}\n"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
BASE_DIR="${HOME}/survival_pi"
SKIP_GAMES=false
SKIP_AI=false
SKIP_MAPS=false
ARIA2_CONNS=8

# Auto-detect D:\Outpost when running in WSL
if [[ -d "/mnt/d/Outpost" ]]; then
  BASE_DIR="/mnt/d/Outpost"
fi

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)        BASE_DIR="$2"; shift 2 ;;
    --skip-games) SKIP_GAMES=true; shift ;;
    --skip-ai)    SKIP_AI=true; shift ;;
    --skip-maps)  SKIP_MAPS=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--dir PATH] [--skip-games] [--skip-ai] [--skip-maps]"
      exit 0 ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Directory layout ──────────────────────────────────────────────────────────
ZIM_DIR="${BASE_DIR}/kiwix/zims"
MAPS_DIR="${BASE_DIR}/maps"
MILITARY_DIR="${BASE_DIR}/manuals/military"
MEDICAL_DIR="${BASE_DIR}/manuals/medical"
SURVIVAL_DIR="${BASE_DIR}/manuals/survival"
FORAGING_DIR="${BASE_DIR}/manuals/foraging"
AGRICULTURE_DIR="${BASE_DIR}/manuals/agriculture"
BOOKS_DIR="${BASE_DIR}/books"
COMICS_DIR="${BASE_DIR}/entertainment/comics"
GAMES_DIR="${BASE_DIR}/entertainment/games"
AI_DIR="${BASE_DIR}/ai"
LOG_FILE="${BASE_DIR}/download.log"

mkdir -p "$ZIM_DIR" "$MAPS_DIR" "$MILITARY_DIR" "$MEDICAL_DIR" \
         "$SURVIVAL_DIR" "$FORAGING_DIR" "$AGRICULTURE_DIR" \
         "$BOOKS_DIR" "$COMICS_DIR" "$GAMES_DIR" "$AI_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║         OUTPOST DOWNLOAD SCRIPT  v3.0               ║${RESET}"
echo -e "${BOLD}${CYAN}║         $(date '+%Y-%m-%d %H:%M:%S')                          ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Dependency check ──────────────────────────────────────────────────────────
section "Checking Dependencies"
MISSING=()
for cmd in wget curl aria2c rsync python3; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  warn "Missing: ${MISSING[*]} — installing..."
  sudo apt-get update -qq
  sudo apt-get install -y wget curl aria2 rsync python3 --no-install-recommends
fi
log "Dependencies ready"

# ── Disk space check ──────────────────────────────────────────────────────────
section "Disk Space Check"
AVAIL_KB=$(df -k "$BASE_DIR" | awk 'NR==2{print $4}')
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
info "Base directory : $BASE_DIR"
info "Available space: ${AVAIL_GB} GB"
(( AVAIL_GB < 15 )) && { error "Less than 15GB free. Use --dir to point to a larger drive."; exit 1; }
(( AVAIL_GB < 70 )) && warn "Less than 70GB — some large downloads may not fit"

# =============================================================================
# HELPERS
# =============================================================================

# ── aria2c download, skips if file already exists and looks complete (>1MB) ───
dl() {
  local url="$1" dest="$2"
  local filename filepath sz
  filename="$(basename "$url")"
  filepath="${dest}/${filename}"

  if [[ -f "$filepath" ]]; then
    sz=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
    if (( sz > 1048576 )); then
      info "Already exists, skipping: $filename"
      return 0
    fi
    warn "Incomplete file found, removing: $filename"
    rm -f "$filepath"
  fi

  info "Downloading: $filename"
  aria2c \
    --dir="$dest" \
    --out="$filename" \
    --continue=true \
    --max-connection-per-server="$ARIA2_CONNS" \
    --split="$ARIA2_CONNS" \
    --min-split-size=5M \
    --retry-wait=10 \
    --max-tries=8 \
    --connect-timeout=30 \
    --timeout=600 \
    --file-allocation=none \
    --console-log-level=warn \
    "$url" \
    && log "Done: $filename" \
    || warn "Failed: $filename — re-run to retry"
}

# ── wget for small files ──────────────────────────────────────────────────────
dlw() {
  local url="$1" dest="$2" outname="${3:-}"
  local filename filepath
  filename="${outname:-$(basename "$url")}"
  filepath="${dest}/${filename}"

  if [[ -f "$filepath" ]] && (( $(stat -c%s "$filepath" 2>/dev/null || echo 0) > 10240 )); then
    info "Already exists: $filename"
    return 0
  fi
  info "Downloading: $filename"
  wget -q --show-progress -c -O "$filepath" "$url" \
    && log "Done: $filename" \
    || warn "Failed: $filename"
}

# ── HEAD check — returns 0 if URL responds 200/301/302 ───────────────────────
url_alive() {
  local code
  code=$(curl -o /dev/null -sL --max-time 20 --connect-timeout 10 \
    -w "%{http_code}" "$1" 2>/dev/null || echo "000")
  [[ "$code" =~ ^(200|301|302)$ ]]
}

# ── Scrape latest ZIM filename from Kiwix directory listing ──────────────────
scrape_latest() {
  local category="$1" prefix="$2"
  local listing newest
  listing=$(curl -sL --max-time 20 \
    "https://download.kiwix.org/zim/${category}/" 2>/dev/null || true)
  newest=$(echo "$listing" \
    | grep -oP "\"${prefix}_[0-9]{4}-[0-9]{2}\.zim\"" \
    | tr -d '"' | sort -V | tail -1 || true)
  [[ -n "$newest" ]] \
    && echo "https://download.kiwix.org/zim/${category}/${newest}" \
    || echo ""
}

# ── Smart ZIM downloader ──────────────────────────────────────────────────────
# Tries: 1) scrape live listing, 2) walk back 18 months with HEAD checks
download_zim() {
  local label="$1" category="$2" prefix="$3"
  local base="https://download.kiwix.org/zim/${category}"

  info "Resolving: ${label}..."

  # Already have it?
  local existing
  existing=$(find "$ZIM_DIR" -maxdepth 1 -name "${prefix}_*.zim" \
    -size +1M 2>/dev/null | sort -V | tail -1 || true)
  if [[ -n "$existing" ]]; then
    info "Already have: $(basename "$existing")"
    return 0
  fi

  # Try live directory scrape
  local url
  url=$(scrape_latest "$category" "$prefix" || true)
  if [[ -n "$url" ]] && url_alive "$url"; then
    info "Found via scrape: $(basename "$url")"
    dl "$url" "$ZIM_DIR"
    return 0
  fi

  # Walk back through last 18 months
  info "Scrape failed — HEAD-checking dated candidates..."
  local i year month candidate
  for i in $(seq 0 17); do
    year=$(date -d "-${i} months" +%Y 2>/dev/null || \
           python3 -c "
from datetime import date
from dateutil.relativedelta import relativedelta
try:
    print((date.today().replace(day=1) - relativedelta(months=${i})).strftime('%Y'))
except Exception:
    from datetime import timedelta
    d = date.today().replace(day=1)
    for _ in range(${i}): d = (d.replace(day=1) - timedelta(days=1)).replace(day=1)
    print(d.strftime('%Y'))
" 2>/dev/null || continue)
    month=$(date -d "-${i} months" +%m 2>/dev/null || \
            python3 -c "
from datetime import date
from dateutil.relativedelta import relativedelta
try:
    print((date.today().replace(day=1) - relativedelta(months=${i})).strftime('%m'))
except Exception:
    from datetime import timedelta
    d = date.today().replace(day=1)
    for _ in range(${i}): d = (d.replace(day=1) - timedelta(days=1)).replace(day=1)
    print(d.strftime('%m'))
" 2>/dev/null || continue)

    candidate="${base}/${prefix}_${year}-${month}.zim"
    if url_alive "$candidate"; then
      info "Verified (HTTP 200): $candidate"
      dl "$candidate" "$ZIM_DIR"
      return 0
    fi
  done

  warn "No valid URL found for: ${label}"
  warn "  → Browse: ${base}/"
  warn "  → Download manually and place in: ${ZIM_DIR}/"
}

# =============================================================================
# 1 / 8 — KIWIX ZIM FILES
# =============================================================================
section "1 / 8  —  Kiwix ZIM Files"

command -v kiwix-serve &>/dev/null || {
  info "Installing kiwix-tools..."
  sudo apt-get install -y kiwix-tools 2>/dev/null \
    || warn "kiwix-tools not in apt — see https://kiwix.org/en/download/"
}

# ── Wikipedia English no-pics (~25GB) ────────────────────────────────────────
download_zim "Wikipedia English (no pictures)" \
  "wikipedia" "wikipedia_en_all_nopic"

# ── iFixit repair guides (~3.3GB) ─────────────────────────────────────────────
# FIXED: correct name is ifixit_en_all (NOT ifixit_en_maxi)
download_zim "iFixit Repair Guides" \
  "ifixit" "ifixit_en_all"

# ── Wikibooks how-to guides (~4GB) ───────────────────────────────────────────
download_zim "Wikibooks" \
  "wikibooks" "wikibooks_en_all_maxi"

# ── Wikivoyage trails & campsites (~1GB) ─────────────────────────────────────
download_zim "Wikivoyage" \
  "wikivoyage" "wikivoyage_en_all_maxi"

# ── Wikisource historic texts (~10GB) ────────────────────────────────────────
download_zim "Wikisource" \
  "wikisource" "wikisource_en_all_maxi"

# ── Wikiversity courses (~2GB) ───────────────────────────────────────────────
download_zim "Wikiversity" \
  "wikiversity" "wikiversity_en_all_maxi"

# ── Stack Exchange ZIMs ───────────────────────────────────────────────────────
# FIXED: real naming is "subdomain.stackexchange.com_en_all_YYYY-MM.zim"
# Verified from https://download.kiwix.org/zim/stack_exchange/ listing
info "--- Stack Exchange (correct subdomain naming) ---"

download_zim "Stack Exchange: Cooking" \
  "stack_exchange" "cooking.stackexchange.com_en_all"

download_zim "Stack Exchange: DIY / Home Improvement" \
  "stack_exchange" "diy.stackexchange.com_en_all"

download_zim "Stack Exchange: Electronics" \
  "stack_exchange" "electronics.stackexchange.com_en_all"

download_zim "Stack Exchange: Gardening" \
  "stack_exchange" "gardening.stackexchange.com_en_all"

download_zim "Stack Exchange: Outdoors / Hiking / Survival" \
  "stack_exchange" "outdoors.stackexchange.com_en_all"

download_zim "Stack Exchange: Motor Vehicle Mechanics" \
  "stack_exchange" "mechanics.stackexchange.com_en_all"

download_zim "Stack Exchange: Home Improvement" \
  "stack_exchange" "home.stackexchange.com_en_all"

download_zim "Stack Exchange: Sustainability" \
  "stack_exchange" "sustainability.stackexchange.com_en_all"

download_zim "Stack Exchange: Ham Radio" \
  "stack_exchange" "ham.stackexchange.com_en_all"

# ── BONUS: US Army Publications archive (~7.7GB from zimit/) ─────────────────
info "--- Bonus: US Army Publications Archive (zimit category) ---"
existing=$(find "$ZIM_DIR" -maxdepth 1 -name "armypubs_en_all_*.zim" \
  -size +1M 2>/dev/null | head -1 || true)
if [[ -n "$existing" ]]; then
  info "Already have: $(basename "$existing")"
else
  # Scrape zimit directory for latest armypubs
  ARMY_URL=$(scrape_latest "zimit" "armypubs_en_all" || true)
  if [[ -z "$ARMY_URL" ]] || ! url_alive "$ARMY_URL"; then
    # HEAD-check known dates
    for CANDIDATE in \
      "https://download.kiwix.org/zim/zimit/armypubs_en_all_2024-12.zim" \
      "https://download.kiwix.org/zim/zimit/armypubs_en_all_2024-06.zim"; do
      if url_alive "$CANDIDATE"; then ARMY_URL="$CANDIDATE"; break; fi
    done
  fi
  if [[ -n "${ARMY_URL:-}" ]]; then
    dl "$ARMY_URL" "$ZIM_DIR"
  else
    warn "Army Publications ZIM not found"
    warn "  → Check: https://download.kiwix.org/zim/zimit/"
  fi
fi

log "Kiwix ZIMs complete"

# =============================================================================
# 2 / 8 — OFFLINE MAPS
# =============================================================================
section "2 / 8  —  Offline Maps"

if [[ "$SKIP_MAPS" == "true" ]]; then
  warn "Skipping maps (--skip-maps)"
else
  GEOFABRIK="https://download.geofabrik.de"
  COUNTRY=$(curl -s --max-time 8 "https://ipapi.co/country/" 2>/dev/null || true)
  COUNTRY="${COUNTRY:-US}"
  [[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || COUNTRY="US"
  info "Detected country: $COUNTRY"

  case "$COUNTRY" in
    US)
      for REGION in "us-northeast" "us-south" "us-west" "us-midwest"; do
        dl "${GEOFABRIK}/north-america/${REGION}-latest.osm.pbf" "$MAPS_DIR" \
          || warn "Region $REGION failed"
      done
      ;;
    CA) dl "${GEOFABRIK}/north-america/canada-latest.osm.pbf" "$MAPS_DIR" ;;
    GB|IE) dl "${GEOFABRIK}/europe/great-britain-latest.osm.pbf" "$MAPS_DIR" ;;
    AU|NZ) dl "${GEOFABRIK}/australia-oceania/australia-latest.osm.pbf" "$MAPS_DIR" ;;
    *)
      warn "Region $COUNTRY not auto-mapped."
      warn "  → Download from: https://download.geofabrik.de"
      warn "  → Place .osm.pbf in: ${MAPS_DIR}/"
      ;;
  esac

  cat > "${MAPS_DIR}/USGS_TOPO_DOWNLOAD.txt" << 'EOF'
USGS Topographic Maps — Free Download (Manual Step)
====================================================
URL: https://apps.nationalmap.gov/downloader/
Format: GeoPDF — viewable offline in any PDF reader

Steps:
  1. Go to the URL above while online
  2. Search your area by place name or coordinates
  3. Select "US Topo" product type
  4. Download .pdf files for your region
  5. Copy them into this maps/ directory
EOF
  log "Maps complete"
fi

# =============================================================================
# 3 / 8 — MILITARY FIELD MANUALS
# =============================================================================
section "3 / 8  —  Military Field Manuals"

ARCHIVE="https://archive.org/download"

declare -A FMs=(
  ["FM_21-76_Survival.pdf"]="${ARCHIVE}/Fm21-76SurvivalManual/FM21-76_SurvivalManual.pdf"
  ["FM_4-25.11_First_Aid.pdf"]="${ARCHIVE}/army-fm-4-25-11/fm-4-25-11.pdf"
  ["FM_31-70_Cold_Weather.pdf"]="${ARCHIVE}/army-fm-31-70/fm-31-70.pdf"
  ["FM_5-426_Carpentry.pdf"]="${ARCHIVE}/army-fm-5-426/fm-5-426.pdf"
  ["FM_5-428_Concrete_Masonry.pdf"]="${ARCHIVE}/army-fm-5-428/fm-5-428.pdf"
  ["FM_90-3_Desert_Operations.pdf"]="${ARCHIVE}/army-fm-90-3/fm-90-3.pdf"
  ["FM_90-5_Jungle_Operations.pdf"]="${ARCHIVE}/army-fm-90-5/fm-90-5.pdf"
  ["FM_21-10_Field_Hygiene.pdf"]="${ARCHIVE}/army-fm-21-10/fm-21-10.pdf"
)

for OUTNAME in "${!FMs[@]}"; do
  URL="${FMs[$OUTNAME]}"
  OUTPATH="${MILITARY_DIR}/${OUTNAME}"
  if [[ -f "$OUTPATH" ]] && (( $(stat -c%s "$OUTPATH" 2>/dev/null || echo 0) > 10240 )); then
    info "Already exists: $OUTNAME"
    continue
  fi
  info "Downloading: $OUTNAME"
  wget -q --show-progress -c -O "$OUTPATH" "$URL" \
    && log "Done: $OUTNAME" \
    || warn "Failed: $OUTNAME"
done

log "Military manuals complete"

# =============================================================================
# 4 / 8 — MEDICAL REFERENCES
# =============================================================================
section "4 / 8  —  Medical References"

declare -A MEDICAL=(
  ["Where_There_Is_No_Doctor.pdf"]="https://archive.org/download/where-there-is-no-doctor-pdf/where-there-is-no-doctor.pdf"
  ["Where_There_Is_No_Dentist.pdf"]="https://archive.org/download/where-there-is-no-doctor-pdf/where-there-is-no-dentist.pdf"
)

for OUTNAME in "${!MEDICAL[@]}"; do
  URL="${MEDICAL[$OUTNAME]}"
  OUTPATH="${MEDICAL_DIR}/${OUTNAME}"
  if [[ -f "$OUTPATH" ]] && (( $(stat -c%s "$OUTPATH" 2>/dev/null || echo 0) > 10240 )); then
    info "Already exists: $OUTNAME"
    continue
  fi
  info "Downloading: $OUTNAME"
  wget -q --show-progress -c -O "$OUTPATH" "$URL" \
    && log "Done: $OUTNAME" \
    || warn "Failed: $OUTNAME — get from https://hesperian.org/books-and-resources/"
done

log "Medical references complete"

# =============================================================================
# 5 / 8 — FORAGING, AGRICULTURE & FOOD PRESERVATION
# =============================================================================
section "5 / 8  —  Foraging, Agriculture & Food"

declare -A FORAGING=(
  ["Peterson_Field_Guide_Edible_Plants.pdf"]="https://archive.org/download/fieldguidetoedib0000pete_h5c3/fieldguidetoedib0000pete_h5c3.pdf"
  ["Complete_Guide_Edible_Wild_Plants.pdf"]="https://archive.org/download/completeguidetoe0000lyle/completeguidetoe0000lyle.pdf"
  ["Wild_Edibles_Practical_Guide.pdf"]="https://archive.org/download/wildediblespract0000bout/wildediblespract0000bout.pdf"
  ["USDA_Complete_Guide_Home_Canning.pdf"]="https://archive.org/download/usda-complete-guide-to-home-canning/usda-complete-guide-to-home-canning.pdf"
)

for OUTNAME in "${!FORAGING[@]}"; do
  dlw "${FORAGING[$OUTNAME]}" "$FORAGING_DIR" "$OUTNAME"
done

declare -A GUTENBERG=(
  ["Agriculture_for_Beginners.epub"]="https://www.gutenberg.org/ebooks/5265.epub.images"
  ["Cottage_Economy.epub"]="https://www.gutenberg.org/ebooks/14905.epub.images"
  ["First_Book_of_Farming.epub"]="https://www.gutenberg.org/ebooks/10378.epub.images"
  ["Culinary_Herbs.epub"]="https://www.gutenberg.org/ebooks/26763.epub.images"
  ["Manual_of_Gardening.epub"]="https://www.gutenberg.org/ebooks/9550.epub.images"
  ["Beekeeping_for_Beginners.epub"]="https://www.gutenberg.org/ebooks/32085.epub.images"
  ["Home_Canning_and_Preserving.epub"]="https://www.gutenberg.org/ebooks/30360.epub.images"
)

for OUTNAME in "${!GUTENBERG[@]}"; do
  dlw "${GUTENBERG[$OUTNAME]}" "$AGRICULTURE_DIR" "$OUTNAME"
done

log "Foraging & agriculture complete"

# =============================================================================
# 6 / 8 — SURVIVOR LIBRARY
# =============================================================================
section "6 / 8  —  Survivor Library"

SURVIVOR_DEST="${SURVIVAL_DIR}/survivor_library"
mkdir -p "$SURVIVOR_DEST"
EXISTING_COUNT=$(find "$SURVIVOR_DEST" -name "*.pdf" 2>/dev/null | wc -l)

if (( EXISTING_COUNT > 100 )); then
  info "Survivor Library already downloaded (${EXISTING_COUNT} PDFs) — skipping"
else
  info "Syncing Survivor Library from archive.org (~6GB)..."
  if rsync --version &>/dev/null; then
    rsync -avz --progress --timeout=60 \
      "rsync://archive.org/survival.library/" "$SURVIVOR_DEST/" 2>/dev/null \
      && log "Survivor Library complete" \
      || {
        warn "rsync failed — downloading compressed archive..."
        dl "https://archive.org/compress/survival.library/formats=PDF" "$SURVIVAL_DIR"
      }
  else
    dl "https://archive.org/compress/survival.library/formats=PDF" "$SURVIVAL_DIR"
  fi
fi

log "Survivor Library complete"

# =============================================================================
# 7 / 8 — ENTERTAINMENT
# =============================================================================
section "7 / 8  —  Entertainment"

if [[ "$SKIP_GAMES" == "true" ]]; then
  warn "Skipping entertainment (--skip-games)"
else
  info "Installing open source games..."
  sudo apt-get install -y \
    openttd supertuxkart minetest wesnoth nethack-console dosbox \
    2>/dev/null || warn "Some game packages unavailable"

  cat > "${GAMES_DIR}/LEGAL_ROM_SOURCES.txt" << 'EOF'
Legal Game ROM Sources
======================
1. MAMEDev Freeware: https://www.mamedev.org/roms/
2. Public Domain ROMs: https://www.zophar.net/pdroms.html
3. Homebrew: https://www.romhacking.net/homebrew/
4. DOS Games Archive: https://archive.org/details/softwarelibrary_msdos_games
5. Open source (installed): OpenTTD, SuperTuxKart, Minetest, Wesnoth, NetHack

Place ROMs in: entertainment/games/roms/<console>/
EOF

  cat > "${COMICS_DIR}/COMIC_SOURCES.txt" << 'EOF'
Public Domain Comics (Free & Legal)
=====================================
1. Digital Comic Museum: https://digitalcomicmuseum.com
2. Comic Book Plus: https://comicbookplus.com
3. Internet Archive: https://archive.org/details/comics

Download tool: pip3 install gallery-dl
Format: .cbz files, place in entertainment/comics/<Series>/<Issue>.cbz
Server: Komga (java -jar komga.jar) on port 8081
EOF
  log "Entertainment setup complete"
fi

# =============================================================================
# 8 / 8 — LOCAL AI
# =============================================================================
section "8 / 8  —  Local AI (Ollama)"

if [[ "$SKIP_AI" == "true" ]]; then
  warn "Skipping AI (--skip-ai)"
else
  if ! command -v ollama &>/dev/null; then
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh \
      && log "Ollama installed" \
      || warn "Install failed — run: curl -fsSL https://ollama.com/install.sh | sh"
  else
    log "Ollama already installed"
  fi

  if command -v ollama &>/dev/null; then
    pgrep -x ollama &>/dev/null || { ollama serve &>/dev/null & sleep 4; }

    info "Pulling Phi-3 Mini (~2.3GB)..."
    ollama pull phi3:mini \
      && log "Phi-3 Mini ready" \
      || warn "Model pull failed — run: ollama pull phi3:mini"

    mkdir -p "$AI_DIR"
    cat > "${AI_DIR}/survival_system_prompt.txt" << 'PROMPT'
You are OUTPOST AI — an expert offline survival assistant.

SURVIVAL: Wilderness survival, shelter, fire, navigation by stars/sun/compass, signalling.
FORAGING: Edible plants by region, mushrooms, dangerous look-alikes, preparation methods.
MEDICINE: Field medicine, wound care, first aid, triage, shock, fractures, infections.
         Always note "seek professional care when possible" for serious conditions.
FARMING: Crop growing, companion planting, soil, seed saving, composting, irrigation.
ANIMALS: Hunting, trapping, fishing, husbandry, butchering, curing and smoking meat.
FOOD PRESERVATION: Canning, fermentation, smoking, drying, root cellaring, salt-curing.
REPAIR: Mechanical repair, engines, pumps, generators, basic electronics, improvised tools.
NAVIGATION: Map reading, compass, celestial navigation, terrain reading, dead reckoning.
CONSTRUCTION: Shelter from natural materials, log cabin basics, adobe, waterproofing.
WATER: Finding, purifying, and storing water in any environment.

Give practical, actionable advice. Be concise but complete. Prioritise safety.
Warn about dangerous plant/fungi look-alikes. Assume limited tools and supplies.
PROMPT

    cat > "${AI_DIR}/survival_ai.sh" << 'LAUNCHER'
#!/bin/bash
SYSTEM=$(cat "$(dirname "$0")/survival_system_prompt.txt")
echo "=============================="
echo "  OUTPOST AI — Offline Mode"
echo "  Model: phi3:mini"
echo "  Type 'exit' to quit"
echo "=============================="
pgrep -x ollama &>/dev/null || { ollama serve &>/dev/null & sleep 3; }
ollama run phi3:mini --system "$SYSTEM"
LAUNCHER
    chmod +x "${AI_DIR}/survival_ai.sh"
    log "AI assistant: ${AI_DIR}/survival_ai.sh"
  fi
fi

# =============================================================================
# KIWIX LIBRARY + SYSTEMD
# =============================================================================
section "Setting Up Kiwix Server"

if command -v kiwix-manage &>/dev/null; then
  LIBRARY_XML="${ZIM_DIR}/library.xml"
  rm -f "$LIBRARY_XML"
  ZIM_COUNT=0
  for ZIM in "${ZIM_DIR}"/*.zim; do
    [[ -f "$ZIM" ]] && kiwix-manage "$LIBRARY_XML" add "$ZIM" 2>/dev/null \
      && (( ZIM_COUNT++ )) || true
  done
  log "Kiwix library: ${ZIM_COUNT} ZIMs indexed"

  sudo tee /etc/systemd/system/kiwix-serve.service > /dev/null << EOF
[Unit]
Description=Kiwix Offline Knowledge Server
After=network.target
[Service]
Type=simple
User=${USER}
ExecStart=/usr/bin/kiwix-serve --port=8080 --library ${LIBRARY_XML}
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable kiwix-serve 2>/dev/null || true
  sudo systemctl restart kiwix-serve 2>/dev/null \
    && log "Kiwix running at http://localhost:8080" \
    || warn "Could not start kiwix — run: sudo systemctl start kiwix-serve"
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================
section "Complete!"

echo -e "${BOLD}Storage used:${RESET}"
du -sh "${BASE_DIR}"/*/  2>/dev/null | sort -h

echo ""
echo -e "${BOLD}ZIM files:${RESET}"
find "$ZIM_DIR" -name "*.zim" -size +1M 2>/dev/null | sort | \
  while read -r f; do
    printf "  %-65s %s\n" "$(basename "$f")" "$(du -sh "$f" 2>/dev/null | cut -f1)"
  done

echo ""
echo -e "${BOLD}Any failures (re-run to retry):${RESET}"
grep "^\[!\]" "$LOG_FILE" 2>/dev/null | tail -20 || echo "  None!"

echo ""
echo -e "${CYAN}Log: ${LOG_FILE}${RESET}"
echo -e "${CYAN}Re-run anytime to resume or retry failed downloads.${RESET}"
