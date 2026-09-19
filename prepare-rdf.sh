#!/usr/bin/env bash
set -euo pipefail
cd /workspace

echo "getting nquads"
curl -fsS https://hooknq.ld.plazi.org/nquads -o plazi-treatments.nq

echo "getting Catalogue of Life"
# Use the latest release of plazi/catologueoflife-to-rdf. The asset has been
# published as col.nt.gz or col.ttl.gz depending on the release, so select it by
# pattern rather than by position. The content is N-Triples either way, which
# is what the Qleverfile expects as col.nt.
release=$(curl -fsS https://api.github.com/repos/plazi/catologueoflife-to-rdf/releases/latest)
tag=$(jq -r '.tag_name' <<<"$release")
url=$(jq -r '[.assets[] | select(.name | test("^col\\.(nt|ttl)\\.gz$"))][0].browser_download_url // empty' <<<"$release")
if [ -z "$url" ]; then
  echo "No col.nt.gz/col.ttl.gz asset found in release ${tag}" >&2
  exit 1
fi
echo "Catalogue of Life release ${tag}: ${url}"
curl -fsSL "$url" | gunzip -c > col.nt
echo "col.nt: $(wc -l < col.nt) lines"
