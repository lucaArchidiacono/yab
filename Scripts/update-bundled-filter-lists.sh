#!/bin/sh
# Refreshes the filter lists shipped inside the app. The app keeps them up to date
# on its own afterwards; fresher bundled copies just mean less to download.
#
# Usage: Scripts/update-bundled-filter-lists.sh
set -eu

destination="$(dirname "$0")/../yab/Resources/FilterLists"

download() {
    name="$1"
    url="$2"
    temporary="$(mktemp)"
    curl --fail --silent --show-error --location "$url" --output "$temporary"
    mv "$temporary" "$destination/$name.txt"
    echo "Updated $name.txt ($(wc -c < "$destination/$name.txt" | tr -d ' ') bytes)"
}

download easylist https://easylist.to/easylist/easylist.txt
download easyprivacy https://easylist.to/easylist/easyprivacy.txt
download ublock-filters https://ublockorigin.github.io/uAssetsCDN/filters/filters.min.txt
download ublock-badware https://ublockorigin.github.io/uAssetsCDN/filters/badware.min.txt
download ublock-privacy https://ublockorigin.github.io/uAssetsCDN/filters/privacy.min.txt
download ublock-quick-fixes https://ublockorigin.github.io/uAssetsCDN/filters/quick-fixes.min.txt
download ublock-unbreak https://ublockorigin.github.io/uAssetsCDN/filters/unbreak.min.txt
download malicious-sites https://curbengh.github.io/malware-filter/urlhaus-filter-domains-online.txt
