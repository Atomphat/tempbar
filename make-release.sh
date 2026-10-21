#!/bin/zsh
# ออก release ใหม่บน GitHub:  ./make-release.sh 1.1.0
set -e
cd "${0:A:h}"
[[ -n "$1" ]] || { echo "ใช้: ./make-release.sh <version>  เช่น 1.1.0"; exit 1; }
VERSION=$1 ./make-app.sh --universal
(cd build && ditto -c -k --keepParent TempBar.app TempBar.zip)
git tag "v$1"
git push origin "v$1"
gh release create "v$1" build/TempBar.zip --title "TempBar v$1" --generate-notes
