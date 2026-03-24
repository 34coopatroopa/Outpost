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
