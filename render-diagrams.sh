#!/bin/sh
# Re-exports every diagrams/*.mmd as a PNG next to it, with the Mermaid CLI in Docker.
#   ./render-diagrams.sh                      all of them
#   ./render-diagrams.sh 05-high-availability  one example
set -eu
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
dir=$(pwd -W 2>/dev/null || pwd)
docker run --rm -v "$dir:/data" --entrypoint sh minlag/mermaid-cli:11.4.2 -c '
  cd /data
  for f in ${1:-*}/diagrams/*.mmd; do
    echo "$f"
    /home/mermaidcli/node_modules/.bin/mmdc -p /puppeteer-config.json -c mermaid-config.json -b white -s 2 -w 1600 \
      -i "$f" -o "${f%.mmd}.png" >/dev/null
  done' sh "${1:-}"
