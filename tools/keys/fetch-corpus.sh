#!/bin/sh
# Text for the tap simulator and the letter model. Public-domain books from Project Gutenberg and
# MacKenzie & Soukoreff's phrase set. Not stored in the repo. Run from tools/keys.
set -e
mkdir -p ../corpus/phrases
for id in 1342 1661 98 2701 76 11 84; do curl -sL -o ../corpus/pg$id.txt https://www.gutenberg.org/cache/epub/$id/pg$id.txt; done
curl -sL -o ../corpus/PhraseSets.zip https://www.yorku.ca/mack/PhraseSets.zip
python3 -I -c "import zipfile; zipfile.ZipFile('../corpus/PhraseSets.zip').extract('phrases2.txt', '../corpus/phrases')"
