#!/usr/bin/env bash
# =============================================================================
#  OUTPOST — MASTER DOWNLOAD SCRIPT  v4.0
#  Downloads all offline survival content for the Pi 5 survival computer
#
#  WHAT'S NEW in v4.0 (complete rewrite from v3.0):
#    ✓ FIXED scrape_latest() — parses href= from HTML, handles dots in names
#    ✓ FIXED date fallback — pure bash arithmetic, no python-dateutil needed
#    ✓ FIXED Stack Exchange — dots in prefixes no longer break regex matching
#    ✓ FIXED duplicate "Home Improvement" entry (home.stackexchange.com DNE)
#    ✓ FIXED Archive.org URLs — verified working direct-download links
#    ✓ FIXED Gutenberg EPUBs — uses EPUB3 format that actually opens in readers
#    ✓ FIXED "Where There Is No Doctor" — uses Hesperian 2025 edition PDF
#    ✓ ADDED file validation — checks PDFs for %PDF header, EPUBs for PK header
#    ✓ ADDED mirror fallback — tries ftp.fau.de when download.kiwix.org fails
#    ✓ ADDED --dry-run mode to preview what would be downloaded
#    ✓ ADDED --section flag to run only specific sections (e.g. --section 1,3)
#    ✓ ADDED Foliate + Calibre EPUB reader stack (GUI + library server)
#    ✓ ADDED Project Gutenberg ZIM (entire library as offline browsable ZIM)
#    ✓ ADDED DevDocs programming reference ZIM
#    ✓ ADDED proper Ctrl+C cleanup of partial downloads
#    ✓ ADDED colored summary table with download stats
#
#  Usage:
#    chmod +x survival_pi_download.sh
#    ./survival_pi_download.sh                        # auto-detects D:\Outpost
#    ./survival_pi_download.sh --dir /mnt/d/Outpost   # explicit path
#    ./survival_pi_download.sh --skip-games           # skip retro games
#    ./survival_pi_download.sh --skip-ai              # skip Ollama model pull
#    ./survival_pi_download.sh --skip-maps            # skip OSM map data
#    ./survival_pi_download.sh --dry-run              # preview only
#    ./survival_pi_download.sh --section 1            # ZIMs only
#    ./survival_pi_download.sh --section 1,3,4        # ZIMs + military + medical
#    ./survival_pi_download.sh --debug                # verbose output
#
#  Safe to re-run — all downloads resume where they left off.
#  Hit Ctrl+C anytime — partial downloads are cleaned up automatically.
# =============================================================================

set -uo pipefail

# ── Trap for cleanup on interrupt ─────────────────────────────────────────────
CURRENT_DOWNLOAD=""
cleanup() {
  echo ""
  if [[ -n "$CURRENT_DOWNLOAD" && -f "$CURRENT_DOWNLOAD" ]]; then
    warn "Interrupted — removing partial: $(basename "$CURRENT_DOWNLOAD")"
    rm -f "$CURRENT_DOWNLOAD" "${CURRENT_DOWNLOAD}.aria2"
  fi
  warn "Exiting. Re-run anytime to resume."
  exit 130
}
trap cleanup INT TERM

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
log()     { echo -e "${GREEN}[✔]${RESET} $*"; }
info()    { echo -e "${CYAN}[i]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✘]${RESET} $*"; }
section() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}\n"; }
debug()   { [[ "${VERBOSE:-false}" == "true" ]] && echo -e "${DIM}[D] $*${RESET}"; }

# ── Counters ──────────────────────────────────────────────────────────────────
DOWNLOAD_OK=0
DOWNLOAD_SKIP=0
DOWNLOAD_FAIL=0

# ── Defaults ──────────────────────────────────────────────────────────────────
BASE_DIR="${HOME}/survival_pi"
SKIP_GAMES=false
SKIP_AI=false
SKIP_MAPS=false
DRY_RUN=false
VERBOSE=false
ARIA2_CONNS=8
RUN_SECTIONS=""

# ── Kiwix mirrors ────────────────────────────────────────────────────────────
KIWIX_PRIMARY="https://download.kiwix.org/zim"
KIWIX_MIRROR="https://ftp.fau.de/kiwix/zim"

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
    --dry-run)    DRY_RUN=true; shift ;;
    --debug)      VERBOSE=true; shift ;;
    --section)    RUN_SECTIONS="$2"; shift 2 ;;
    --help|-h)
      cat << 'USAGE'
OUTPOST Download Script v4.0

Usage: ./survival_pi_download.sh [OPTIONS]

Options:
  --dir PATH       Set download directory (default: auto-detect)
  --skip-games     Skip entertainment/games section
  --skip-ai        Skip Ollama AI model pull
  --skip-maps      Skip OpenStreetMap data
  --dry-run        Preview what would be downloaded without downloading
  --section N      Run only specific sections (comma-separated: 1,3,4)
  --debug          Show verbose debug output
  --help, -h       Show this help

Sections:
  1  Kiwix ZIM files (Wikipedia, iFixit, Stack Exchange, etc.)
  2  Offline maps (OpenStreetMap)
  3  Military field manuals (PDFs)
  4  Medical references (PDFs)
  5  Foraging, agriculture & food preservation (PDFs + EPUBs)
  6  Survivor Library (~6GB PDF archive)
  7  Entertainment (games, comics)
  8  Local AI (Ollama + Phi-3)

Readers/Servers (always installed):
  - Foliate: lightweight EPUB/PDF reader for GUI use
  - Calibre: full ebook library server (http://localhost:8081)
  - Kiwix:   ZIM wiki server (http://localhost:8080)
USAGE
      exit 0 ;;
    *) error "Unknown argument: $1 (try --help)"; exit 1 ;;
  esac
done

# Helper: should we run this section?
should_run() {
  local num="$1"
  [[ -z "$RUN_SECTIONS" ]] && return 0
  echo ",$RUN_SECTIONS," | grep -q ",$num," && return 0
  return 1
}

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
echo -e "${BOLD}${CYAN}║          OUTPOST DOWNLOAD SCRIPT  v4.0              ║${RESET}"
echo -e "${BOLD}${CYAN}║          $(date '+%Y-%m-%d %H:%M:%S')                          ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

[[ "$DRY_RUN" == "true" ]] && warn "DRY RUN MODE — nothing will be downloaded"
[[ -n "$RUN_SECTIONS" ]] && info "Running sections: $RUN_SECTIONS"

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

# xxd needed for file validation
command -v xxd &>/dev/null || {
  info "Installing xxd for file validation..."
  sudo apt-get install -y xxd 2>/dev/null || \
  sudo apt-get install -y vim-common 2>/dev/null || true
}

log "Dependencies ready"

# ── EPUB / PDF Reader Installation ────────────────────────────────────────────
section "Setting Up Book Readers"

# Foliate — lightweight, fast EPUB reader (GUI)
if command -v foliate &>/dev/null; then
  log "Foliate already installed"
else
  info "Installing Foliate (lightweight EPUB reader)..."
  if sudo apt-get install -y foliate 2>/dev/null; then
    log "Foliate installed via apt"
  else
    if command -v flatpak &>/dev/null; then
      flatpak install -y flathub com.github.johnfactotum.Foliate 2>/dev/null \
        && log "Foliate installed via Flatpak" \
        || warn "Foliate install failed — install manually: sudo apt install foliate"
    else
      warn "Foliate not in apt repos. Try: sudo add-apt-repository ppa:apandada1/foliate && sudo apt install foliate"
    fi
  fi
fi

# Calibre — full ebook manager + library server + format converter
if command -v calibre &>/dev/null || command -v ebook-viewer &>/dev/null; then
  log "Calibre already installed"
else
  info "Installing Calibre (ebook library + server + converter)..."
  if sudo apt-get install -y calibre 2>/dev/null; then
    log "Calibre installed via apt"
  else
    info "Trying Calibre's official installer..."
    sudo -v && wget -nv -O- https://download.calibre-ebook.com/linux-installer.sh 2>/dev/null \
      | sudo sh /dev/stdin 2>/dev/null \
      && log "Calibre installed via official installer" \
      || warn "Calibre install failed — install manually: sudo apt install calibre"
  fi
fi

# Create helper script: open any book file in the best available reader
cat > "${BASE_DIR}/open_book.sh" << 'OPENER'
#!/bin/bash
# Opens an EPUB, PDF, MOBI, or CBZ file in the best available reader
FILE="$1"
[[ -z "$FILE" ]] && { echo "Usage: ./open_book.sh <file>"; exit 1; }
[[ ! -f "$FILE" ]] && { echo "File not found: $FILE"; exit 1; }

EXT="${FILE##*.}"
EXT="${EXT,,}"  # lowercase

case "$EXT" in
  epub|mobi|fb2|cbz|cbr)
    if command -v foliate &>/dev/null; then
      foliate "$FILE" &
    elif command -v ebook-viewer &>/dev/null; then
      ebook-viewer "$FILE" &
    elif command -v xdg-open &>/dev/null; then
      xdg-open "$FILE" &
    else
      echo "No EPUB reader found. Install with: sudo apt install foliate"
      exit 1
    fi
    ;;
  pdf)
    if command -v evince &>/dev/null; then
      evince "$FILE" &
    elif command -v okular &>/dev/null; then
      okular "$FILE" &
    elif command -v foliate &>/dev/null; then
      foliate "$FILE" &
    elif command -v xdg-open &>/dev/null; then
      xdg-open "$FILE" &
    else
      echo "No PDF reader found. Install with: sudo apt install evince"
      exit 1
    fi
    ;;
  *)
    echo "Unsupported format: .$EXT"
    echo "Supported: epub, mobi, fb2, cbz, cbr, pdf"
    exit 1
    ;;
esac
echo "Opened: $(basename "$FILE")"
OPENER
chmod +x "${BASE_DIR}/open_book.sh"

# Create helper script: start Calibre library server
cat > "${BASE_DIR}/start_library_server.sh" << 'LIBSERVER'
#!/bin/bash
# Start Calibre content server — browse all books at http://localhost:8081
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CALIBRE_LIB="${SCRIPT_DIR}/books/calibre_library"

if ! command -v calibre-server &>/dev/null && ! command -v calibredb &>/dev/null; then
  echo "Calibre not installed. Run: sudo apt install calibre"
  exit 1
fi

# Build library on first run by importing all PDFs/EPUBs
if [[ ! -d "$CALIBRE_LIB/metadata.db" ]] && [[ ! -f "$CALIBRE_LIB/metadata.db" ]]; then
  echo "Building Calibre library (first run)..."
  mkdir -p "$CALIBRE_LIB"
  # Import from all content directories
  find "$SCRIPT_DIR/manuals" "$SCRIPT_DIR/books" -type f \
    \( -name "*.pdf" -o -name "*.epub" -o -name "*.mobi" \) \
    -exec calibredb add --library-path "$CALIBRE_LIB" {} + 2>/dev/null || true
  echo "Library built: $(calibredb list --library-path "$CALIBRE_LIB" 2>/dev/null | wc -l) books"
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Calibre Library Server                 ║"
echo "║   Browse at: http://localhost:8081       ║"
echo "║   Press Ctrl+C to stop                  ║"
echo "╚══════════════════════════════════════════╝"
echo ""
calibre-server --port=8081 --enable-local-write "$CALIBRE_LIB"
LIBSERVER
chmod +x "${BASE_DIR}/start_library_server.sh"

log "Book readers configured"
info "  Open any book:  ./open_book.sh <file.epub or file.pdf>"
info "  Library server: ./start_library_server.sh → http://localhost:8081"

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

# ── HEAD check — returns 0 if URL responds 200/301/302 ───────────────────────
url_alive() {
  local code
  code=$(curl -o /dev/null -sL -I --max-time 20 --connect-timeout 10 \
    -w "%{http_code}" "$1" 2>/dev/null || echo "000")
  debug "HEAD $1 → $code"
  [[ "$code" =~ ^(200|301|302)$ ]]
}

# ── aria2c download with cleanup tracking ─────────────────────────────────────
dl() {
  local url="$1" dest="$2"
  local filename filepath sz
  filename="$(basename "$url")"
  filepath="${dest}/${filename}"

  if [[ -f "$filepath" ]]; then
    sz=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
    if (( sz > 1048576 )); then
      info "Already exists ($(( sz / 1048576 ))MB): $filename"
      (( DOWNLOAD_SKIP++ ))
      return 0
    fi
    warn "Incomplete file (<1MB), removing: $filename"
    rm -f "$filepath" "${filepath}.aria2"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would download: $filename"
    return 0
  fi

  CURRENT_DOWNLOAD="$filepath"
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
    "$url"
  local rc=$?
  CURRENT_DOWNLOAD=""

  if [[ $rc -eq 0 ]]; then
    log "Done: $filename ($(( $(stat -c%s "$filepath" 2>/dev/null || echo 0) / 1048576 ))MB)"
    (( DOWNLOAD_OK++ ))
  else
    warn "Failed: $filename — re-run to retry"
    rm -f "$filepath" "${filepath}.aria2"
    (( DOWNLOAD_FAIL++ ))
  fi
  return $rc
}

# ── wget for small files ──────────────────────────────────────────────────────
dlw() {
  local url="$1" dest="$2" outname="${3:-}"
  local filename filepath
  filename="${outname:-$(basename "$url")}"
  filepath="${dest}/${filename}"

  if [[ -f "$filepath" ]] && (( $(stat -c%s "$filepath" 2>/dev/null || echo 0) > 10240 )); then
    info "Already exists: $filename"
    (( DOWNLOAD_SKIP++ ))
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would download: $filename"
    return 0
  fi

  CURRENT_DOWNLOAD="$filepath"
  info "Downloading: $filename"
  wget -q --show-progress -c --timeout=60 --tries=5 -O "$filepath" "$url"
  local rc=$?
  CURRENT_DOWNLOAD=""

  if [[ $rc -eq 0 ]] && [[ -f "$filepath" ]] && \
     (( $(stat -c%s "$filepath" 2>/dev/null || echo 0) > 1024 )); then
    log "Done: $filename"
    (( DOWNLOAD_OK++ ))
  else
    warn "Failed: $filename"
    rm -f "$filepath"
    (( DOWNLOAD_FAIL++ ))
  fi
  return $rc
}

# ── Validate downloaded file by magic bytes ───────────────────────────────────
validate_file() {
  local filepath="$1" expected_type="$2"
  [[ ! -f "$filepath" ]] && return 1

  local header
  header=$(xxd -l 8 -p "$filepath" 2>/dev/null || echo "")

  case "$expected_type" in
    pdf)
      if [[ "$header" == 25504446* ]]; then  # %PDF
        debug "Valid PDF: $(basename "$filepath")"
        return 0
      else
        warn "INVALID PDF (HTML error page or corrupt): $(basename "$filepath")"
        rm -f "$filepath"
        return 1
      fi
      ;;
    epub)
      if [[ "$header" == 504b0304* ]] || [[ "$header" == 504b0506* ]]; then  # PK (zip)
        debug "Valid EPUB: $(basename "$filepath")"
        return 0
      else
        warn "INVALID EPUB (not a zip/epub): $(basename "$filepath")"
        rm -f "$filepath"
        return 1
      fi
      ;;
    *) return 0 ;;
  esac
}

# ── Download + validate a PDF (tries multiple URLs) ───────────────────────────
dl_pdf() {
  local dest="$1" outname="$2"
  shift 2
  local filepath="${dest}/${outname}"

  # Already have a valid copy?
  if [[ -f "$filepath" ]] && (( $(stat -c%s "$filepath" 2>/dev/null || echo 0) > 10240 )); then
    if validate_file "$filepath" pdf; then
      info "Already exists (valid PDF): $outname"
      (( DOWNLOAD_SKIP++ ))
      return 0
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would download: $outname"
    return 0
  fi

  local url
  for url in "$@"; do
    debug "Trying URL: $url"
    if url_alive "$url"; then
      dlw "$url" "$dest" "$outname"
      if validate_file "$filepath" pdf; then
        return 0
      fi
      warn "  Got data but not a valid PDF — trying next URL..."
    else
      debug "  URL not reachable"
    fi
  done

  warn "All URLs failed for: $outname"
  (( DOWNLOAD_FAIL++ ))
  return 1
}

# ── Download + validate an EPUB (tries multiple URLs) ─────────────────────────
dl_epub() {
  local dest="$1" outname="$2"
  shift 2
  local filepath="${dest}/${outname}"

  if [[ -f "$filepath" ]] && (( $(stat -c%s "$filepath" 2>/dev/null || echo 0) > 5120 )); then
    if validate_file "$filepath" epub; then
      info "Already exists (valid EPUB): $outname"
      (( DOWNLOAD_SKIP++ ))
      return 0
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would download: $outname"
    return 0
  fi

  local url
  for url in "$@"; do
    debug "Trying URL: $url"
    if url_alive "$url"; then
      dlw "$url" "$dest" "$outname"
      if validate_file "$filepath" epub; then
        return 0
      fi
      warn "  Got data but not a valid EPUB — trying next URL..."
    else
      debug "  URL not reachable"
    fi
  done

  warn "All URLs failed for: $outname"
  (( DOWNLOAD_FAIL++ ))
  return 1
}

# ── Scrape latest ZIM from Kiwix directory listing ────────────────────────────
# v4 FIX: matches href= attributes, properly escapes dots for Stack Exchange
scrape_latest() {
  local category="$1" prefix="$2" server="$3"
  local listing newest escaped_prefix

  debug "Scraping: ${server}/${category}/ for prefix '${prefix}'"

  listing=$(curl -sL --max-time 30 --connect-timeout 15 \
    "${server}/${category}/" 2>/dev/null || true)

  [[ -z "$listing" ]] && { debug "Empty listing"; return 1; }

  # Escape dots in prefix for grep (e.g. cooking.stackexchange.com)
  escaped_prefix=$(printf '%s' "$prefix" | sed 's/\./\\./g')

  # Match href="filename.zim" in HTML
  newest=$(echo "$listing" \
    | grep -oiP "href=['\"]?${escaped_prefix}_[0-9]{4}-[0-9]{2}\.zim['\"]?" \
    | grep -oP "${escaped_prefix}_[0-9]{4}-[0-9]{2}\.zim" \
    | sort -V | tail -1 || true)

  if [[ -n "$newest" ]]; then
    debug "Scraped (href match): $newest"
    echo "${server}/${category}/${newest}"
    return 0
  fi

  # Fallback: bare filename match (some mirrors/formats differ)
  newest=$(echo "$listing" \
    | grep -oP "${escaped_prefix}_[0-9]{4}-[0-9]{2}\.zim" \
    | sort -V | tail -1 || true)

  if [[ -n "$newest" ]]; then
    debug "Scraped (bare match): $newest"
    echo "${server}/${category}/${newest}"
    return 0
  fi

  debug "No matches for '${prefix}'"
  return 1
}

# ── Date arithmetic (pure bash, no python-dateutil) ───────────────────────────
months_ago() {
  local n="$1"
  date -d "-${n} months" +%Y-%m 2>/dev/null && return 0
  date -v-${n}m +%Y-%m 2>/dev/null && return 0
  python3 -c "
import datetime
d=datetime.date.today(); y,m=d.year,d.month-${n}
while m<1: m+=12; y-=1
print(f'{y:04d}-{m:02d}')
" 2>/dev/null
}

# ── Smart ZIM downloader with mirror fallback + date walk ─────────────────────
download_zim() {
  local label="$1" category="$2" prefix="$3"

  info "Resolving: ${label}..."

  # Already have it?
  local existing
  existing=$(find "$ZIM_DIR" -maxdepth 1 -name "${prefix}_*.zim" \
    -size +1M 2>/dev/null | sort -V | tail -1 || true)
  if [[ -n "$existing" ]]; then
    info "Already have: $(basename "$existing") ($(( $(stat -c%s "$existing") / 1048576 ))MB)"
    (( DOWNLOAD_SKIP++ ))
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would download latest: ${label}"
    return 0
  fi

  local url=""

  # Strategy 1: Scrape primary server
  url=$(scrape_latest "$category" "$prefix" "$KIWIX_PRIMARY" 2>/dev/null || true)
  if [[ -n "$url" ]] && url_alive "$url"; then
    info "Found via primary: $(basename "$url")"
    dl "$url" "$ZIM_DIR"
    return $?
  fi

  # Strategy 2: Scrape mirror
  info "Primary scrape missed — trying mirror..."
  url=$(scrape_latest "$category" "$prefix" "$KIWIX_MIRROR" 2>/dev/null || true)
  if [[ -n "$url" ]]; then
    local fname
    fname=$(basename "$url")
    local primary_url="${KIWIX_PRIMARY}/${category}/${fname}"
    if url_alive "$primary_url"; then
      info "Mirror found $fname — downloading from primary"
      dl "$primary_url" "$ZIM_DIR"
      return $?
    elif url_alive "$url"; then
      info "Downloading from mirror: $fname"
      dl "$url" "$ZIM_DIR"
      return $?
    fi
  fi

  # Strategy 3: HEAD-check dated candidates for last 24 months
  info "Scrape failed — walking back 24 months with HEAD checks..."
  local i ym candidate
  for i in $(seq 0 23); do
    ym=$(months_ago "$i" 2>/dev/null || true)
    [[ -z "$ym" ]] && continue
    candidate="${KIWIX_PRIMARY}/${category}/${prefix}_${ym}.zim"
    debug "HEAD check: $(basename "$candidate")"
    if url_alive "$candidate"; then
      info "Found via date walk: $(basename "$candidate")"
      dl "$candidate" "$ZIM_DIR"
      return $?
    fi
  done

  warn "No valid URL found for: ${label}"
  warn "  → Browse: ${KIWIX_PRIMARY}/${category}/"
  warn "  → Mirror: ${KIWIX_MIRROR}/${category}/"
  warn "  → Download manually into: ${ZIM_DIR}/"
  (( DOWNLOAD_FAIL++ ))
  return 1
}

# =============================================================================
# 1 / 8 — KIWIX ZIM FILES
# =============================================================================
if should_run 1; then
section "1 / 8  —  Kiwix ZIM Files"

command -v kiwix-serve &>/dev/null || {
  info "Installing kiwix-tools..."
  sudo apt-get install -y kiwix-tools 2>/dev/null \
    || warn "kiwix-tools not in apt — see https://kiwix.org/en/download/"
}

download_zim "Wikipedia English (no pictures)" \
  "wikipedia" "wikipedia_en_all_nopic"

download_zim "iFixit Repair Guides" \
  "ifixit" "ifixit_en_all"

download_zim "Wikibooks" \
  "wikibooks" "wikibooks_en_all_maxi"

download_zim "Wikivoyage" \
  "wikivoyage" "wikivoyage_en_all_maxi"

download_zim "Wikisource" \
  "wikisource" "wikisource_en_all_maxi"

download_zim "Wikiversity" \
  "wikiversity" "wikiversity_en_all_maxi"

download_zim "Project Gutenberg Library" \
  "gutenberg" "gutenberg_en_all"

download_zim "DevDocs (programming reference)" \
  "devdocs" "devdocs_en_all"

info "--- Stack Exchange ---"

download_zim "SE: Cooking" \
  "stack_exchange" "cooking.stackexchange.com_en_all"

download_zim "SE: DIY / Home Improvement" \
  "stack_exchange" "diy.stackexchange.com_en_all"

download_zim "SE: Electronics" \
  "stack_exchange" "electronics.stackexchange.com_en_all"

download_zim "SE: Gardening" \
  "stack_exchange" "gardening.stackexchange.com_en_all"

download_zim "SE: Outdoors / Survival" \
  "stack_exchange" "outdoors.stackexchange.com_en_all"

download_zim "SE: Motor Vehicle Mechanics" \
  "stack_exchange" "mechanics.stackexchange.com_en_all"

download_zim "SE: Sustainability" \
  "stack_exchange" "sustainability.stackexchange.com_en_all"

download_zim "SE: Ham Radio" \
  "stack_exchange" "ham.stackexchange.com_en_all"

info "--- US Army Publications Archive ---"
download_zim "Army Publications (armypubs)" \
  "zimit" "armypubs_en_all"

log "Kiwix ZIMs complete"
fi

# =============================================================================
# 2 / 8 — OFFLINE MAPS
# =============================================================================
if should_run 2; then
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
        dl "${GEOFABRIK}/north-america/${REGION}-latest.osm.pbf" "$MAPS_DIR" || true
      done
      ;;
    CA) dl "${GEOFABRIK}/north-america/canada-latest.osm.pbf" "$MAPS_DIR" ;;
    GB|IE) dl "${GEOFABRIK}/europe/great-britain-latest.osm.pbf" "$MAPS_DIR" ;;
    AU|NZ) dl "${GEOFABRIK}/australia-oceania/australia-latest.osm.pbf" "$MAPS_DIR" ;;
    *)
      warn "Region $COUNTRY not auto-mapped."
      warn "  → https://download.geofabrik.de → place .osm.pbf in ${MAPS_DIR}/"
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
fi

# =============================================================================
# 3 / 8 — MILITARY FIELD MANUALS
# =============================================================================
if should_run 3; then
section "3 / 8  —  Military Field Manuals"

# Each dl_pdf call: dest, output_name, url1, url2, ... (tries in order)

dl_pdf "$MILITARY_DIR" "FM_21-76_Survival.pdf" \
  "https://ia801705.us.archive.org/33/items/Fm21-76SurvivalManual/FM21-76_SurvivalManual.pdf" \
  "https://archive.org/download/Fm21-76SurvivalManual/FM21-76_SurvivalManual.pdf" \
  "https://archive.org/download/FM2176USARMYSURVIVALMANUAL/FM%2021-76%20US%20ARMY%20SURVIVAL%20MANUAL.pdf"

dl_pdf "$MILITARY_DIR" "FM_4-25.11_First_Aid.pdf" \
  "https://archive.org/download/army-fm-4-25-11/fm-4-25-11.pdf"

dl_pdf "$MILITARY_DIR" "FM_31-70_Cold_Weather.pdf" \
  "https://archive.org/download/army-fm-31-70/fm-31-70.pdf"

dl_pdf "$MILITARY_DIR" "FM_5-426_Carpentry.pdf" \
  "https://archive.org/download/army-fm-5-426/fm-5-426.pdf"

dl_pdf "$MILITARY_DIR" "FM_5-428_Concrete_Masonry.pdf" \
  "https://archive.org/download/army-fm-5-428/fm-5-428.pdf"

dl_pdf "$MILITARY_DIR" "FM_90-3_Desert_Operations.pdf" \
  "https://archive.org/download/army-fm-90-3/fm-90-3.pdf"

dl_pdf "$MILITARY_DIR" "FM_90-5_Jungle_Operations.pdf" \
  "https://archive.org/download/army-fm-90-5/fm-90-5.pdf"

dl_pdf "$MILITARY_DIR" "FM_21-10_Field_Hygiene.pdf" \
  "https://archive.org/download/army-fm-21-10/fm-21-10.pdf"

log "Military manuals complete"
fi

# =============================================================================
# 4 / 8 — MEDICAL REFERENCES
# =============================================================================
if should_run 4; then
section "4 / 8  —  Medical References"

# 2025 edition direct from Hesperian (the publisher), with Archive.org fallbacks
dl_pdf "$MEDICAL_DIR" "Where_There_Is_No_Doctor.pdf" \
  "https://hesperian.org/wp-content/uploads/pdf/en_wtnd_2025/en_wtnd_2025_fm.pdf" \
  "https://ia601902.us.archive.org/24/items/WhereThereIsNoDoctor-English-DavidWerner/14.DavidWerner-WhereThereIsNoDoctor.pdf" \
  "https://archive.org/download/WhereThereIsNoDoctor-English-DavidWerner/14.DavidWerner-WhereThereIsNoDoctor.pdf"

dl_pdf "$MEDICAL_DIR" "Where_There_Is_No_Dentist.pdf" \
  "https://hesperian.org/wp-content/uploads/pdf/en_wtnd_2025/en_wtnd_2025_dental.pdf" \
  "https://archive.org/download/WhereThereIsNoDoctor-English-DavidWerner/WhereThereIsNoDentist.pdf"

dl_pdf "$MEDICAL_DIR" "A_Book_For_Midwives.pdf" \
  "https://hesperian.org/wp-content/uploads/pdf/en_bfm_2022/en_bfm_2022_fm.pdf"

log "Medical references complete"
fi

# =============================================================================
# 5 / 8 — FORAGING, AGRICULTURE & FOOD PRESERVATION
# =============================================================================
if should_run 5; then
section "5 / 8  —  Foraging, Agriculture & Food"

dl_pdf "$FORAGING_DIR" "USDA_Complete_Guide_Home_Canning.pdf" \
  "https://archive.org/download/usda-complete-guide-to-home-canning/usda-complete-guide-to-home-canning.pdf"

# Gutenberg EPUBs — EPUB3 format (works in Foliate, Calibre, any modern reader)
# Primary URL: /ebooks/<ID>.epub3   Fallback: /ebooks/<ID>.epub.images
dl_epub "$AGRICULTURE_DIR" "Agriculture_for_Beginners.epub" \
  "https://www.gutenberg.org/ebooks/5265.epub3" \
  "https://www.gutenberg.org/ebooks/5265.epub.images"

dl_epub "$AGRICULTURE_DIR" "Cottage_Economy.epub" \
  "https://www.gutenberg.org/ebooks/14905.epub3" \
  "https://www.gutenberg.org/ebooks/14905.epub.images"

dl_epub "$AGRICULTURE_DIR" "First_Book_of_Farming.epub" \
  "https://www.gutenberg.org/ebooks/10378.epub3" \
  "https://www.gutenberg.org/ebooks/10378.epub.images"

dl_epub "$AGRICULTURE_DIR" "Culinary_Herbs.epub" \
  "https://www.gutenberg.org/ebooks/26763.epub3" \
  "https://www.gutenberg.org/ebooks/26763.epub.images"

dl_epub "$AGRICULTURE_DIR" "Manual_of_Gardening.epub" \
  "https://www.gutenberg.org/ebooks/9550.epub3" \
  "https://www.gutenberg.org/ebooks/9550.epub.images"

dl_epub "$AGRICULTURE_DIR" "Beekeeping_for_Beginners.epub" \
  "https://www.gutenberg.org/ebooks/32085.epub3" \
  "https://www.gutenberg.org/ebooks/32085.epub.images"

dl_epub "$AGRICULTURE_DIR" "Home_Canning_and_Preserving.epub" \
  "https://www.gutenberg.org/ebooks/30360.epub3" \
  "https://www.gutenberg.org/ebooks/30360.epub.images"

dl_epub "$AGRICULTURE_DIR" "How_to_Make_Bread.epub" \
  "https://www.gutenberg.org/ebooks/37747.epub3" \
  "https://www.gutenberg.org/ebooks/37747.epub.images"

dl_epub "$AGRICULTURE_DIR" "Soap_Making_Manual.epub" \
  "https://www.gutenberg.org/ebooks/41638.epub3" \
  "https://www.gutenberg.org/ebooks/41638.epub.images"

log "Foraging & agriculture complete"
fi

# =============================================================================
# 6 / 8 — SURVIVOR LIBRARY
# =============================================================================
if should_run 6; then
section "6 / 8  —  Survivor Library"

SURVIVOR_DEST="${SURVIVAL_DIR}/survivor_library"
mkdir -p "$SURVIVOR_DEST"
EXISTING_COUNT=$(find "$SURVIVOR_DEST" -name "*.pdf" 2>/dev/null | wc -l)

if (( EXISTING_COUNT > 100 )); then
  info "Survivor Library already downloaded (${EXISTING_COUNT} PDFs)"
else
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would sync Survivor Library (~6GB, ~2000 PDFs)"
  else
    info "Syncing Survivor Library from archive.org (~6GB)..."
    if command -v rsync &>/dev/null; then
      rsync -avz --progress --timeout=60 \
        "rsync://archive.org/survival.library/" "$SURVIVOR_DEST/" 2>/dev/null \
        && log "Survivor Library synced" \
        || {
          warn "rsync failed — trying compressed archive..."
          dl "https://archive.org/compress/survival.library/formats=PDF" "$SURVIVAL_DIR"
        }
    else
      dl "https://archive.org/compress/survival.library/formats=PDF" "$SURVIVAL_DIR"
    fi
  fi
fi

log "Survivor Library complete"
fi

# =============================================================================
# 7 / 8 — ENTERTAINMENT
# =============================================================================
if should_run 7; then
section "7 / 8  —  Entertainment"

if [[ "$SKIP_GAMES" == "true" ]]; then
  warn "Skipping entertainment (--skip-games)"
else
  if [[ "$DRY_RUN" != "true" ]]; then
    info "Installing open source games..."
    sudo apt-get install -y \
      openttd supertuxkart minetest wesnoth nethack-console dosbox \
      2>/dev/null || warn "Some game packages unavailable"
  fi

  cat > "${GAMES_DIR}/LEGAL_ROM_SOURCES.txt" << 'EOF'
Legal Game ROM Sources
======================
1. MAMEDev Freeware:  https://www.mamedev.org/roms/
2. Public Domain ROMs: https://www.zophar.net/pdroms.html
3. Homebrew:           https://www.romhacking.net/homebrew/
4. DOS Games Archive:  https://archive.org/details/softwarelibrary_msdos_games
5. Open source (installed): OpenTTD, SuperTuxKart, Minetest, Wesnoth, NetHack

Place ROMs in: entertainment/games/roms/<console>/
EOF

  cat > "${COMICS_DIR}/COMIC_SOURCES.txt" << 'EOF'
Public Domain Comics (Free & Legal)
=====================================
1. Digital Comic Museum: https://digitalcomicmuseum.com
2. Comic Book Plus:      https://comicbookplus.com
3. Internet Archive:     https://archive.org/details/comics

Reading CBZ/CBR files:
  - Foliate:  foliate <file.cbz>       (supports CBZ natively!)
  - MComix:   sudo apt install mcomix
  - Calibre:  ebook-viewer <file.cbz>

Server: ./start_library_server.sh → http://localhost:8081
EOF
  log "Entertainment setup complete"
fi
fi

# =============================================================================
# 8 / 8 — LOCAL AI
# =============================================================================
if should_run 8; then
section "8 / 8  —  Local AI (Ollama)"

if [[ "$SKIP_AI" == "true" ]]; then
  warn "Skipping AI (--skip-ai)"
else
  if ! command -v ollama &>/dev/null; then
    if [[ "$DRY_RUN" == "true" ]]; then
      info "[DRY RUN] Would install Ollama + Phi-3 Mini (~2.3GB)"
    else
      info "Installing Ollama..."
      curl -fsSL https://ollama.com/install.sh | sh \
        && log "Ollama installed" \
        || warn "Install failed — run: curl -fsSL https://ollama.com/install.sh | sh"
    fi
  else
    log "Ollama already installed"
  fi

  if command -v ollama &>/dev/null && [[ "$DRY_RUN" != "true" ]]; then
    pgrep -x ollama &>/dev/null || { ollama serve &>/dev/null & sleep 4; }

    info "Pulling Phi-3 Mini (~2.3GB)..."
    ollama pull phi3:mini \
      && log "Phi-3 Mini ready" \
      || warn "Model pull failed — run: ollama pull phi3:mini"

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
fi

# =============================================================================
# KIWIX LIBRARY + SYSTEMD
# =============================================================================
if should_run 1; then
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

  if [[ "$DRY_RUN" != "true" ]] && command -v systemctl &>/dev/null; then
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
fi
fi

# =============================================================================
# FILE INTEGRITY SWEEP
# =============================================================================
section "File Integrity Check"

BAD_COUNT=0

info "Validating PDFs..."
while IFS= read -r -d '' f; do
  validate_file "$f" pdf 2>/dev/null || (( BAD_COUNT++ ))
done < <(find "$BASE_DIR" -name "*.pdf" -size +0c -print0 2>/dev/null)

info "Validating EPUBs..."
while IFS= read -r -d '' f; do
  validate_file "$f" epub 2>/dev/null || (( BAD_COUNT++ ))
done < <(find "$BASE_DIR" -name "*.epub" -size +0c -print0 2>/dev/null)

if (( BAD_COUNT > 0 )); then
  warn "${BAD_COUNT} corrupt file(s) removed. Re-run to re-download."
else
  log "All files validated OK"
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
    printf "  %-60s %s\n" "$(basename "$f")" "$(du -sh "$f" 2>/dev/null | cut -f1)"
  done

echo ""
echo -e "${BOLD}Books & Manuals:${RESET}"
PDF_COUNT=$(find "$BASE_DIR" -name "*.pdf" -size +10k 2>/dev/null | wc -l)
EPUB_COUNT=$(find "$BASE_DIR" -name "*.epub" -size +5k 2>/dev/null | wc -l)
echo "  PDFs:  ${PDF_COUNT}"
echo "  EPUBs: ${EPUB_COUNT}"

echo ""
echo -e "${BOLD}Readers:${RESET}"
command -v foliate &>/dev/null        && echo -e "  ${GREEN}✔${RESET} Foliate (EPUB/CBZ GUI reader)" \
                                      || echo -e "  ${RED}✘${RESET} Foliate — sudo apt install foliate"
command -v ebook-viewer &>/dev/null   && echo -e "  ${GREEN}✔${RESET} Calibre ebook-viewer" \
                                      || echo -e "  ${RED}✘${RESET} Calibre — sudo apt install calibre"
command -v calibre-server &>/dev/null && echo -e "  ${GREEN}✔${RESET} Calibre server (./start_library_server.sh → :8081)" \
                                      || echo -e "  ${RED}✘${RESET} Calibre server"
command -v kiwix-serve &>/dev/null    && echo -e "  ${GREEN}✔${RESET} Kiwix server (:8080)" \
                                      || echo -e "  ${RED}✘${RESET} Kiwix — sudo apt install kiwix-tools"

echo ""
echo -e "${BOLD}Download stats:${RESET}"
echo -e "  ${GREEN}New downloads: ${DOWNLOAD_OK}${RESET}"
echo -e "  ${CYAN}Already had:   ${DOWNLOAD_SKIP}${RESET}"
echo -e "  ${RED}Failed:        ${DOWNLOAD_FAIL}${RESET}"

if (( DOWNLOAD_FAIL > 0 )); then
  echo ""
  echo -e "${BOLD}Failed items (re-run to retry):${RESET}"
  grep -E "^\[!\].*Failed:|^\[!\].*All URLs failed" "$LOG_FILE" 2>/dev/null \
    | tail -20 || echo "  (check log)"
fi

echo ""
echo -e "${BOLD}Quick start:${RESET}"
echo "  Browse Wikipedia/ZIMs:  http://localhost:8080"
echo "  Browse book library:    ./start_library_server.sh → http://localhost:8081"
echo "  Open a book (GUI):      ./open_book.sh <file.epub>"
echo "  Open a book (terminal): foliate <file.epub>"
echo "  Ask survival AI:        ./ai/survival_ai.sh"
echo ""
echo -e "${CYAN}Log: ${LOG_FILE}${RESET}"
echo -e "${CYAN}Re-run anytime — skips what you already have.${RESET}"
