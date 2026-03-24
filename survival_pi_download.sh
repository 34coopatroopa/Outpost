#!/usr/bin/env bash
# =============================================================================
#  SURVIVAL PI - MASTER DOWNLOAD SCRIPT
#  Downloads all offline survival content in lean/optimized versions
#  Target: ~65GB total | Raspberry Pi 5 compatible
#
#  Usage:
#    chmod +x survival_pi_download.sh
#    ./survival_pi_download.sh [--dir /path/to/storage] [--skip-games] [--skip-ai]
#
#  Requirements:
#    sudo apt install wget curl aria2 rsync python3 git
# =============================================================================

set -uo pipefail   # removed -e so individual failures don't kill the whole script
# Each section handles its own errors with || warn "..." patterns

# ─── COLOUR OUTPUT ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${GREEN}[✔]${RESET} $*"; }
info()    { echo -e "${CYAN}[i]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✘]${RESET} $*"; }
section() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}\n"; }

# ─── DEFAULTS ─────────────────────────────────────────────────────────────────
BASE_DIR="${HOME}/survival_pi"
SKIP_GAMES=false
SKIP_AI=false
SKIP_MAPS=false
ARIA2_CONNECTIONS=8        # parallel connections per download
LOG_FILE="${BASE_DIR}/download.log"

# ─── ARGUMENT PARSING ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)       BASE_DIR="$2"; shift 2 ;;
    --skip-games) SKIP_GAMES=true; shift ;;
    --skip-ai)   SKIP_AI=true; shift ;;
    --skip-maps) SKIP_MAPS=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--dir PATH] [--skip-games] [--skip-ai] [--skip-maps]"
      exit 0 ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── DIRECTORY LAYOUT ─────────────────────────────────────────────────────────
ZIM_DIR="${BASE_DIR}/kiwix/zims"
MAPS_DIR="${BASE_DIR}/maps"
MANUALS_DIR="${BASE_DIR}/manuals"
MEDICAL_DIR="${BASE_DIR}/manuals/medical"
MILITARY_DIR="${BASE_DIR}/manuals/military"
SURVIVAL_DIR="${BASE_DIR}/manuals/survival"
FORAGING_DIR="${BASE_DIR}/manuals/foraging"
AGRICULTURE_DIR="${BASE_DIR}/manuals/agriculture"
REPAIR_DIR="${BASE_DIR}/manuals/repair"
BOOKS_DIR="${BASE_DIR}/books"
COMICS_DIR="${BASE_DIR}/comics"
GAMES_DIR="${BASE_DIR}/games"
AI_DIR="${BASE_DIR}/ai"

mkdir -p "$ZIM_DIR" "$MAPS_DIR" "$MANUALS_DIR" "$MEDICAL_DIR" \
         "$MILITARY_DIR" "$SURVIVAL_DIR" "$FORAGING_DIR" \
         "$AGRICULTURE_DIR" "$REPAIR_DIR" "$BOOKS_DIR" \
         "$COMICS_DIR" "$GAMES_DIR" "$AI_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

# ─── DEPENDENCY CHECK ─────────────────────────────────────────────────────────
section "Checking Dependencies"

MISSING=()
for cmd in wget curl aria2c rsync git python3; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("$cmd")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  warn "Missing tools: ${MISSING[*]}"
  info "Installing missing dependencies..."
  sudo apt-get update -qq
  sudo apt-get install -y wget curl aria2 rsync git python3 python3-pip --no-install-recommends
fi

log "All dependencies satisfied"

# ─── HELPER FUNCTIONS ─────────────────────────────────────────────────────────

# aria2c download with resume support
dl() {
  local url="$1"
  local dest="$2"
  local filename
  filename="$(basename "$url")"
  local filepath="${dest}/${filename}"

  if [[ -f "$filepath" ]]; then
    info "Already exists, skipping: $filename"
    return 0
  fi

  info "Downloading: $filename"
  aria2c \
    --dir="$dest" \
    --out="$filename" \
    --continue=true \
    --max-connection-per-server="$ARIA2_CONNECTIONS" \
    --split="$ARIA2_CONNECTIONS" \
    --min-split-size=10M \
    --retry-wait=5 \
    --max-tries=10 \
    --file-allocation=none \
    --console-log-level=warn \
    "$url" && log "Done: $filename" || warn "Failed: $filename (will retry on next run)"
}

# wget fallback for small files
dlw() {
  local url="$1"
  local dest="$2"
  local filename
  filename="$(basename "$url")"

  if [[ -f "${dest}/${filename}" ]]; then
    info "Already exists, skipping: $filename"
    return 0
  fi

  wget -q --show-progress -c -P "$dest" "$url" \
    && log "Done: $filename" \
    || warn "Failed: $filename"
}

# Get latest ZIM filename from Kiwix catalog for a given prefix
latest_zim() {
  local prefix="$1"
  # Query Kiwix download listing and find latest file matching prefix
  curl -s "https://download.kiwix.org/zim/${prefix%%_*}/" 2>/dev/null \
    | grep -oP "href=\"${prefix}[^\"]+\.zim\"" \
    | grep -oP "${prefix}[^\"]+\.zim" \
    | sort -V | tail -1
}

# ─── DISK SPACE CHECK ─────────────────────────────────────────────────────────
section "Disk Space Check"

AVAILABLE_KB=$(df -k "$BASE_DIR" | awk 'NR==2 {print $4}')
AVAILABLE_GB=$(( AVAILABLE_KB / 1024 / 1024 ))
REQUIRED_GB=70

info "Storage location : $BASE_DIR"
info "Available space  : ${AVAILABLE_GB}GB"
info "Estimated needed : ~${REQUIRED_GB}GB (lean build)"

if (( AVAILABLE_GB < 20 )); then
  error "Less than 20GB free! Please free up space or use --dir to point to a larger drive."
  exit 1
elif (( AVAILABLE_GB < REQUIRED_GB )); then
  warn "Less than ${REQUIRED_GB}GB free. Some downloads may be skipped."
fi

# ─── 1. KIWIX ZIM FILES ───────────────────────────────────────────────────────
section "1 / 8  —  Kiwix ZIM Files (Offline Knowledge)"

# Install kiwix-tools if not present
if ! command -v kiwix-serve &>/dev/null; then
  info "Installing kiwix-tools..."
  sudo apt-get install -y kiwix-tools 2>/dev/null || \
    warn "kiwix-tools not in apt — install manually from https://kiwix.org/en/download/"
fi

KIWIX_BASE="https://download.kiwix.org/zim"

# ── Helper: get the latest ZIM for a given category and filename prefix ──
# Uses Kiwix's library.xml catalog which is more reliable than scraping HTML
get_latest_zim_url() {
  local category="$1"   # e.g. "wikipedia"
  local prefix="$2"     # e.g. "wikipedia_en_all_nopic"
  local fallback="$3"   # full fallback URL

  local found
  # Try catalog XML first (most reliable)
  found=$(curl -sL "https://library.kiwix.org/catalog/v2/entries?lang=eng&count=1&name=${prefix}" \
    2>/dev/null \
    | grep -oP 'https://download\.kiwix\.org/zim/[^"<]+\.zim' \
    | head -1 || true)

  # If catalog didn't work, try scraping the directory listing
  if [[ -z "$found" ]]; then
    found=$(curl -sL "${KIWIX_BASE}/${category}/" 2>/dev/null \
      | grep -oP "href=\"[^\"]*${prefix}[^\"]*\.zim\"" \
      | grep -oP "${prefix}[^\"]+\.zim" \
      | grep -v '\.torrent\|\.meta4\|\.magnet' \
      | sort -V | tail -1 || true)
    [[ -n "$found" ]] && found="${KIWIX_BASE}/${category}/${found}"
  fi

  # Fall back to known-good URL
  if [[ -z "$found" ]]; then
    warn "Auto-detect failed for ${prefix} — using fallback URL"
    found="$fallback"
  fi

  echo "$found"
}

# ── Wikipedia English nopic (~25GB) ──
info "Fetching latest Wikipedia (no pictures) ZIM..."
WIKI_URL=$(get_latest_zim_url "wikipedia" "wikipedia_en_all_nopic" \
  "${KIWIX_BASE}/wikipedia/wikipedia_en_all_nopic_2025-12.zim")
dl "$WIKI_URL" "$ZIM_DIR"

# ── iFixit repair guides (~2.5GB) ──
info "Fetching latest iFixit ZIM..."
IFIXIT_URL=$(get_latest_zim_url "ifixit" "ifixit_en_maxi" \
  "${KIWIX_BASE}/ifixit/ifixit_en_maxi_2025-01.zim")
dl "$IFIXIT_URL" "$ZIM_DIR"

# ── Wikibooks how-to guides (~4GB) ──
info "Fetching latest Wikibooks ZIM..."
WIKIBOOKS_URL=$(get_latest_zim_url "wikibooks" "wikibooks_en_all_maxi" \
  "${KIWIX_BASE}/wikibooks/wikibooks_en_all_maxi_2025-12.zim")
dl "$WIKIBOOKS_URL" "$ZIM_DIR"

# ── Wikivoyage trails & campsites (~1GB) ──
info "Fetching latest Wikivoyage ZIM..."
WIKIVOYAGE_URL=$(get_latest_zim_url "wikivoyage" "wikivoyage_en_all_maxi" \
  "${KIWIX_BASE}/wikivoyage/wikivoyage_en_all_maxi_2025-12.zim")
dl "$WIKIVOYAGE_URL" "$ZIM_DIR"

# ── Wikisource historic texts (~10GB) ──
info "Fetching latest Wikisource ZIM..."
WIKISOURCE_URL=$(get_latest_zim_url "wikisource" "wikisource_en_all_maxi" \
  "${KIWIX_BASE}/wikisource/wikisource_en_all_maxi_2025-12.zim")
dl "$WIKISOURCE_URL" "$ZIM_DIR"

# ── Stack Exchange practical Q&A (per subject ~200-500MB each) ──
declare -A STACK_FALLBACKS=(
  ["electronics"]="${KIWIX_BASE}/stack_exchange/stack_exchange_electronics_en_all_2025-02.zim"
  ["diy"]="${KIWIX_BASE}/stack_exchange/stack_exchange_diy_en_all_2025-02.zim"
  ["cooking"]="${KIWIX_BASE}/stack_exchange/stack_exchange_cooking_en_all_2025-02.zim"
  ["outdoors"]="${KIWIX_BASE}/stack_exchange/stack_exchange_outdoors_en_all_2025-02.zim"
  ["mechanics"]="${KIWIX_BASE}/stack_exchange/stack_exchange_mechanics_en_all_2025-02.zim"
  ["gardening"]="${KIWIX_BASE}/stack_exchange/stack_exchange_gardening_en_all_2025-02.zim"
)

for STACK in "${!STACK_FALLBACKS[@]}"; do
  info "Fetching Stack Exchange: $STACK"
  STACK_URL=$(get_latest_zim_url "stack_exchange" "stack_exchange_${STACK}_en" \
    "${STACK_FALLBACKS[$STACK]}")
  dl "$STACK_URL" "$ZIM_DIR" || warn "Skipping Stack Exchange ${STACK}"
done

log "Kiwix ZIMs complete"

# ─── 2. OFFLINE MAPS ──────────────────────────────────────────────────────────
section "2 / 8  —  Offline Maps"

if [[ "$SKIP_MAPS" == "true" ]]; then
  warn "Skipping maps (--skip-maps)"
else
  GEOFABRIK="https://download.geofabrik.de"

  # Detect region — default to US if undetectable
  DETECTED_REGION=$(curl -s --max-time 5 "https://ipapi.co/country/" 2>/dev/null) || true
  DETECTED_REGION="${DETECTED_REGION:-US}"
  # Sanitise — must be 2 uppercase letters
  [[ "$DETECTED_REGION" =~ ^[A-Z]{2}$ ]] || DETECTED_REGION="US"
  info "Detected country code: $DETECTED_REGION"

  # Map of country codes to Geofabrik regions
  case "$DETECTED_REGION" in
    US|CA)
      info "Downloading North America maps (US + Canada)..."
      dl "${GEOFABRIK}/north-america/us-latest.osm.pbf" "$MAPS_DIR"
      dl "${GEOFABRIK}/north-america/canada-latest.osm.pbf" "$MAPS_DIR"
      ;;
    GB|IE)
      dl "${GEOFABRIK}/europe/great-britain-latest.osm.pbf" "$MAPS_DIR"
      dl "${GEOFABRIK}/europe/ireland-and-northern-ireland-latest.osm.pbf" "$MAPS_DIR"
      ;;
    AU|NZ)
      dl "${GEOFABRIK}/australia-oceania/australia-latest.osm.pbf" "$MAPS_DIR"
      dl "${GEOFABRIK}/australia-oceania/new-zealand-latest.osm.pbf" "$MAPS_DIR"
      ;;
    *)
      warn "Region not auto-mapped — downloading world overview map"
      dl "${GEOFABRIK}/planet-latest.osm.pbf" "$MAPS_DIR" || \
        warn "Planet file is huge (>70GB). Consider manually downloading your region from https://download.geofabrik.de"
      ;;
  esac

  # USGS Topo map index (links to downloadable GeoPDFs)
  info "Saving USGS topo map download page reference..."
  cat > "${MAPS_DIR}/usgs_topo_download.txt" << 'EOF'
USGS Topographic Maps — Free Download
======================================
URL: https://apps.nationalmap.gov/downloader/
Format: GeoPDF (viewable offline in most PDF readers)
Instructions:
  1. Go to the URL above while online
  2. Search your area by coordinates or place name
  3. Select "US Topo" product
  4. Download as many quads as you need
  5. Copy .pdf files into this maps/ directory
EOF

  log "Maps complete"
fi

# ─── 3. MILITARY FIELD MANUALS ────────────────────────────────────────────────
section "3 / 8  —  Military Field Manuals"

ARCHIVE="https://archive.org/download"

declare -A MANUALS=(
  ["FM_21-76_Survival"]="Fm21-76SurvivalManual/FM21-76_SurvivalManual.pdf"
  ["FM_21-76-1_SERE"]="FM2176USARMYSURVIVALMANUAL/FM_21-76.pdf"
  ["FM_3-05.70_Survival_Updated"]="FM-21-76-US-Army-Survival-Manual/FM-21-76-US-Army-Survival-Manual.pdf"
  ["FM_31-70_Cold_Weather"]="army-fm-31-70/fm-31-70.pdf"
  ["FM_5-426_Carpentry"]="army-fm-5-426/fm-5-426.pdf"
  ["FM_5-428_Concrete_Masonry"]="army-fm-5-428/fm-5-428.pdf"
  ["FM_4-25.11_First_Aid"]="army-fm-4-25-11/fm-4-25-11.pdf"
  ["FM_3-06_Urban_Operations"]="army-fm-3-06/fm-3-06.pdf"
  ["TC_21-3_Soldiers_Handbook"]="army-tc-21-3/tc-21-3.pdf"
)

for NAME in "${!MANUALS[@]}"; do
  URL="${ARCHIVE}/${MANUALS[$NAME]}"
  OUTFILE="${MILITARY_DIR}/${NAME}.pdf"
  if [[ ! -f "$OUTFILE" ]]; then
    info "Downloading: $NAME"
    wget -q --show-progress -c -O "$OUTFILE" "$URL" \
      && log "Done: $NAME" \
      || warn "Failed: $NAME — check URL manually"
  else
    info "Already exists: $NAME"
  fi
done

# Also grab full Army FM index page for reference
cat > "${MILITARY_DIR}/more_manuals.txt" << 'EOF'
More Military Field Manuals — Manual Download
=============================================
All public domain US military manuals:
  https://archive.org/search?query=army+field+manual&mediatype=texts
  https://irp.fas.org/doddir/army/
  https://adtdl.army.mil/

Key manuals to consider adding:
  FM 3-97.6  — Mountain Operations
  FM 90-3    — Desert Operations
  FM 90-5    — Jungle Operations
  FM 31-70   — Basic Cold Weather Manual
  FM 21-10   — Field Hygiene and Sanitation
  FM 8-10-6  — Medical Evacuation
  TC 3-97.61 — Military Mountaineering
EOF

log "Military manuals complete"

# ─── 4. MEDICAL & HEALTH REFERENCES ──────────────────────────────────────────
section "4 / 8  —  Medical & Health References"

# Hesperian Health Guides (free community health books)
HESPERIAN_BASE="https://en.hesperian.org/hhg"

declare -A MEDICAL_BOOKS=(
  ["Where_There_Is_No_Doctor"]="https://store.hesperian.org/prod/Where_There_Is_No_Doctor.html"
  ["Where_There_Is_No_Dentist"]="https://store.hesperian.org/prod/Where_There_Is_No_Dentist.html"
)

# Hesperian books via archive.org (free PDF)
info "Downloading Hesperian community health books from Archive.org..."
dlw "https://archive.org/download/where-there-is-no-doctor-pdf/where-there-is-no-doctor.pdf" "$MEDICAL_DIR"
dlw "https://archive.org/download/WhereTherIsNoDentist/Where_Ther_Is_No_Dentist.pdf" "$MEDICAL_DIR"
dlw "https://archive.org/download/where-there-is-no-doctor-pdf/where-there-is-no-dentist.pdf" "$MEDICAL_DIR"

# US Army First Aid (public domain)
dlw "https://archive.org/download/army-fm-4-25-11/fm-4-25-11.pdf" "$MEDICAL_DIR"

# Wilderness medicine reference
cat > "${MEDICAL_DIR}/medical_resources.txt" << 'EOF'
Additional Medical References — Manual Download
===============================================
Hesperian Health Guides (FREE PDFs):
  https://hesperian.org/books-and-resources/
  - Where There Is No Doctor
  - Where There Is No Dentist
  - A Community Guide to Environmental Health
  - Disabled Village Children
  - Health Actions for Women

Merck Manual (Public Domain older editions):
  https://archive.org/search?query=merck+manual&mediatype=texts

US Army Medical Field Manuals:
  FM 8-10-6  Medical Evacuation
  FM 8-285   Treatment of Chemical Agent Casualties
  TM 8-227   Food Service Sanitation
  (All on archive.org)
EOF

log "Medical references complete"

# ─── 5. FORAGING, AGRICULTURE & FOOD PRESERVATION ────────────────────────────
section "5 / 8  —  Foraging, Agriculture & Food Preservation"

# Archive.org foraging books (public domain / open access)
FORAGING_BOOKS=(
  "https://archive.org/download/fieldguidetoedib0000pete_h5c3/fieldguidetoedib0000pete_h5c3.pdf"
  "https://archive.org/download/completeguidetoe0000lyle/completeguidetoe0000lyle.pdf"
  "https://archive.org/download/wildediblespract0000bout/wildediblespract0000bout.pdf"
)

for URL in "${FORAGING_BOOKS[@]}"; do
  dlw "$URL" "$FORAGING_DIR"
done

# USDA Complete Guide to Home Canning (food preservation bible)
dlw "https://nchfp.uga.edu/publications/publications_usda.html" "$FORAGING_DIR" || true
dlw "https://archive.org/download/usda-complete-guide-to-home-canning/usda-complete-guide-to-home-canning.pdf" "$FORAGING_DIR"

# Project Gutenberg agriculture books
info "Downloading Project Gutenberg agriculture books..."
declare -A GUTENBERG_AG=(
  ["Agriculture_for_Beginners"]="https://www.gutenberg.org/ebooks/5265.epub.images"
  ["Cottage_Economy"]="https://www.gutenberg.org/ebooks/14905.epub.images"
  ["First_Book_of_Farming"]="https://www.gutenberg.org/ebooks/10378.epub.images"
  ["Culinary_Herbs"]="https://www.gutenberg.org/ebooks/26763.epub.images"
  ["Elements_of_Agriculture"]="https://www.gutenberg.org/ebooks/24752.epub.images"
  ["Manual_of_Gardening"]="https://www.gutenberg.org/ebooks/9550.epub.images"
  ["Animal_Husbandry"]="https://www.gutenberg.org/ebooks/38185.epub.images"
  ["Beekeeping"]="https://www.gutenberg.org/ebooks/32085.epub.images"
)

for TITLE in "${!GUTENBERG_AG[@]}"; do
  URL="${GUTENBERG_AG[$TITLE]}"
  OUTFILE="${AGRICULTURE_DIR}/${TITLE}.epub"
  if [[ ! -f "$OUTFILE" ]]; then
    wget -q --show-progress -c -O "$OUTFILE" "$URL" \
      && log "Done: $TITLE" \
      || warn "Failed: $TITLE"
  else
    info "Already exists: $TITLE"
  fi
done

log "Foraging & agriculture complete"

# ─── 6. SURVIVOR LIBRARY ──────────────────────────────────────────────────────
section "6 / 8  —  Survivor Library (Technical Skills)"

info "Downloading Survivor Library mirror from Archive.org..."
info "This is ~6GB — please be patient..."

# Try rsync first (fastest for large collections), fall back to direct download
if rsync --version &>/dev/null; then
  rsync -avz --progress \
    "rsync://archive.org/survival.library/" \
    "${SURVIVAL_DIR}/survivor_library/" \
    2>/dev/null \
    && log "Survivor Library sync complete" \
    || {
      warn "rsync failed — trying direct archive download"
      dl "https://archive.org/compress/survival.library/formats=PDF&file=/survival.library.zip" "$SURVIVAL_DIR"
    }
else
  dl "https://archive.org/compress/survival.library/formats=PDF&file=/survival.library.zip" "$SURVIVAL_DIR"
fi

# Key individual categories also available directly at:
cat > "${SURVIVAL_DIR}/manual_downloads.txt" << 'EOF'
Survivor Library — Category Downloads
======================================
Visit: https://www.survivorlibrary.com/index.php/main-library-index/
Each category has a ZIP file with all books in that section.

Priority categories for survival:
  Survival_Individual    (~588MB ZIP)
  Farming                (~200MB ZIP)
  Farming2               (~150MB ZIP)
  Medical_Emergency      (~100MB ZIP)
  Medical_Medicine_1900  (~300MB ZIP)
  Butchering             (~50MB ZIP)
  Canning                (~80MB ZIP)
  Engineering_General    (~250MB ZIP)
  Engineering_Electrical (~200MB ZIP)
  Steam_Engines          (~100MB ZIP)
  Machine_Tools          (~150MB ZIP)
  Smithing               (~80MB ZIP)
  Firearms_Books         (~200MB ZIP)
  Livestock              (~300MB ZIP combined)
  Forestry               (~100MB ZIP)
  Fishing                (~80MB ZIP)
  Food                   (~150MB ZIP)
EOF

log "Survivor Library complete"

# ─── 7. GAMES (OPTIONAL) ──────────────────────────────────────────────────────
section "7 / 8  —  Games & Entertainment"

if [[ "$SKIP_GAMES" == "true" ]]; then
  warn "Skipping games (--skip-games)"
else
  # Install RetroPie dependencies
  info "Installing game emulation stack..."
  sudo apt-get install -y retroarch libretro-* 2>/dev/null \
    || warn "RetroArch packages not found in apt — install manually"

  # Open-source / public domain games (100% legal)
  info "Installing open source games..."
  sudo apt-get install -y \
    0ad \
    freeciv-client-gtk \
    openttd \
    supertuxkart \
    minetest \
    wesnoth \
    freesweep \
    nethack-console \
    2>/dev/null || warn "Some games not available in apt — check manually"

  # Legal MAME ROMs from MAMEdev
  info "Downloading legal freeware MAME ROMs..."
  mkdir -p "${GAMES_DIR}/mame_roms"
  cat > "${GAMES_DIR}/mame_roms/download_legal_roms.txt" << 'EOF'
Legal / Freeware MAME ROMs
===========================
Download from official sources:

1. MAMEDev Freeware ROMs:
   https://www.mamedev.org/roms/
   (Games officially released as freeware by rights holders)

2. Public Domain ROMs:
   https://www.zophar.net/pdroms.html
   https://pdroms.de/

3. Homebrew Games (free, no copyright issues):
   https://www.romhacking.net/homebrew/
   https://itch.io/games/free (many free indie games)

4. DOS Games (many now free):
   https://archive.org/details/softwarelibrary_msdos_games
   (Use DOSBox emulator — install with: sudo apt install dosbox)
EOF

  # DOSBox for classic DOS games
  sudo apt-get install -y dosbox 2>/dev/null || true

  # Public domain comics from Digital Comic Museum
  info "Creating comic download reference..."
  mkdir -p "${COMICS_DIR}"
  cat > "${COMICS_DIR}/download_comics.txt" << 'EOF'
Public Domain Comics — Free & Legal
=====================================
All pre-1928 comics are public domain in the US.

Sources:
  1. Digital Comic Museum: https://digitalcomicmuseum.com
     - Golden Age comics (1930s-1950s)
     - Thousands of issues, completely free

  2. Comic Book Plus: https://comicbookplus.com
     - More Golden Age public domain comics

  3. Internet Archive Comics:
     https://archive.org/details/comics
     - Massive collection, many public domain

Download tool (while online):
  pip3 install gallery-dl
  gallery-dl https://digitalcomicmuseum.com/preview/index.php?did=XXXX

Organize into /comics/<Series>/<Issue>.cbz for Komga/Kavita
EOF

  # Install Komga (comic server)
  if command -v java &>/dev/null || command -v docker &>/dev/null; then
    info "Setting up Komga comic server..."
    mkdir -p "${COMICS_DIR}/komga_config"
    KOMGA_VERSION=$(curl -s --max-time 10 "https://api.github.com/repos/gotson/komga/releases/latest" 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' || true)
    KOMGA_VERSION="${KOMGA_VERSION:-latest}"
    cat > "${COMICS_DIR}/start_komga.sh" << KOMGAEOF
#!/bin/bash
# Start Komga comic server
# Download Komga JAR first: https://github.com/gotson/komga/releases/latest
# Place komga.jar in this directory, then run this script

JAR_PATH="\$(dirname "\$0")/komga.jar"

if [[ ! -f "\$JAR_PATH" ]]; then
  echo "Downloading Komga..."
  KOMGA_URL=\$(curl -s --max-time 10 "https://api.github.com/repos/gotson/komga/releases/latest" \
    2>/dev/null | grep -oP '"browser_download_url": "\K[^"]+komga[^"]+\.jar' | head -1 || true)
  if [[ -z "\$KOMGA_URL" ]]; then
    echo "Could not auto-detect Komga URL. Download manually from:"
    echo "  https://github.com/gotson/komga/releases/latest"
    exit 1
  fi
  wget -O "\$JAR_PATH" "\$KOMGA_URL"
fi

java -jar "\$JAR_PATH" \
  --server.port=8080 \
  --komga.libraries-scan-cron="0 */15 * * * ?" \
  --spring.datasource.url="jdbc:h2:file:${COMICS_DIR}/komga_config/database"
KOMGAEOF
    chmod +x "${COMICS_DIR}/start_komga.sh"
    log "Komga setup complete — run ${COMICS_DIR}/start_komga.sh to start"
  fi

  log "Games & entertainment setup complete"
fi

# ─── 8. LOCAL AI (OPTIONAL) ───────────────────────────────────────────────────
section "8 / 8  —  Local AI (Offline LLM)"

if [[ "$SKIP_AI" == "true" ]]; then
  warn "Skipping AI (--skip-ai)"
else
  # Install Ollama
  if ! command -v ollama &>/dev/null; then
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh \
      && log "Ollama installed" \
      || warn "Ollama install failed — try manually: curl -fsSL https://ollama.com/install.sh | sh"
  else
    log "Ollama already installed"
  fi

  if command -v ollama &>/dev/null; then
    # Start Ollama service
    ollama serve &>/dev/null &
    sleep 3

    # Pull Phi-3 Mini — best model for Pi 5 (3.8B params, ~2.3GB at Q4)
    info "Pulling Phi-3 Mini model (~2.3GB — optimized for Pi 5)..."
    ollama pull phi3:mini \
      && log "Phi-3 Mini model ready" \
      || warn "Model pull failed — run manually: ollama pull phi3:mini"

    # Create a survival-tuned system prompt
    mkdir -p "${AI_DIR}"
    cat > "${AI_DIR}/survival_assistant.sh" << 'AIEOF'
#!/bin/bash
# Survival AI Assistant — powered by Ollama (fully offline)
# Usage: ./survival_assistant.sh

SYSTEM_PROMPT="You are an expert survival assistant with deep knowledge of:
- Wilderness survival, shelter building, fire starting, navigation
- Edible plants, foraging, hunting, fishing, trapping
- Field medicine, wound care, improvised first aid
- Off-grid farming, food preservation, animal husbandry
- Mechanical repair, engines, pumps, basic electronics
- Weather reading, navigation by stars, map reading
Always give practical, actionable advice. Prioritize safety. 
When discussing plants or medicine, always warn about dangerous look-alikes or risks."

echo "============================================"
echo "  SURVIVAL AI ASSISTANT (Offline)"
echo "  Model: phi3:mini | Type 'exit' to quit"
echo "============================================"
echo ""

ollama run phi3:mini --system "$SYSTEM_PROMPT"
AIEOF
    chmod +x "${AI_DIR}/survival_assistant.sh"
    log "Survival AI assistant configured at ${AI_DIR}/survival_assistant.sh"
  fi
fi

# ─── SETUP KIWIX AUTO-START ───────────────────────────────────────────────────
section "Setting Up Services"

# Create kiwix-serve systemd service
info "Creating kiwix-serve systemd service..."
sudo tee /etc/systemd/system/kiwix-serve.service > /dev/null << SVCEOF
[Unit]
Description=Kiwix Offline Knowledge Server
After=network.target

[Service]
Type=simple
User=${USER}
ExecStart=/usr/bin/kiwix-serve --port=8080 --library ${ZIM_DIR}/library.xml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# Build kiwix library index from all downloaded ZIMs
if command -v kiwix-manage &>/dev/null; then
  info "Building Kiwix library index..."
  LIBRARY_FILE="${ZIM_DIR}/library.xml"
  # Remove old library
  rm -f "$LIBRARY_FILE"
  # Add all ZIMs
  for ZIM in "${ZIM_DIR}"/*.zim; do
    [[ -f "$ZIM" ]] && kiwix-manage "$LIBRARY_FILE" add "$ZIM" 2>/dev/null && log "Added to library: $(basename $ZIM)"
  done
  sudo systemctl daemon-reload
  sudo systemctl enable kiwix-serve
  sudo systemctl start kiwix-serve
  log "Kiwix server running at http://localhost:8080"
fi

# ─── FINAL SUMMARY ────────────────────────────────────────────────────────────
section "Download Complete!"

echo ""
echo -e "${BOLD}Storage used:${RESET}"
du -sh "${BASE_DIR}"/* 2>/dev/null | sort -h

echo ""
echo -e "${BOLD}Services:${RESET}"
echo -e "  ${GREEN}📚 Kiwix (Wikipedia, iFixit, Wikibooks...)${RESET}  → http://localhost:8080"
echo -e "  ${GREEN}🗺️  Maps data${RESET}                               → ${MAPS_DIR}"
echo -e "  ${GREEN}📖 Manuals & books${RESET}                          → ${MANUALS_DIR}"
[[ "$SKIP_GAMES" == "false" ]] && echo -e "  ${GREEN}🎮 Comics server${RESET}                            → ${COMICS_DIR}/start_komga.sh"
[[ "$SKIP_AI" == "false" ]] && echo -e "  ${GREEN}🤖 Survival AI${RESET}                              → ${AI_DIR}/survival_assistant.sh"

echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Run the GUI setup:  ./survival_pi_gui.sh"
echo "  2. Add your comics/books to ${COMICS_DIR} and ${BOOKS_DIR}"
echo "  3. Download additional content listed in the .txt reference files"
echo "  4. Access Kiwix at http://localhost:8080 from any device on your network"
echo ""
echo -e "${CYAN}Log saved to: ${LOG_FILE}${RESET}"
echo ""
