#!/bin/bash
cd /workspace

echo "---------------"
date

# Checkout treatments-rdf
GIT_OK="F"
if [ -d "treatments-rdf" ]; then
    cd /workspace/treatments-rdf
    if git pull; then
        GIT_OK="T"
    fi
fi

if [ "$GIT_OK" = "F" ]; then
    echo "(re)cloning"
    cd /workspace
    rm -r treatments-rdf
    git clone https://git.ld.plazi.org/plazi/treatments-rdf.git
fi

# Convert, concat, sort data
echo > /workspace/treatments-redundant.nt

cd /workspace/treatments-rdf
for file in $(find . -type f); do
    if [[ $file == *.ttl ]]; then
        # echo "> found $file, adding"
        rapper -q $file --input turtle >> /workspace/treatments-redundant.nt
    fi
done

cd /workspace

sort treatments-redundant.nt | uniq > treatments.nt

## CoL data

wget -N --no-verbose https://github.com/plazi/catologueoflife-to-rdf/releases/download/master/col.nt.gz
rm --force col.nt # --force to remove potentially pre-existing file first
gunzip col.nt.gz

# split into four files col_00.nt to col_03.nt
split -n l/4  col.nt col_ -d --additional-suffix=.nt

# replace all four files
for i in 00 01 02 03; do
  curl -X DELETE -D - -u plazi:aingieci0Eineepee1erae1rioyeeYaiTehesh1xie "https://webdav-test.cluster.ldbar.ch/plazi/input/col_$i.nt"
  curl -X PUT -D - --upload-file "col_$i.nt" -u plazi:aingieci0Eineepee1erae1rioyeeYaiTehesh1xie "https://webdav-test.cluster.ldbar.ch/plazi/input/col_$i.nt"
done

echo "uploaded files"
date