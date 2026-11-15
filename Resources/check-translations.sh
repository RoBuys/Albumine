#!/bin/zsh
# Lists the interface texts that have no English translation yet.
#   ./Resources/check-translations.sh
# The compiler extracts every localizable text (Text("…"), Button("…"), L("…")…); the French text is
# the key. Add the missing ones to Resources/en.lproj/Localizable.strings ("français" = "English";).
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
touch Sources/Albumine/*.swift
swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null 2>&1
/usr/bin/python3 - "$OUT" Resources/en.lproj/Localizable.strings <<'PY'
import glob, json, plistlib, re, sys
out, strings = sys.argv[1], sys.argv[2]
import subprocess
done = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", strings], capture_output=True, check=True).stdout)
missing = {}
for path in glob.glob(out + "/*.stringsdata"):
    data = json.load(open(path))
    for entries in data.get("tables", {}).values():
        for e in entries:
            k = e["key"]
            if re.search(r"[A-Za-zÀ-ÿ]", k) and k not in done:
                missing.setdefault(k, f'{data["source"].split("/")[-1]}:{e["location"]["startingLine"]}')
for k, where in sorted(missing.items(), key=lambda x: x[1]):
    print(f"{where}\t{k!r}")
print(f"{len(missing)} text(s) without English translation." if missing else "All texts are translated.")
PY
