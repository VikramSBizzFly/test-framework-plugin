# shellcheck shell=sh
# lib/report.sh -- cost projection, results readers and the report
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# cost -- project what a run will spend, by cost tier, before committing to it.
#
# The numbers are deliberately coarse. The point is not an accurate token count,
# it is to make an expensive run visible BEFORE it happens, and to show when a
# generation pass has drifted toward browser cases that a status code could have
# answered.
cmd_cost() {
  need_csv
  budget=0; check=0
  [ "${1:-}" = "--check" ] && check=1
  b="$(json_get "$FRAMEWORK" max_tokens_per_run 2>/dev/null || true)"
  case "$b" in ''|*[!0-9]*) budget=0 ;; *) budget="$b" ;; esac
  joined | awk -v budget="$budget" -v check="$check" "$AWKLIB"'
    function bucket(type, status, spec) {
      if (type == "api")        return "api"
      if (spec != "")           return "spec"
      if (status == "Skipped")  return "skip"
      if (status == "Pass" || status == "Fail" || status == "Flaky") return "replay"
      return "compile"
    }
    NR == 1 { hdrmap($0, H); next }
    {
      csvsplit($0, F)
      b = bucket(F[H["type"]], F[H["Status"]], F[H["spec_file"]])
      N[b]++; total++
      if (b == "compile") { r = F[H["route"]]
        if (r != "" && !(r in ROUTE)) { ROUTE[r] = 1; nroutes++ } }
    }
    END {
      cReplay = 350; cCompile = 300; cRoute = 6000
      tReplay = N["replay"] * cReplay; tCompile = N["compile"] * cCompile
      tRoutes = nroutes * cRoute
      grand = tReplay + tCompile + tRoutes

      printf "%-9s %6s  %-34s %10s\n", "BUCKET", "CASES", "ENGINE", "EST TOKENS"
      printf "%-9s %6d  %-34s %10s\n", "api",    N["api"]+0,    "curl, no browser",              "0"
      printf "%-9s %6d  %-34s %10s\n", "spec",   N["spec"]+0,   "your own test runner, headless","0"
      printf "%-9s %6d  %-34s %10d\n", "replay", N["replay"]+0, "browser, replaying a recipe",   tReplay
      printf "%-9s %6d  %-34s %10d\n", "compile",N["compile"]+0,"browser, first time for this case", tCompile
      printf "%-9s %6d  %-34s %10d\n", "pages",  nroutes+0,     "reading a page, once per page", tRoutes
      if (N["skip"] > 0)
        printf "%-9s %6d  %-34s %10s\n", "skipped", N["skip"], "not run", "0"
      printf "%-9s %6d  %-34s %10d\n", "TOTAL", total+0, "", grand

      free = N["api"] + N["spec"]
      freepct = total > 0 ? int(free * 100 / total) : 0
      printf "\n%d of %d cases (%d%%) cost nothing to re-run.\n", free, total, freepct
      if (N["spec"] == 0 && total > 10)
        printf "None are promoted to real test files yet. Once they are, they\nre-run headless for zero tokens - that is the big saving here.\n"
      if (nroutes > 0)
        printf "%d page(s) to read; each is paid once and reused by every case on it.\n", nroutes

      if (budget > 0) {
        printf "\nbudget %d tokens", budget
        if (grand > budget) {
          printf " -- PROJECTION EXCEEDS IT by %d.\n", grand - budget
          printf "Narrow the run (--changed, --feature) or raise\nmax_tokens_per_run in tests/framework.json.\n"
          if (check) exit 1
        } else printf " -- within budget.\n"
      } else if (check)
        printf "\nno max_tokens_per_run set in tests/framework.json; nothing to check.\n"
    }
  '
}

# ================================================================== reporting

# junit <results.xml> [out.csv] -- JUnit XML -> results CSV.
#
# The Tier 2 fallback. A project whose stack has its own adapter in templates/
# should use that one, since it runs on a runtime the project already has. This
# exists so a project WITHOUT a usable adapter still gets machine-readable
# results instead of the model reading XML.
#
# The case id is recovered from the test name, which codegen stamps there.
cmd_junit() {
  xml="${1:?junit: results.xml required}"
  [ -f "$xml" ] || die "junit: no such file: $xml"
  out="${2:-}"
  { echo 'id,type,role,route,expected,actual,verdict,ms'
    # Normalise to one <testcase> per line first, so the parse stays line-based.
    tr '\n' ' ' < "$xml" |
      sed -e 's#<testcase#\n<testcase#g' -e 's#</testsuite#\n</testsuite#g' |
      awk '
        /^<testcase/ {
          name = ""; if (match($0, /name="[^"]*"/)) name = substr($0, RSTART+6, RLENGTH-7)
          t = 0;     if (match($0, /time="[^"]*"/)) t = substr($0, RSTART+6, RLENGTH-7) + 0

          # id conventions: hyphenated (JS) or underscored (python/java/dotnet)
          id = ""
          if (match(name, /[A-Z][A-Z0-9]*(-[A-Z][A-Z0-9]*)*-[0-9]+/)) id = substr(name, RSTART, RLENGTH)
          else if (match(name, /[A-Z][A-Z0-9]*(_[A-Z][A-Z0-9]*)*__[0-9]+/)) {
            id = substr(name, RSTART, RLENGTH); gsub(/_+/, "-", id)
          }
          if (id == "") next          # not one of ours; skip rather than guess

          verdict = "PASS"; msg = "ok"
          if ($0 ~ /<skipped/) { verdict = "SKIP"; msg = "skipped" }
          else if ($0 ~ /<error/)   { verdict = "ERROR"; msg = "error" }
          else if ($0 ~ /<failure/) { verdict = "FAIL";  msg = "failed" }
          if ((verdict == "FAIL" || verdict == "ERROR") &&
              match($0, /<(failure|error)[^>]*message="[^"]*"/)) {
            m = substr($0, RSTART, RLENGTH)
            if (match(m, /message="[^"]*"/)) msg = substr(m, RSTART+9, RLENGTH-10)
          }
          gsub(/&quot;/, "\"", msg); gsub(/&amp;/, "\\&", msg)
          gsub(/&lt;/, "<", msg);    gsub(/&gt;/, ">", msg)
          if (msg ~ /[",]/) { gsub(/"/, "\"\"", msg); msg = "\"" msg "\"" }

          printf "%s,ui,,,,%s,%s,%d\n", id, msg, verdict, t * 1000
        }'
  } | if [ -n "$out" ]; then cat > "$out"; echo "junit: wrote $out" >&2; else cat; fi
}

# diff <old.csv> <new.csv> -- regressions and fixes only. The model is never
# shown a passing row.
cmd_diff() {
  old="$1"; new="$2"
  [ -f "$old" ] || die "diff: no such file: $old"
  [ -f "$new" ] || die "diff: no such file: $new"
  awk -F, '
    NR == FNR { if (FNR > 1) O[$1] = $7; next }
    FNR == 1 { next }
    {
      if (!($1 in O)) { print "NEW\t" $1 "\t" $7; next }
      if (O[$1] != $7) {
        if ($7 == "PASS") print "FIXED\t" $1 "\t" O[$1] " -> PASS"
        else print "REGRESSED\t" $1 "\t" O[$1] " -> " $7
      }
    }
  ' "$old" "$new" | sort
}

cmd_latest() { ls -1t "$RESULTS"/run-*.csv 2>/dev/null | head -n "${1:-1}"; }

# summary [results.csv] [--json|--quiet] [--ascii] [--color|--no-color]
#
# The end-of-run dashboard. Rendered here, from the results CSV, at zero model
# tokens -- callers print it verbatim rather than describing it again.
#
# Layout note: awk counts bytes, not characters, so every symbol is laid out as
# a one-byte placeholder and substituted for UTF-8 only after padding is
# computed. Colour codes are zero-width and excluded from the length.
cmd_summary() {
  res=""; want_json=0; quiet=0; ascii="${TF_ASCII:-0}"; color=auto
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) want_json=1; shift ;;
      --quiet) quiet=1; shift ;;
      --ascii) ascii=1; shift ;;
      --color) color=always; shift ;;
      --no-color) color=never; shift ;;
      *) res="$1"; shift ;;
    esac
  done
  [ -n "$res" ] || res="$(cmd_latest 1)"
  [ -n "$res" ] && [ -f "$res" ] || { echo "summary: no results yet -- run /test-run first" >&2; return 3; }

  # Diff against the previous run only when summarising the newest one.
  prev=""
  [ "$res" = "$(cmd_latest 1)" ] && prev="$(ls -1t "$RESULTS"/run-*.csv 2>/dev/null | sed -n '2p')"
  meta="${res%.csv}.meta"; [ -f "$meta" ] || meta=/dev/null

  usecolor=0
  case "$color" in
    always) usecolor=1 ;;
    auto) if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then usecolor=1; fi ;;
  esac

  width="${COLUMNS:-}"
  [ -n "$width" ] || width="$(tput cols 2>/dev/null || echo 72)"
  case "$width" in ''|*[!0-9]*) width=72 ;; esac
  [ "$width" -gt 78 ] && width=78
  [ "$width" -lt 34 ] && width=34

  # Pass rate of the last 10 runs, oldest first, for the sparkline.
  trend=""
  for f in $(ls -1t "$RESULTS"/run-*.csv 2>/dev/null | head -10 |
             awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'); do
    trend="$trend$(awk -F, 'NR>1{t++; if($7=="PASS")p++} END{printf "%d", (t?int(p*100/t):0)}' "$f"),"
  done

  # Placeholder bytes, chosen so none can occur in a route, id or status code:
  #   01 TL  02 TR  03 hbar  04 side  05 BL  06 BR
  #   07 check  08 cross  0B circle  0C warn  0E bolt  0F arrow
  #   10-15 sparkline levels   16 bar-full  17 bar-empty
  #   18 reset  19 green  1A red  1C yellow  1D dim  1E bold  1F cyan
  awk -F, -v prev="$prev" -v metaf="$meta" -v W="$width" -v JSON="$want_json" \
      -v QUIET="$quiet" -v TREND="$trend" -v RESF="$res" -v PROJ="$(basename "$(pwd)")" '
  function vlen(s,   i, n, c) {
    n = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\030" || c == "\031" || c == "\032" || c == "\034" ||
          c == "\035" || c == "\036" || c == "\037") continue
      n++
    }
    return n
  }
  function pad(s, w,   d) { d = w - vlen(s); return d > 0 ? s sprintf("%" d "s", "") : s }
  function rep(c, n,   i, s) { s = ""; for (i = 0; i < n; i++) s = s c; return s }
  # Clip to a visible width, keeping zero-width colour markers so nothing leaks.
  function trunc(s, w,   i, n, c, out) {
    if (vlen(s) <= w) return s
    n = 0; out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\030" || c == "\031" || c == "\032" || c == "\034" ||
          c == "\035" || c == "\036" || c == "\037") { out = out c; continue }
      if (n >= w - 1) break
      out = out c; n++
    }
    return out "\030"
  }
  function row(s) { LINES[++NL] = "\004" pad(trunc(s, INNER), INNER) "\004" }
  function sect(s) { LINES[++NL] = s }

  BEGIN { INNER = W - 2; split(TREND, TR, ",") }

  # results columns: id,type,role,route,expected,actual,verdict,ms
  NR > 1 && NF >= 7 {
    id = $1; type = $2; role = $3; route = $4; actual = $6; verdict = $7
    # Not a verdict on the app: listed apart, and left out of the pass rate.
    if (verdict == "UNJUDGED") {
      NUNJ++; if (NUNJ <= 5) UNJ[NUNJ] = sprintf("%-15s %-28s %s", id, route, $5)
      next
    }
    total++; V[verdict]++; TT[type]++
    if (verdict == "PASS") { TP[type]++; PASSED[id] = 1 }
    else {
      FAILN++
      if (!FIRSTFAIL) FIRSTFAIL = id
      # A case whose id says AUTH/PERM asserts that someone should be kept out.
      # Failing it means they are not being kept out -- which outranks every
      # broken button, so it is pinned above the ordinary failures.
      if (id ~ /^(AUTH|PERM)-/) {
        NSEC++; SECID[NSEC] = id
        SEC[NSEC] = sprintf("%-15s %-11s \017 %-20s", id, \
                            (role == "" ? "nobody" : role), route)
        SECC[NSEC] = actual
      } else {
        NOTH++; OTHID[NOTH] = id
        OTH[NOTH] = sprintf("%-15s %-32s", id, route)
        OTHC[NOTH] = actual
      }
    }
    if (type == "api") FREE++
    dur += $8 + 0
    next
  }

  END {
    while ((getline l < metaf) > 0) {
      if (index(l, "=") == 0) continue
      META[substr(l, 1, index(l, "=") - 1)] = substr(l, index(l, "=") + 1)
    }
    if (META["duration_ms"] != "") dur = META["duration_ms"]
    skipped = META["skipped"] + 0
    nosession = META["nosession"]
    unver = META["unverified"] + 0

    if (prev != "") {
      while ((getline l < prev) > 0) { if (++pc == 1) continue
        split(l, P, ","); PREVV[P[1]] = P[7] }
    }

    pct = total > 0 ? int(V["PASS"] * 100 / total) : 0

    if (JSON) {
      printf "{\"run\":\"%s\",\"total\":%d,\"pass\":%d,\"fail\":%d,\"error\":%d,\"skipped\":%d,", \
             RESF, total, V["PASS"]+0, V["FAIL"]+0, V["ERROR"]+0, skipped
      printf "\"pass_rate\":%d,\"security_failures\":%d,\"free_cases\":%d,\"duration_ms\":%d,", \
             pct, NSEC+0, FREE+0, dur
      printf "\"unverified_cases\":%d,\"unverified_roles\":\"%s\",\"unjudged\":%d}\n", unver, nosession, NUNJ+0
      exit
    }
    if (QUIET) {
      printf "%s %d/%d cases (%d%%)%s\n", \
             (NSEC > 0 ? "SECURITY" : (FAILN > 0 ? "FAIL" : "PASS")), \
             V["PASS"]+0, total, pct, \
             (NSEC > 0 ? sprintf(" - %d privilege boundary crossed", NSEC) : "")
      exit
    }

    # ---------------------------------------------------------------- panel
    compact = (INNER < 56)
    hdr = "\003 TEST RUN \003\003 " PROJ " "
    stamp = (META["time"] != "") ? "\003 " META["time"] " " : ""
    d = INNER - vlen(hdr) - vlen(stamp)
    if (d < 1) { stamp = ""; d = INNER - vlen(hdr); if (d < 1) d = 1 }
    LINES[++NL] = "\001" hdr rep("\003", d) stamp "\002"

    if (!compact) row("")

    barw = compact ? 10 : 20
    filled = int(pct * barw / 100)
    bar = rep("\026", filled) rep("\027", barw - filled)
    ratecol = (NSEC > 0) ? "\032" : (pct == 100 ? "\031" : "\034")
    row(sprintf("  \036%d cases\030   %s  %s%d%%\030   \035%.1fs\030", \
        total, bar, ratecol, pct, dur / 1000))
    if (!compact) row("")

    if (compact)
      row(sprintf("  \031\007%d\030 \032\010%d\030 \034!%d\030 \035\013%d\030", \
          V["PASS"]+0, V["FAIL"]+0, V["ERROR"]+0, skipped))
    else
      row(sprintf("  \031\007 pass %-4d\030 \032\010 fail %-4d\030 \034! error %-3d\030 \035\013 skip %-3d\030", \
          V["PASS"]+0, V["FAIL"]+0, V["ERROR"]+0, skipped))
    if (!compact) row("")

    tl = "  "
    for (t in TT) tl = tl sprintf("%s %d/%d    ", t, TP[t]+0, TT[t])
    if (length(tl) > 2 && !compact) row(tl)

    if (FREE > 0) {
      if (compact) row(sprintf("  \034\016\030 \035%d/%d free\030", FREE, total))
      else row(sprintf("  \034\016\030 \035%d of %d ran free (curl); the rest used a browser\030", FREE, total))
    }

    ntr = 0
    for (i = 1; (i in TR) && TR[i] != ""; i++) ntr = i
    if (ntr >= 2 && !compact) {
      sp = ""
      for (i = 1; i <= ntr; i++) {
        lvl = int(TR[i] * 5 / 100); if (lvl > 5) lvl = 5
        sp = sp sprintf("%c", 16 + lvl)
      }
      row(sprintf("  \035trend\030  %s  \035%d%%\030", sp, TR[ntr]))
    }

    LINES[++NL] = "\005" rep("\003", INNER) "\006"

    # ------------------------------------------------------------- sections
    if (NSEC > 0) {
      sect("")
      sect("  \032\036\014  SECURITY - privilege boundary crossed\030")
      for (i = 1; i <= NSEC && i <= 8; i++)
        sect(sprintf("     \032%s\030 \035%s%s\030", SEC[i], SECC[i], \
             ((SECID[i] in PREVV) && PREVV[SECID[i]] == "PASS" ? "  (new since last run)" : "")))
      if (NSEC > 8) sect(sprintf("     \035... and %d more\030", NSEC - 8))
    }

    nreg = 0
    for (i = 1; i <= NOTH; i++)
      if ((OTHID[i] in PREVV) && PREVV[OTHID[i]] == "PASS") { nreg++; REG[nreg] = i }
    for (i = 1; i <= NSEC; i++)
      if ((SECID[i] in PREVV) && PREVV[SECID[i]] == "PASS") nsecreg++

    if (nreg > 0) {
      sect("")
      n = split(prev, PP, "/")
      sect(sprintf("  \034\036REGRESSED\030 \035since %s\030", PP[n]))
      for (i = 1; i <= nreg && i <= 8; i++)
        sect(sprintf("     \034%s\030  \035%s\030", OTH[REG[i]], OTHC[REG[i]]))
    }

    shown = 0
    for (i = 1; i <= NOTH; i++) {
      if ((OTHID[i] in PREVV) && PREVV[OTHID[i]] == "PASS") continue
      if (shown == 0) { sect(""); sect("  \036FAILED\030") }
      if (shown < 8) sect(sprintf("     \032%s\030  \035%s\030", OTH[i], OTHC[i]))
      shown++
    }
    if (shown > 8) sect(sprintf("     \035... and %d more\030", shown - 8))

    nfix = 0
    for (id in PREVV) if (PREVV[id] != "PASS" && (id in PASSED)) { nfix++; FIX[nfix] = id }
    if (nfix > 0) {
      sect(""); sect("  \031\036FIXED\030")
      line = "     \031"
      for (i = 1; i <= nfix && i <= 10; i++) line = line FIX[i] "  "
      sect(line "\030")
    }

    # ---- false-green guards: silence here would read as coverage
    warned = 0
    if (nosession != "") {
      sect(""); warned = 1
      sect(sprintf("  \034\014  %d case%s ran with no session for [%s]\030", unver, (unver==1?"":"s"), nosession))
      sect("     \035logged-out requests are denied anyway, so these verdicts are\030")
      sect("     \035unverified, not passed - run /test-setup to fix\030")
    }
    if (NUNJ > 0) {
      if (!warned) sect(""); warned = 1
      sect(sprintf("  \034\014  %d api case%s could not be judged\030 \035(not counted as failures)\030", \
           NUNJ, (NUNJ == 1 ? "" : "s")))
      for (i = 1; i <= NUNJ && i <= 5; i++) sect(sprintf("     \035%s\030", UNJ[i]))
      if (NUNJ > 5) sect(sprintf("     \035... and %d more\030", NUNJ - 5))
      sect("     \035give each a method and an expect_code: tf.sh set <id> method=POST expect_code=2xx\030")
    }
    if (skipped > 0) {
      if (!warned) sect("")
      sect(sprintf("  \034\014  %d destructive case%s skipped\030 \035(--allow-destructive to run)\030", \
           skipped, (skipped == 1 ? "" : "s")))
    }

    # ---- exactly one next action, chosen by outcome
    sect("")
    sect(sprintf("  \035\017 %s\030", RESF))
    if (NSEC > 0)          nxt = "/test-report --bug " SECID[1]
    else if (nosession != "") nxt = "/test-setup"
    else if (nreg > 0)     nxt = "/test-run --only-failing"
    else if (FAILN > 0)    nxt = "/test-report"
    else                   nxt = "/test-report --publish"
    sect(sprintf("  \037\017 %s\030", nxt))

    for (i = 1; i <= NL; i++) print LINES[i]
  }
  ' "$res" | _tf_render "$ascii" "$usecolor"

  # Open bugs are not a verdict on this run, so they sit under the panel rather
  # than inside it -- and never change the exit status. Panel only: --quiet is
  # promised as one line, and --json is parsed by CI, where a stray line of text
  # would break the job rather than inform it.
  [ "$want_json" = 0 ] && [ "$quiet" = 0 ] && _bug_summary_lines

  # Exit status, for CI gating. Recomputed rather than smuggled through the pipe.
  awk -F, 'NR>1 && NF>=7 && $7 != "UNJUDGED" {
             if ($7 != "PASS") { f++; if ($2 == "rbac" || $2 == "auth") s++ }
           }
           END { exit (s > 0 ? 2 : (f > 0 ? 1 : 0)) }' "$res"
}

# Substitute layout placeholders for real glyphs and colour. Split from the awk
# so that stays about layout and this stays about presentation.
_tf_render() {
  _a="$1"; _c="$2"
  if [ "$_a" = "1" ]; then
    sed -e 's/\x01/+/g' -e 's/\x02/+/g' -e 's/\x03/-/g' -e 's/\x04/|/g' \
        -e 's/\x05/+/g' -e 's/\x06/+/g' \
        -e 's/\x07/+/g' -e 's/\x08/x/g' -e 's/\x0b/o/g' -e 's/\x0c/!/g' \
        -e 's/\x0e/*/g' -e 's/\x0f/>/g' \
        -e 's/\x16/#/g'  -e 's/\x17/./g' \
        -e 's/\x10/_/g;s/\x11/./g;s/\x12/-/g;s/\x13/+/g;s/\x14/*/g;s/\x15/#/g'
  else
    sed -e 's/\x01/╭/g' -e 's/\x02/╮/g' -e 's/\x03/─/g' -e 's/\x04/│/g' \
        -e 's/\x05/╰/g' -e 's/\x06/╯/g' \
        -e 's/\x07/✓/g' -e 's/\x08/✗/g' -e 's/\x0b/○/g' -e 's/\x0c/⚠/g' \
        -e 's/\x0e/⚡/g' -e 's/\x0f/→/g' \
        -e 's/\x16/█/g' -e 's/\x17/░/g' \
        -e 's/\x10/▁/g;s/\x11/▃/g;s/\x12/▄/g;s/\x13/▅/g;s/\x14/▆/g;s/\x15/█/g'
  fi | if [ "$_c" = "1" ]; then
    sed -e 's/\x18/\x1b[0m/g'  -e 's/\x19/\x1b[32m/g' -e 's/\x1a/\x1b[31m/g' \
        -e 's/\x1c/\x1b[33m/g' -e 's/\x1d/\x1b[2m/g'  -e 's/\x1e/\x1b[1m/g' \
        -e 's/\x1f/\x1b[36m/g'
  else
    sed -e 's/\x18//g' -e 's/\x19//g' -e 's/\x1a//g' -e 's/\x1c//g' \
        -e 's/\x1d//g' -e 's/\x1e//g' -e 's/\x1f//g'
  fi
}

cmd_render() {
  res="${1:-$(cmd_latest 1)}"
  [ -n "$res" ] && [ -f "$res" ] || die "render: no results file"
  out="${2:-$RESULTS/report.html}"
  awk -F, -v title="$(basename "$res")" '
    NR == 1 { next }
    { total++; v[$7]++; if ($7 != "PASS") { rows = rows sprintf("<tr class=f><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>", $1, $2, $4, $6, $7) } }
    END {
      printf "<!doctype html><meta charset=utf-8><title>Test results %s</title>", title
      printf "<style>body{font:14px system-ui;margin:2rem;max-width:60rem}h1{font-size:1.3rem}"
      printf ".s{display:flex;gap:1rem;margin:1rem 0}.s div{padding:.6rem 1rem;border-radius:.4rem;background:#f2f2f2}"
      printf ".p{background:#e6f6e9}.f{background:#fdecea}table{border-collapse:collapse;width:100%%}"
      printf "td,th{border-bottom:1px solid #ddd;padding:.4rem .6rem;text-align:left;font-size:13px}</style>"
      printf "<h1>Test results <small>%s</small></h1><div class=s>", title
      printf "<div class=p>PASS %d</div>", v["PASS"] + 0
      printf "<div class=f>FAIL %d</div>", v["FAIL"] + 0
      printf "<div>ERROR %d</div><div>total %d</div></div>", v["ERROR"] + 0, total
      if (rows == "") printf "<p>All %d cases passed.</p>", total
      else printf "<table><tr><th>id<th>type<th>route<th>actual<th>verdict</tr>%s</table>", rows
    }
  ' "$res" > "$out"
  echo "$out"
}

# version -- print the plugin version.
#
# The version lives in exactly one place, .claude-plugin/plugin.json. Resolve it
# from this script's own location, so it works whether tf.sh was invoked through
# $CLAUDE_PLUGIN_ROOT, by an absolute path, or from a checkout. Unknown is an
# answer; failing is not -- this exists to make a bug report answerable.
cmd_version() {
  root="${CLAUDE_PLUGIN_ROOT:-}"
  [ -n "$root" ] || root="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
  v="$(json_get "$root/.claude-plugin/plugin.json" version 2>/dev/null)"
  [ -n "$v" ] || v=unknown
  echo "tf.sh $v"
}
