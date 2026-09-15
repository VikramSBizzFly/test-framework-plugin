# shellcheck shell=sh
# lib/migrate.sh -- bringing older suites up to date
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# The layouts a suite has had, oldest first. Each converter below turns one
# into the next, so the oldest suite chains through all of them.
V03_SIG='^id,feature,role'                    # 0.1-0.3: one 20-column file
V04_SIG='^id,area,who,'                       # 0.4: 8 visible columns + state
V04_HEADER='id,area,who,what to do,what should happen,priority,status,notes'
V04_STATE_HEADER='id,type,route,tags,source_files,spec_file,last_run,last_result,pass_streak,flake_count,viewport,method,body,headers,expect_code,repeat'

# migrate -- bring a suite from any earlier layout to the current one.
#
# Working suites already exist, so changing the schema without a migration
# would throw away everyone's history. Every step keeps each id, status and
# note, translates the vocabulary, and leaves the file it replaced as .old.
cmd_migrate() {
  need_csv
  _m_did=0
  if head -1 "$CSV" | grep -q "$V03_SIG"; then _tf_migrate_03; _m_did=1; fi
  if head -1 "$CSV" | grep -q "$V04_SIG"; then _tf_migrate_04; _m_did=1; fi
  if [ "$_m_did" = 0 ]; then
    head -1 "$CSV" | tr -d '\r' | grep -qx "$HEADER" ||
      die "migrate: unrecognised header in $CSV -- not a layout this version knows"
    echo "migrate: schema already current"
  fi
  tf_adopt_workbook
}

# 0.1-0.3 -> 0.4. Translates P0 -> high, anonymous -> nobody, verified/stable
# -> passing. Writes the 0.4 layout on purpose; _tf_migrate_04 takes it the rest
# of the way.
_tf_migrate_03() {
  cp "$CSV" "$CSV.old" || die "migrate: could not back up $CSV"
  mkdir -p "$CACHE"
  tmp="$CSV.new.$$"; stmp="$STATE.new.$$"

  awk -v hdr="$V04_HEADER" -v shdr="$V04_STATE_HEADER" -v stf="$stmp" "$AWKLIB"'
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
      R[1] = F[idcol(H)]
      R[2] = F[H["feature"]]
      R[3] = who(F[H["role"]])
      R[4] = F[H["steps"]]
      R[5] = F[H["expected"]]
      R[6] = prio(F[H["priority"]])
      R[7] = stat(F[H["status"]])
      R[8] = F[H["notes"]]
      print csvjoin(R, nh)

      split("", S)
      S[1] = F[idcol(H)];          S[2] = kind(F[H["type"]])
      S[3] = F[H["route"]];       S[4] = F[H["tags"]]
      S[5] = F[H["source_files"]];S[6] = F[H["spec_file"]]
      S[7] = F[H["last_run"]];    S[8] = F[H["last_result"]]
      S[9] = (F[H["pass_streak"]] == "" ? "0" : F[H["pass_streak"]])
      S[10] = (F[H["flake_count"]] == "" ? "0" : F[H["flake_count"]])
      S[11] = F[H["viewport"]]
      for (i = 12; i <= ns; i++) S[i] = ""
      print csvjoin(S, ns) > stf
      moved++
    }
    END { print "migrate: " moved + 0 " cases moved to the 0.4 layout" > "/dev/stderr" }
  ' "$CSV" > "$tmp" || die "migrate: conversion failed; $CSV is unchanged"
  _tf_validate "$tmp" "$V04_HEADER" && _tf_validate "$stmp" "$V04_STATE_HEADER" ||
    { rm -f "$tmp" "$stmp"; die "migrate: the converted files do not parse; $CSV is unchanged"; }
  mv "$tmp" "$CSV" && mv "$stmp" "$STATE"
  echo "migrate: old file kept at $CSV.old"
}

# 0.4 -> 1.0: the QA team's ten columns.
#
#   Test Case ID      <- id
#   Module            <- area
#   Test Scenario     <- the first sentence of `what to do`, at most 80 chars
#   Test Description  <- notes
#   Preconditions     <- who, in words: "Not logged in" / "Logged in as admin"
#   Test Case Steps   <- what to do
#   Expected Result   <- what should happen
#   Status            <- the old status, as a QA word
#
# `who` also becomes state `role` -- the runner still needs to know which
# session to use -- and `priority=high` becomes the `smoke` tag, which is what
# a bare /test-run now falls back to. Priority itself is gone from the sheet.
_tf_migrate_04() {
  # Keep the oldest backup. A 0.3 suite reaches here already converted once, and
  # its .old is the user's real original -- replacing it with the 0.4 midpoint
  # would lose exactly the file they would want back.
  [ -f "$CSV.old" ] || cp "$CSV" "$CSV.old" 2>/dev/null || die "migrate: could not back up $CSV"
  [ -f "$STATE" ] && { [ -f "$STATE.old" ] || cp "$STATE" "$STATE.old" 2>/dev/null; }
  mkdir -p "$CACHE"
  tmp="$CSV.new.$$"; stmp="$STATE.new.$$"
  [ -f "$STATE" ] || printf '%s\n' "$V04_STATE_HEADER" > "$STATE"

  awk -v hdr="$HEADER" -v shdr="$STATE_HEADER" -v stf="$stmp" -v cur="$CSV" "$AWKLIB"'
    function scenario(s,   i) {
      i = index(s, ". "); if (i > 0) s = substr(s, 1, i - 1)
      sub(/\.$/, "", s)
      return (length(s) > 80) ? substr(s, 1, 77) "..." : s
    }
    function pre(w)  { return (w == "" || w == "nobody" || w == "anonymous") ?
                              "Not logged in" : "Logged in as " w }
    function role(w) { return (w == "" || w == "nobody" || w == "anonymous") ? "nobody" :
                              ((w == "normal user") ? "user" : w) }
    function qa(s,   l) {
      l = tolower(s)
      if (l == "" || l == "new")                 return "Not Run"
      if (l == "passing" || l == "pass")         return "Pass"
      if (l == "failing" || l == "fail")         return "Fail"
      if (l == "flaky")                          return "Flaky"
      if (l == "skipped" || l == "skip")         return "Skipped"
      if (l == "error" || l == "blocked")        return "Blocked"
      return s
    }
    BEGIN {
      nh = split(hdr, OUT, ","); ns = split(shdr, SC, ",")
      # Pass 1 -- the visible file, for the values state needs from it.
      c = 0
      while ((getline l < cur) > 0) {
        if (++c == 1) { hdrmap(l, VH); continue }
        if (l == "") continue
        split("", F); csvsplit(l, F); id = F[idcol(VH)]
        WHO[id] = F[VH["who"]]; PRIO[id] = F[VH["priority"]]
        V[id, "Test Case ID"]      = id
        V[id, "Module"]            = F[VH["area"]]
        V[id, "Test Scenario"]     = scenario(F[VH["what to do"]])
        V[id, "Test Description"]  = F[VH["notes"]]
        V[id, "Preconditions"]     = pre(F[VH["who"]])
        V[id, "Test Case Steps"]   = F[VH["what to do"]]
        V[id, "Test Data"]         = ""
        V[id, "Expected Result"]   = F[VH["what should happen"]]
        V[id, "Actual Result"]     = ""
        V[id, "Status"]            = qa(F[VH["status"]])
        ORDER[++norder] = id
      }
      close(cur)
      print hdr
      for (j = 1; j <= norder; j++) {
        id = ORDER[j]
        for (i = 1; i <= nh; i++) R[i] = V[id, OUT[i]]
        print csvjoin(R, nh); moved++
      }
      print shdr > stf
    }
    # Pass 2 -- the old state file, re-laid by column name so a state file from
    # any 0.4 build (with or without the api columns) converts the same way.
    FNR == 1 { hdrmap($0, SH); next }
    $0 == "" { next }
    {
      split("", F); csvsplit($0, F); id = F[idcol(SH)]
      HAS[id] = 1
      for (i = 1; i <= ns; i++) {
        k = SC[i]
        S[i] = (k in SH) ? F[SH[k]] : ""
        if (k == "role") S[i] = role(WHO[id])
        if (k == "tags" && PRIO[id] == "high" && index("," S[i] ",", ",smoke,") == 0)
          S[i] = (S[i] == "" ? "smoke" : S[i] ",smoke")
        if ((k == "pass_streak" || k == "flake_count") && S[i] == "") S[i] = "0"
      }
      print csvjoin(S, ns) > stf
    }
    END {
      # A case with no state row still gets one, or the runner cannot see it.
      for (j = 1; j <= norder; j++) {
        id = ORDER[j]; if (id in HAS) continue
        for (i = 1; i <= ns; i++) {
          k = SC[i]; S[i] = ""
          if (k == "id") S[i] = id
          if (k == "type") S[i] = "page"
          if (k == "role") S[i] = role(WHO[id])
          if (k == "tags" && PRIO[id] == "high") S[i] = "smoke"
          if (k == "pass_streak" || k == "flake_count") S[i] = "0"
        }
        print csvjoin(S, ns) > stf
      }
      print "migrate: " moved + 0 " cases moved to the 1.0 layout" > "/dev/stderr"
    }
  ' "$STATE" > "$tmp" || die "migrate: conversion failed; $CSV is unchanged"

  _tf_validate "$tmp" "$HEADER" && _tf_validate "$stmp" "$STATE_HEADER" ||
    { rm -f "$tmp" "$stmp"; die "migrate: the converted files do not parse; $CSV is unchanged"; }
  mv "$tmp" "$CSV" && mv "$stmp" "$STATE" && _tf_stamp
  echo "migrate: previous files kept as $CSV.old and $STATE.old"
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

  # An older schema. cmd_migrate chains every converter it needs, backs each
  # file up as .old, and adopts the workbook.
  if head -1 "$CSV" 2>/dev/null | grep -q -e "$V03_SIG" -e "$V04_SIG"; then
    echo "tf: this suite uses an older format -- migrating it now" >&2
    cmd_migrate >&2 || true
    return 0
  fi

  # Current schema, old layout: the CSV is still at the top level.
  case "$CSV" in
    "$TESTS_DIR/testcases.csv") tf_adopt_workbook >&2 || true ;;
  esac
  return 0
}
