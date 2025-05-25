echo getting nquads
cd /workspace
curl -s -X GET "https://git.ld.plazi.org/api/v1/repos/plazi/treatments-rdf/releases/latest" | \
jq -r '.assets[0].browser_download_url' | xargs -I {} curl -L {} -o plazi-treatments.nq

echo getting col.nt
url=$(curl -s https://api.github.com/repos/plazi/catologueoflife-to-rdf/releases/latest | jq -r '.assets[0].browser_download_url')
wget "$url"
gunzip col.nt.gz