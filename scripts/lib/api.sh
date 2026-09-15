# shellcheck shell=sh
# lib/api.sh -- run-api: type=api cases over curl
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# run-api -- execute `type=api` cases with curl.
#
# Only headless endpoints belong here. Anything that renders a page is a
# browser case now, because a permission check has to be judged by what the
# user actually sees: an "Access denied" body served with HTTP 200 passes a
# status-code check and is exactly the bug worth catching.
cmd_run_api() {
  need_csv
  assert_target_allowed
  have curl || die "run-api: curl not found"
  base="$(json_get "$CREDS" base_url)"
  mkdir -p "$RESULTS"
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$RESULTS/run-$ts.csv"
  echo 'id,type,role,route,expected,actual,verdict,ms' > "$out"

  allow_destructive=0
  [ "${1:-}" = "--allow-destructive" ] && allow_destructive=1

  # Tab-separated so the CSV parser, not cut, does the field splitting.
  work="$CACHE/.http.$$"; mkdir -p "$CACHE"
  cmd_select --type api --cols id,type,who,route,tags,status \
    --format plain 2>/dev/null > "$work"

  # Which roles have no session? Cases for those roles are logged-out requests,
  # so a "denied" verdict proves nothing -- they are unverified, not passed.
  # Reporting them as green is the worst failure mode this tool has.
  nosession=""; unverified=0
  for r in $(awk -F"$(printf '\t')" '{print $3}' "$work" | sort -u); do
    case "$r" in ""|anonymous|nobody) continue ;; esac
    [ -f "$TESTS_DIR/.auth/$r.cookies" ] && continue
    nosession="$nosession${nosession:+,}$r"
    unverified=$((unverified + $(awk -F"$(printf '\t')" -v r="$r" '$3==r{n++} END{print n+0}' "$work")))
  done

  run_t0=$(date +%s%N 2>/dev/null || echo 0)
  _tf_progress_init "$(grep -c . "$work" 2>/dev/null || echo 0)"
  skip=0
  while IFS="$(printf '\t')" read -r id typ role route tags status; do
    [ -n "${id:-}" ] || continue
    [ "$status" = "skipped" ] && { skip=$((skip + 1)); _tf_progress_tick SKIP "$typ" "$id"; continue; }
    case "$tags" in
      *destructive*) [ "$allow_destructive" = "1" ] || \
        { skip=$((skip + 1)); _tf_progress_tick SKIP "$typ" "$id"; continue; } ;;
    esac
    [ -n "$route" ] || { _tf_progress_tick SKIP "$typ" "$id"; continue; }

    jar=""
    if [ -n "$role" ] && [ "$role" != "anonymous" ] && [ "$role" != "nobody" ]; then
      [ -f "$TESTS_DIR/.auth/$role.cookies" ] && jar="-b $TESTS_DIR/.auth/$role.cookies"
    fi

    t0=$(date +%s%N 2>/dev/null || echo 0)
    # shellcheck disable=SC2086
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -L --max-redirs 0 \
             $jar "$base$route" 2>/dev/null); [ -n "$code" ] || code=000
    t1=$(date +%s%N 2>/dev/null || echo 0)
    ms=$(( (t1 - t0) / 1000000 ))
    [ "$ms" -lt 0 ] && ms=0

    # `refused` cases assert a denial, so the pass/fail sense is inverted:
    # a 200 on an endpoint that should reject you is the bug being hunted.
    case "$tags" in
      *refused*)
        case "$code" in
          401|403|302|303|307|404) verdict=PASS ;;
          000)                     verdict=ERROR ;;
          2*)                      verdict=FAIL ;;
          *)                       verdict=PASS ;;
        esac ;;
      *)
        case "$code" in
          2*)  verdict=PASS ;;
          000) verdict=ERROR ;;
          *)   verdict=FAIL ;;
        esac ;;
    esac

    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$id" "$typ" "$role" "$route" "denied-or-2xx" "$code" "$verdict" "$ms" >> "$out"

    _tf_progress_tick "$verdict" "$typ" "$id"
  done < "$work"
  _tf_progress_done
  rm -f "$work"

  # Fold verdicts back into the state columns in a single pass. Per-row `set`
  # would rewrite the whole file once per case.
  now="$(date +%Y-%m-%dT%H:%M:%S)"
  awk -F, -v now="$now" 'NR > 1 {
    print $1 " status=" ($7 == "PASS" ? "passing" : "failing") \
          " last_result=" $7 " last_run=" now
  }' "$out" | cmd_setmany

  run_t1=$(date +%s%N 2>/dev/null || echo 0)
  {
    echo "time=$(date +%H:%M:%S)"
    echo "duration_ms=$(( (run_t1 - run_t0) / 1000000 ))"
    echo "skipped=$skip"
    echo "nosession=$nosession"
    echo "unverified=$unverified"
  } > "${out%.csv}.meta"

  cmd_summary "$out"
}
