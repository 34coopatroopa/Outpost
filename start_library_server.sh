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
