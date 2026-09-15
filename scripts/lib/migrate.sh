# shellcheck shell=sh
# lib/migrate.sh -- bringing older suites up to date
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# migrate -- convert an old 20-column testcases.csv into the new pair.
#
# Working suites already exist, so changing the schema without a migration
# would throw away everyone's history. Translates the vocabulary too: P0 ->
# high, anonymous -> nobody, verified/stable -> passing.
cmd_migrate() {
  need_csv
  # The schema may already be current while the *layout* is not -- a suite from
  # before the workbook existed. Adopting it is still a migration.
  head -1 "$CSV" | grep -q '^id,area,who' && {
    echo "migrate: schema already current"
    tf_adopt_workbook
    return 0
  }
  head -1 "$CSV" | grep -q '^id,feature,role' || die "migrate: unrecognised header; expected the old 20-column format"

  cp "$CSV" "$CSV.old" || die "migrate: could not back up $CSV"
  mkdir -p "$CACHE"
  tmp="$CSV.new.$$"; stmp="$STATE.new.$$"

  awk -v hdr="$HEADER" -v shdr="$STATE_HEADER" -v stf="$stmp" "$AWKLIB"'
    function who(r)   { return (r == "anonymous" || r == "") ? "nobody" :
                               ((r == "user") ? "normal user" : r) }
    function prio(p)  { return (p == "P0") ? "high" : ((p == "P1") ? "medium" :
                               ((p == "P2") ? "low" : (p == "" ? "medium" : p))) }
    function stat(s)  { return (s == "verified" || s == "stable") ? "passing" :
                               ((s == "new" || s == "") ? "new" : s) }
    function kind(t)  { return (t == "api") ? "api" : "page" }
    BEGIN { nh = split(hdr, OUT, ","); ns = split(shdr, SC, ",")
            print hdr; print shdr > stf }
    NR == 1 { hdrmap($0, H); next }
    {
      n = csvsplit($0, F)
      R[1] = F[H["id"]]
      R[2] = F[H["feature"]]
      R[3] = who(F[H["role"]])
      R[4] = F[H["steps"]]
      R[5] = F[H["expected"]]
      R[6] = prio(F[H["priority"]])
      R[7] = stat(F[H["status"]])
      R[8] = F[H["notes"]]
      print csvjoin(R, nh)

      S[1] = F[H["id"]];          S[2] = kind(F[H["type"]])
      S[3] = F[H["route"]];       S[4] = F[H["tags"]]
      S[5] = F[H["source_files"]];S[6] = F[H["spec_file"]]
      S[7] = F[H["last_run"]];    S[8] = F[H["last_result"]]
      S[9] = (F[H["pass_streak"]] == "" ? "0" : F[H["pass_streak"]])
      S[10] = (F[H["flake_count"]] == "" ? "0" : F[H["flake_count"]])
      S[11] = F[H["viewport"]]
      print csvjoin(S, ns) > stf
      moved++
    }
    END { print "migrate: " moved + 0 " cases moved" > "/dev/stderr" }
  ' "$CSV" > "$tmp" && mv "$tmp" "$CSV" && mv "$stmp" "$STATE"
  echo "migrate: old file kept at $CSV.old"
  tf_adopt_workbook
}

# Move a pre-workbook suite to the new layout: the xlsx becomes the store and
# the CSV moves out of sight into .cache/. Only on an explicit `migrate` -- a
# file a person has been opening for months should not relocate itself as a side
# effect of some other command.
tf_adopt_workbook() {
  [ -f "$TESTS_DIR/testcases.csv" ] || return 0
  tf_python >/dev/null 2>&1 || {
    echo "migrate: no python here, so the suite stays at $TESTS_DIR/testcases.csv" >&2
    return 0
  }
  mkdir -p "$CACHE"
  mv "$TESTS_DIR/testcases.csv" "$CACHE/testcases.csv" || return 0
  CSV="$CACHE/testcases.csv"
  cmd_xlsx || true
  echo "migrate: the store is now $XLSX; the engine's CSV moved to $CSV"
}

# cache-check <srcdir> -- is the discovery cache still valid?
#
# Exit 0 means unchanged, so /test-run can reuse the cached feature map and
# page models for free. Exit 1 means the source moved and they must be rebuilt.
# This was previously only an instruction in a skill, which meant a model that
# skipped the instruction silently re-paid full price.
cmd_cache_check() {
  src="${1:-.}"
  mkdir -p "$CACHE"
  now="$(cmd_hash "$src")"
  old=""
  [ -f "$CACHE/hash" ] && old="$(cat "$CACHE/hash" 2>/dev/null)"
  if [ -n "$old" ] && [ "$old" = "$now" ]; then
    echo "cache: valid ($now) -- reuse .cache/, regeneration is free"
    return 0
  fi
  printf '%s\n' "$now" > "$CACHE/hash"
  if [ -z "$old" ]; then echo "cache: cold ($now) -- first run, nothing cached yet"
  else echo "cache: stale ($old -> $now) -- source changed, rebuild what it affects"; fi
  return 1
}

# tf_auto_migrate -- bring an older suite up to date without being asked.
#
# Two things can be out of date: the schema (the old 20-column testcases.csv)
# and the layout (a top-level CSV from before the workbook existed). Both are
# handled here, once, before the subcommand runs, so nobody has to know that
# `migrate` exists. Safe on a current suite: it reads one header line and
# returns. Set TF_NO_AUTO_MIGRATE=1 to hold a suite exactly where it is.
tf_auto_migrate() {
  [ "${TF_NO_AUTO_MIGRATE:-}" = "1" ] && return 0
  [ -f "$CSV" ] || return 0

  # Old schema. cmd_migrate backs up to .old, converts, and adopts the workbook.
  if head -1 "$CSV" 2>/dev/null | grep -q '^id,feature,role'; then
    echo "tf: this suite uses the old format -- migrating it now" >&2
    cmd_migrate >&2 || true
    return 0
  fi

  # Current schema, old layout: the CSV is still at the top level.
  case "$CSV" in
    "$TESTS_DIR/testcases.csv") tf_adopt_workbook >&2 || true ;;
  esac
  return 0
}
