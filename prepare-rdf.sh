echo getting nquads
cd /workspace
curl -s -X GET "https://git.ld.plazi.org/api/v1/repos/plazi/treatments-rdf/releases/latest" | \
jq -r '.assets[0].browser_download_url' | xargs -I {} curl -L {} -o plazi-treatments.nq

curl -L https://github.com/plazi/catologueoflife-to-rdf/releases/download/master/col.nt.gz -O
gunzip col.nt.gz