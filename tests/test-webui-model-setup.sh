#!/usr/bin/env bash
# This file is part of OffgridDev
# test-webui-model-setup.sh
# Author(s): OffgridDev contributors
# Created: 2026-11-21
# Summary: Exercises the Bash launcher's optional Open WebUI model setup with local stubs.
# Notes: See README file for documentation and full license information.
#
# Copyright © 2026 The Regents of the University of Michigan
#
# Licensed under the GNU General Public License v3.0 or later.
# See <https://www.gnu.org/licenses/gpl-3.0-standalone.html>.

set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/offgrid-webui.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/project/scripts" "$fixture/project/config"
cp "$root/scripts/offgriddev-start.sh" "$fixture/project/scripts/"
printf '%s\n' 'ENABLE_DEEPSEEK_CODER_1P3B=1' > "$fixture/project/config/models.env"

cat > "$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info|compose|exec) exit 0 ;;
  inspect) printf '%s\n' healthy ;;
  *) exit 64 ;;
esac
EOF

cat > "$fixture/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
endpoint=
output=
payload=
format=
while [ "$#" -gt 0 ]; do
  case "$1" in
    http://localhost:3000/*) endpoint="${1#http://localhost:3000}" ;;
    -o|--output) shift; output="$1" ;;
    -d) shift; payload="$1" ;;
    -w|--write-out) shift; format="$1" ;;
    -X|-H|--connect-timeout|--max-time) shift ;;
    --silent|--fail) ;;
    *) exit 64 ;;
  esac
  shift
done

status=200
body='{}'
case "$endpoint" in
  /api/v1/auths/signin)
    body='{"token":"synthetic-test-token"}'
    ;;
  /api/v1/models/create|/api/v1/models/model/update)
    model="${payload#*:\"}"
    model="${model%%\"*}"
    printf '%s %s\n' "${endpoint##*/}" "$model" >> "$WEBUI_CALLS"
    if [[ "$endpoint" == */create && "$model" == deepseek-coder:small-coding ]]; then
      case "$WEBUI_SCENARIO" in
        duplicate)
          status=401
          body='{ "detail": "Uh-oh! This model id is already registered. Please choose another model id string." }'
          ;;
        legacy-400) status=400 ;;
        legacy-409) status=409 ;;
        unauthorized)
          status=401
          body='{"detail":"Not authenticated"}'
          ;;
        timeout) exit 28 ;;
        unavailable) status=503 ;;
      esac
    fi
    ;;
  *) exit 64 ;;
esac

if [ "$output" != /dev/null ]; then
  printf '%s' "$body"
fi
printf '%b' "${format//'%{http_code}'/$status}"
EOF
chmod +x "$fixture/bin/"*

run_launcher() {
  local scenario="$1"
  : > "$fixture/calls"
  HOME="$fixture/home-$scenario" PATH="$fixture/bin:$PATH" \
    WEBUI_CALLS="$fixture/calls" WEBUI_SCENARIO="$scenario" \
    bash "$fixture/project/scripts/offgriddev-start.sh" \
    > "$fixture/stdout" 2> "$fixture/stderr"
  grep -qx 'OffgridDev READY' "$fixture/stdout"
  grep -q 'model: deepseek-coder:small-coding' "$fixture/home-$scenario/.continue/config.yaml"
}

run_launcher success
grep -qx 'create qwen25vl:medium-vision' "$fixture/calls"
test ! -s "$fixture/stderr"

printf '%s\n' 'create deepseek-coder:small-coding' 'update deepseek-coder:small-coding' \
  'create deepseek-coder:medium-coding' > "$fixture/expected-requests"
for scenario in duplicate legacy-400 legacy-409; do
  run_launcher "$scenario"
  head -n 3 "$fixture/calls" > "$fixture/first-requests"
  diff -u "$fixture/expected-requests" "$fixture/first-requests"
  grep -qx 'create qwen25vl:medium-vision' "$fixture/calls"
  test ! -s "$fixture/stderr"
done

for scenario in unauthorized timeout unavailable; do
  run_launcher "$scenario"
  printf '%s\n' 'create deepseek-coder:small-coding' > "$fixture/expected-requests"
  diff -u "$fixture/expected-requests" "$fixture/calls"
  test "$(grep -c '^WARNING: Could not finish setting up model tool compatibility' "$fixture/stderr")" -eq 1
done

printf '%s\n' 'Open WebUI model setup tests passed.'
