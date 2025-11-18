echo getting nquads
cd /workspace
curl -fs https://hooknq.ld.plazi.org/nquads -o plazi-treatments.nq

echo getting col.nt
url=$(curl -fs https://api.github.com/repos/plazi/catologueoflife-to-rdf/releases/latest | jq -r '.assets[0].browser_download_url')
wget "$url"
gunzip col.nt.gz