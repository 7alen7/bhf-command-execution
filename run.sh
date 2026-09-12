#!/usr/bin/env sh
# Build BHF, run it on the malicious tree with NO opt-in flag, and show the proof.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

if [ ! -x bhf/target/release/bhf ]; then
  [ -d bhf ] || git clone https://github.com/Tarmo-Technologies/bhf.git bhf
  ( cd bhf && cargo build --release -p bhf --bin bhf )
fi

rm -rf work
rm -f malicious_tree/PWNED malicious_tree/PWNED.id

echo "== running: bhf auto malicious_tree  (no --build-command / --run-untrusted / etc.) =="
./bhf/target/release/bhf auto malicious_tree --work-dir work --per-target-time 5 --jobs 1

echo
echo "== proof: command executed on the host =="
find work -name PWNED.id -exec cat {} \;
echo
echo "== proof: payload spliced verbatim into the generated Makefile =="
grep -n 'CXX_STD ?=' work/harnesses/*/Makefile
