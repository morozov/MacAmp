#!/usr/bin/env bash
# Generate a per-format document .icns for every file type MacAmp can open.
# Each icon = the base document sheet/bolt (winamp-file.svg) plus a navy "tag"
# that overhangs the sheet's left edge, holding the uppercased extension in
# Arial Black, auto-sized to fit the tag. The rendered .icns files land in
# MacAmpApp/FileIcons/ and are wired to document types via CFBundleTypeIconFile
# in MacAmpApp/Info.plist.
#
# Usage:  bash generate-file-icons.sh            # the full MacAmp format list
#         bash generate-file-icons.sh mp3 flac   # only the given extensions
#
# Requires: librsvg (rsvg-convert), imagemagick (magick), iconutil (built in).
#   brew install librsvg imagemagick
set -euo pipefail
cd "$(dirname "$0")"

BASE="winamp-file.svg"
FONT="/System/Library/Fonts/Supplemental/Arial Black.ttf"
OUTROOT="../../MacAmpApp/FileIcons"
# iconset layers iconutil packs into the .icns (1x plus @2x retina variants).
SIZES=(16 32 128 256 512)

# Every extension MacAmp can open today: decoded audio, AVFoundation video,
# playlists, CUE sheets, skins, and EQ presets. Keep in sync with the
# CFBundleDocumentTypes entries in MacAmpApp/Info.plist.
# .m3u8 is omitted: it shares the system UTI public.m3u-playlist with .m3u, so
# both use the m3u icon (one icon per UTI).
DEFAULT_EXTS=(mp3 m4a aac flac wav aiff mp4 mov m4v avi m3u pls cue wsz eqf)
if [ "$#" -gt 0 ]; then EXTS=("$@"); else EXTS=("${DEFAULT_EXTS[@]}"); fi

# --- tag geometry, in the icon's 48-unit space (matches winamp-file.svg) ---
# The tag overhangs the sheet's left edge (sheet starts at x5) as a protruding tab.
BX=1.2; BY=6.9; BW=27.6; BH=8.7  # tag rect (sharp corners)
PAD=2.5                          # horizontal text padding inside the tag
MAXFS=7.0                        # height-capped font size (fits BH with margin)
CX=$(awk -v a=$BX -v w=$BW 'BEGIN{printf "%.3f", a+w/2}')    # text center x
BCY=$(awk -v a=$BY -v h=$BH 'BEGIN{printf "%.3f", a+h/2}')   # tag center y
CAPR=0.74                                                    # Arial Black cap-height / font-size
AVAILW=$(awk -v w=$BW -v p=$PAD 'BEGIN{printf "%.3f", w-2*p}')

command -v rsvg-convert >/dev/null || { echo "rsvg-convert (librsvg) required" >&2; exit 1; }
command -v magick >/dev/null || { echo "magick (imagemagick) required" >&2; exit 1; }
[ -f "$FONT" ] || { echo "font not found: $FONT" >&2; exit 1; }
[ -f "$BASE" ] || { echo "base svg not found: $BASE" >&2; exit 1; }

mkdir -p "$OUTROOT"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf '%-7s %-6s %s\n' "ext" "fs" "output"
for ext in "${EXTS[@]}"; do
  EXTUP=$(printf '%s' "$ext" | tr '[:lower:]' '[:upper:]')

  # Auto-fit: measure label width at 100pt with the real font, then pick the
  # largest font size that fits both the available width and the height cap.
  w100=$(magick -background none -fill black -font "$FONT" -pointsize 100 \
                label:"$EXTUP" -trim -format '%w' info:)
  fs=$(awk -v avail=$AVAILW -v w=$w100 -v cap=$MAXFS \
         'BEGIN{ fw=avail*100/w; print (fw<cap)?sprintf("%.2f",fw):sprintf("%.2f",cap) }')
  # Baseline that vertically centers the caps in the tag (no dominant-baseline).
  ty=$(awk -v c=$BCY -v r=$CAPR -v f=$fs 'BEGIN{printf "%.3f", c + r*f/2}')

  svg="$work/$ext.svg"

  # Inject the tag (gradient + subtle shadow + rect + text) before </svg>.
  awk -v ext="$EXTUP" -v fs="$fs" -v cx="$CX" -v ty="$ty" \
      -v bx="$BX" -v by="$BY" -v bw="$BW" -v bh="$BH" '
    /<\/svg>/{
      print "  <defs>"
      print "    <linearGradient id=\"tag\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">"
      print "      <stop offset=\"0\" stop-color=\"#2a6cb4\"/>"
      print "      <stop offset=\"1\" stop-color=\"#103a6b\"/>"
      print "    </linearGradient>"
      print "    <filter id=\"dsTag\" x=\"-45%\" y=\"-45%\" width=\"190%\" height=\"190%\">"
      print "      <feDropShadow dx=\"0.25\" dy=\"0.4\" stdDeviation=\"0.4\" flood-color=\"#000000\" flood-opacity=\"0.35\"/>"
      print "    </filter>"
      print "  </defs>"
      printf "  <rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"url(#tag)\" stroke=\"#0c2e54\" stroke-width=\"0.6\" filter=\"url(#dsTag)\"/>\n", bx,by,bw,bh
      printf "  <text x=\"%s\" y=\"%s\" font-family=\"Arial Black\" font-weight=\"normal\" font-size=\"%s\" fill=\"#ffffff\" text-anchor=\"middle\">%s</text>\n", cx,ty,fs,ext
      print "</svg>"; next
    }
    {print}
  ' "$BASE" > "$svg"

  # Rasterize each layer into an .iconset, then pack the .icns.
  iconset="$work/$ext.iconset"; mkdir -p "$iconset"
  for s in "${SIZES[@]}"; do
    rsvg-convert -w "$s"          -h "$s"          "$svg" -o "$iconset/icon_${s}x${s}.png"
    rsvg-convert -w "$((s*2))"    -h "$((s*2))"    "$svg" -o "$iconset/icon_${s}x${s}@2x.png"
  done
  iconutil -c icns "$iconset" -o "$OUTROOT/$ext.icns"

  printf '%-7s %-6s %s\n' "$ext" "$fs" "$OUTROOT/$ext.icns"
done
echo "done: ${#EXTS[@]} extensions -> $OUTROOT/"
