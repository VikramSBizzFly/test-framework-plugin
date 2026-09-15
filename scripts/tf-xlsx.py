#!/usr/bin/env python
"""tf-xlsx.py -- the Excel side of the test framework.

tests/testcases.xlsx is where flows, test cases and their statuses live. This
script is the only thing that reads or writes it. The engine (tf.sh) works on a
CSV cache in tests/.cache/, because awk cannot read a ZIP of XML.

Standard library only -- zipfile plus hand-written OOXML. No openpyxl, no pip,
nothing added to the user's project. If this file needs a dependency, it is
wrong.

  export        cases.csv + flows.txt + results.csv  ->  workbook
  import        workbook  ->  human CSV + a CSV of rows that are new
  status        write verdicts back into the workbook, and roll flows up
  bugs-export   bugs.csv  ->  bug-report.xlsx
  bugs-import   bug-report.xlsx  ->  bugs.csv, keeping what people own

Exit 0 on success, 1 on a real error. Callers treat a missing interpreter as
"skip", never as failure.
"""

import csv
import os
import re
import sys
import zipfile
import datetime
import xml.etree.ElementTree as ET

NS_MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
NS_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS_PKG_REL = "http://schemas.openxmlformats.org/package/2006/relationships"

# The Test Cases sheet is exactly these columns, in this order: the QA team's
# layout. Each has a short key, which is what the engine's joined CSV uses.
CASE_FIELDS = [
    ("Test Case ID", "id"), ("Module", "module"), ("Test Scenario", "scenario"),
    ("Test Description", "description"), ("Preconditions", "preconditions"),
    ("Test Case Steps", "steps"), ("Test Data", "data"),
    ("Expected Result", "expected"), ("Actual Result", "actual"),
    ("Status", "status"),
]
CASE_COLS = [label for label, _k in CASE_FIELDS]

# A workbook written before 1.0 used these headers. Reading them keeps a
# person's edits in an old sheet instead of mistaking every row for a new case.
LEGACY_CASE_LABELS = {
    "id": "Test Case ID", "area": "Module", "what to do": "Test Case Steps",
    "what should happen": "Expected Result", "status": "Status",
    "notes": "Test Description",
}

FLOW_COLS = ["id", "name", "actor", "trigger", "steps", "code path", "writes",
             "branches", "cases", "status", "last run"]
RESULT_COLS = ["run", "id", "type", "role", "route", "expected", "actual",
               "verdict", "ms"]

STATUS_VALUES = "Not Run,Pass,Fail,Blocked,Flaky,Skipped"
# Engine words from before 1.0, and verdicts, onto the QA words.
STATUS_WORDS = {
    "new": "Not Run", "not run": "Not Run", "": "Not Run",
    "passing": "Pass", "pass": "Pass",
    "failing": "Fail", "fail": "Fail",
    "blocked": "Blocked", "error": "Blocked", "unjudged": "Blocked",
    "flaky": "Flaky", "skipped": "Skipped", "skip": "Skipped",
}

BUG_COLS = ["Bug No", "Module", "Bug Description", "Steps to Reproduce",
            "Expected Result", "Actual Result", "Test data", "Status(QA)",
            "QA Comments", "Severity", "Priority", "Reporter", "Environment",
            "Access Link", "Bug Link", "found date", "Dev Comment"]
# bugs.csv carries one more, hidden column: the case a bug was raised from.
BUG_STORE_COLS = BUG_COLS + ["case_id"]
# What a person owns in the bug sheet. Everything else is regenerated from the
# failing case, so a stale copy in the spreadsheet cannot overwrite it.
BUG_PEOPLE_OWN = ["Status(QA)", "QA Comments", "Severity", "Priority",
                  "Bug Link", "Dev Comment"]
BUG_STATUS_VALUES = "Open,In Progress,Fixed,Retest,Reopened,Closed,Not a Bug"
SEVERITY_VALUES = "Critical,High,Medium,Low"
PRIORITY_VALUES = "High,Medium,Low"

SHEET_CASES = "Test Cases"
SHEET_FLOWS = "Flows"
SHEET_RESULTS = "Results"
SHEET_BUGS = "Bugs"

# Style indices into cellXfs below. Keep in sync with _styles_xml().
S_DEFAULT, S_HEADER, S_WRAP, S_PASS, S_FAIL, S_FLAKY, S_SKIP, S_MUTED = range(8)

STATUS_STYLE = {
    "passing": S_PASS, "pass": S_PASS,
    "failing": S_FAIL, "fail": S_FAIL, "error": S_FAIL,
    "blocked": S_FLAKY, "flaky": S_FLAKY,
    "skipped": S_SKIP, "skip": S_SKIP,
    "not covered": S_SKIP,
}
BUG_STATUS_STYLE = {
    "open": S_FAIL, "reopened": S_FAIL,
    "in progress": S_FLAKY, "retest": S_FLAKY,
    "fixed": S_PASS, "closed": S_PASS,
    "not a bug": S_SKIP,
}
SEVERITY_STYLE = {"critical": S_FAIL, "high": S_FAIL, "medium": S_FLAKY,
                  "low": S_SKIP}

# Columns wide enough to read without dragging, and wrapped where the text is
# a sentence rather than a token.
WIDTHS = {
    "Test Case ID": 16, "Module": 14, "Test Scenario": 34,
    "Test Description": 40, "Preconditions": 28, "Test Case Steps": 50,
    "Test Data": 24, "Expected Result": 40, "Actual Result": 40, "Status": 11,
    "Bug No": 10, "Bug Description": 44, "Steps to Reproduce": 50,
    "Test data": 24, "Status(QA)": 12, "QA Comments": 36, "Severity": 10,
    "Priority": 9, "Reporter": 16, "Environment": 26, "Access Link": 34,
    "Bug Link": 34, "found date": 12, "Dev Comment": 36,
    "id": 16, "status": 11,
    "name": 22, "actor": 13, "trigger": 22, "steps": 46, "code path": 42,
    "writes": 24, "branches": 34, "cases": 26, "last run": 17,
    "run": 17, "type": 8, "role": 13, "route": 22, "expected": 26,
    "actual": 26, "verdict": 10, "ms": 7,
}
WRAPPED = {"Test Scenario", "Test Description", "Preconditions",
           "Test Case Steps", "Test Data", "Expected Result", "Actual Result",
           "Bug Description", "Steps to Reproduce", "Test data", "QA Comments",
           "Environment", "Dev Comment",
           "steps", "code path", "branches", "writes", "expected", "actual"}


# ---------------------------------------------------------------- XML helpers

_ILLEGAL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def esc(text):
    text = _ILLEGAL.sub("", str(text if text is not None else ""))
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                .replace('"', "&quot;"))


def col_letter(n):
    """1 -> A, 27 -> AA."""
    out = ""
    while n > 0:
        n, rem = divmod(n - 1, 26)
        out = chr(65 + rem) + out
    return out


# ---------------------------------------------------------------- the writer

def _cell(ref, value, style):
    if value is None or value == "":
        return '<c r="%s" s="%d"/>' % (ref, style)
    return ('<c r="%s" s="%d" t="inlineStr"><is><t xml:space="preserve">%s</t>'
            '</is></c>' % (ref, style, esc(value)))


def _sheet_xml(columns, rows, styled=None, validations=()):
    """styled: {column: {lowercased value: style}} for colour-coded columns."""
    styled = styled or {}
    ncols = len(columns)
    nrows = len(rows) + 1
    last = "%s%d" % (col_letter(ncols), max(nrows, 1))

    cols_xml = []
    for i, name in enumerate(columns, 1):
        width = WIDTHS.get(name, 18)
        cols_xml.append('<col min="%d" max="%d" width="%d" customWidth="1"/>'
                        % (i, i, width))

    body = ['<row r="1" spans="1:%d">' % ncols]
    for i, name in enumerate(columns, 1):
        body.append(_cell("%s1" % col_letter(i), name, S_HEADER))
    body.append("</row>")

    for r, row in enumerate(rows, 2):
        body.append('<row r="%d" spans="1:%d">' % (r, ncols))
        for i, name in enumerate(columns, 1):
            value = row.get(name, "")
            if name in styled:
                style = styled[name].get(str(value).strip().lower(), S_DEFAULT)
            elif name in WRAPPED:
                style = S_WRAP
            else:
                style = S_DEFAULT
            body.append(_cell("%s%d" % (col_letter(i), r), value, style))
        body.append("</row>")

    dv = ""
    if validations:
        parts = []
        for col_name, values in validations:
            if col_name not in columns:
                continue
            letter = col_letter(columns.index(col_name) + 1)
            parts.append(
                '<dataValidation type="list" allowBlank="1" showInputMessage="1"'
                ' showErrorMessage="0" sqref="%s2:%s%d">'
                '<formula1>"%s"</formula1></dataValidation>'
                % (letter, letter, max(nrows, 2) + 200, values))
        if parts:
            dv = '<dataValidations count="%d">%s</dataValidations>' % (
                len(parts), "".join(parts))

    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<worksheet xmlns="%s" xmlns:r="%s">'
        '<dimension ref="A1:%s"/>'
        '<sheetViews><sheetView workbookViewId="0">'
        '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
        '</sheetView></sheetViews>'
        '<sheetFormatPr defaultRowHeight="15"/>'
        '<cols>%s</cols>'
        '<sheetData>%s</sheetData>'
        '<autoFilter ref="A1:%s"/>'
        '%s'
        '</worksheet>' % (NS_MAIN, NS_REL, last, "".join(cols_xml),
                          "".join(body), last, dv))


def _styles_xml():
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<styleSheet xmlns="%s">'
        '<fonts count="3">'
        '<font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>'
        '<font><sz val="10"/><color rgb="FF808080"/><name val="Calibri"/></font>'
        '</fonts>'
        '<fills count="7">'
        '<fill><patternFill patternType="none"/></fill>'
        '<fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FF2F4858"/>'
        '<bgColor indexed="64"/></patternFill></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFD7F0D7"/>'
        '<bgColor indexed="64"/></patternFill></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFF8D0D0"/>'
        '<bgColor indexed="64"/></patternFill></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFFCEBC0"/>'
        '<bgColor indexed="64"/></patternFill></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFECECEC"/>'
        '<bgColor indexed="64"/></patternFill></fill>'
        '</fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="8">'
        '<xf xfId="0" numFmtId="0" fontId="0" fillId="0" borderId="0"/>'
        '<xf xfId="0" numFmtId="0" fontId="1" fillId="2" borderId="0" applyFont="1"'
        ' applyFill="1" applyAlignment="1"><alignment vertical="center"/></xf>'
        '<xf xfId="0" numFmtId="0" fontId="0" fillId="0" borderId="0" applyAlignment="1">'
        '<alignment wrapText="1" vertical="top"/></xf>'
        '<xf xfId="0" numFmtId="0" fontId="0" fillId="3" borderId="0" applyFill="1"/>'
        '<xf xfId="0" numFmtId="0" fontId="0" fillId="4" borderId="0" applyFill="1"/>'
        '<xf xfId="0" numFmtId="0" fontId="0" fillId="5" borderId="0" applyFill="1"/>'
        '<xf xfId="0" numFmtId="0" fontId="0" fillId="6" borderId="0" applyFill="1"/>'
        '<xf xfId="0" numFmtId="0" fontId="2" fillId="0" borderId="0" applyFont="1"/>'
        '</cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        '</styleSheet>' % NS_MAIN)


def write_workbook(path, sheets):
    """sheets: list of (name, columns, rows, styled, validations)."""
    names = [s[0] for s in sheets]

    content_types = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>']
    for i in range(1, len(sheets) + 1):
        content_types.append(
            '<Override PartName="/xl/worksheets/sheet%d.xml" ContentType='
            '"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' % i)
    content_types.append("</Types>")

    sheets_xml = "".join(
        '<sheet name="%s" sheetId="%d" r:id="rId%d"/>' % (esc(n), i, i)
        for i, n in enumerate(names, 1))
    workbook = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<workbook xmlns="%s" xmlns:r="%s"><sheets>%s</sheets></workbook>'
        % (NS_MAIN, NS_REL, sheets_xml))

    rels = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="%s">' % NS_PKG_REL]
    for i in range(1, len(sheets) + 1):
        rels.append('<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org'
                    '/officeDocument/2006/relationships/worksheet" '
                    'Target="worksheets/sheet%d.xml"/>' % (i, i))
    rels.append('<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org'
                '/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
                % (len(sheets) + 1))
    rels.append("</Relationships>")

    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="%s"><Relationship Id="rId1" Type='
        '"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"'
        ' Target="xl/workbook.xml"/></Relationships>' % NS_PKG_REL)

    tmp = path + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", "".join(content_types))
        z.writestr("_rels/.rels", root_rels)
        z.writestr("xl/workbook.xml", workbook)
        z.writestr("xl/_rels/workbook.xml.rels", "".join(rels))
        z.writestr("xl/styles.xml", _styles_xml())
        for i, (_n, cols, rows, styled, validations) in enumerate(sheets, 1):
            z.writestr("xl/worksheets/sheet%d.xml" % i,
                       _sheet_xml(cols, rows, styled, validations))
    os.replace(tmp, path)


# ---------------------------------------------------------------- the reader

def read_workbook(path):
    """-> {sheet name: [ {column: value}, ... ]}, reading row 1 as the header.

    Handles both inline strings (what we write) and shared strings (what Excel
    rewrites the file with the moment a person saves it).
    """
    out = {}
    if not os.path.exists(path):
        return out
    with zipfile.ZipFile(path) as z:
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            root = ET.fromstring(z.read("xl/sharedStrings.xml"))
            for si in root.findall("{%s}si" % NS_MAIN):
                shared.append("".join(t.text or "" for t in
                                      si.iter("{%s}t" % NS_MAIN)))

        wb = ET.fromstring(z.read("xl/workbook.xml"))
        rel_root = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
        targets = {r.get("Id"): r.get("Target")
                   for r in rel_root.findall("{%s}Relationship" % NS_PKG_REL)}

        for sheet in wb.iter("{%s}sheet" % NS_MAIN):
            name = sheet.get("name")
            rid = sheet.get("{%s}id" % NS_REL)
            target = targets.get(rid, "")
            part = "xl/" + target.lstrip("/").replace("xl/", "", 1)
            if part not in z.namelist():
                continue
            out[name] = _read_sheet(ET.fromstring(z.read(part)), shared)
    return out


def _read_sheet(root, shared):
    grid = []
    for row in root.iter("{%s}row" % NS_MAIN):
        cells = {}
        for c in row.findall("{%s}c" % NS_MAIN):
            ref = c.get("r") or ""
            letters = "".join(ch for ch in ref if ch.isalpha())
            idx = 0
            for ch in letters:
                idx = idx * 26 + (ord(ch) - 64)
            ctype = c.get("t")
            if ctype == "inlineStr":
                is_el = c.find("{%s}is" % NS_MAIN)
                value = "".join(t.text or "" for t in is_el.iter("{%s}t" % NS_MAIN)) if is_el is not None else ""
            elif ctype == "s":
                v = c.find("{%s}v" % NS_MAIN)
                try:
                    value = shared[int(v.text)] if v is not None else ""
                except (ValueError, IndexError):
                    value = ""
            else:
                v = c.find("{%s}v" % NS_MAIN)
                value = v.text if v is not None and v.text else ""
            cells[idx] = value
        grid.append(cells)

    if not grid:
        return []
    header = grid[0]
    ncols = max(header) if header else 0
    names = [header.get(i, "") for i in range(1, ncols + 1)]
    rows = []
    for cells in grid[1:]:
        row = {}
        empty = True
        for i, name in enumerate(names, 1):
            if not name:
                continue
            value = (cells.get(i) or "").strip()
            row[name] = value
            if value:
                empty = False
        if not empty:
            rows.append(row)
    return rows


# ---------------------------------------------------------------- data in/out

def read_csv(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8", newline="") as fh:
        return [dict(r) for r in csv.DictReader(fh)]


def read_flows(path):
    """flows.txt -- one flow per line, TAB between fields:

        id <TAB> name <TAB> actor <TAB> trigger <TAB> steps <TAB> code path
           <TAB> writes <TAB> branches <TAB> cases

    Tab, not pipe: `steps` and `code path` are themselves pipe- and
    arrow-separated lists, so a pipe field separator would split them.
    """
    rows = []
    if not path or not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            parts += [""] * (9 - len(parts))
            rows.append(dict(zip(
                ["id", "name", "actor", "trigger", "steps", "code path",
                 "writes", "branches", "cases"], parts[:9])))
    return rows


def qa_status(value):
    return STATUS_WORDS.get((value or "").strip().lower(), (value or "").strip())


def field(row, label, key):
    """A case value, whether the engine's CSV names the column by its visible
    label (1.0) or by its short key."""
    value = row.get(label)
    if value is None:
        value = row.get(key, "")
    return value or ""


def case_rows(cases):
    """Map a joined CSV row (short keys) onto the sheet's columns. The run
    details ride along under keys the sheet does not show."""
    rows = []
    for c in cases:
        row = {label: field(c, label, key) for label, key in CASE_FIELDS}
        row["Status"] = qa_status(row["Status"])
        row["_id"] = field(c, "Test Case ID", "id")
        row["_last_run"] = c.get("last_run", "")
        rows.append(row)
    return rows


def roll_up(flow, by_id):
    """A flow is only as good as the cases covering it."""
    ids = [i.strip() for i in re.split(r"[,\s]+", flow.get("cases", "")) if i.strip()]
    ids = [i for i in ids if i in by_id]
    if not ids:
        return "not covered"
    states = [qa_status(by_id[i].get("Status")) for i in ids]
    if "Fail" in states:
        return "failing"
    if "Flaky" in states:
        return "flaky"
    if all(s == "Pass" for s in states):
        return "passing"
    if all(s == "Skipped" for s in states):
        return "skipped"
    if all(s == "Not Run" for s in states):
        return "not run"
    return "partial"


def build_sheets(cases, flows, results, prev_flows=None):
    crows = case_rows(cases)
    by_id = {r["_id"]: r for r in crows if r.get("_id")}

    frows = []
    prev = {f.get("id"): f for f in (prev_flows or [])}
    for f in flows:
        row = dict(f)
        row["status"] = roll_up(f, by_id)
        row["last run"] = ""
        for i in re.split(r"[,\s]+", f.get("cases", "")):
            i = i.strip()
            if i in by_id and by_id[i].get("_last_run"):
                row["last run"] = max(row["last run"], by_id[i]["_last_run"])
        if not row["last run"] and f.get("id") in prev:
            row["last run"] = prev[f["id"]].get("last run", "")
        frows.append(row)

    rrows = []
    for r in results:
        rrows.append({
            "run": r.get("run", ""), "id": r.get("id", ""),
            "type": r.get("type", ""), "role": r.get("role", ""),
            "route": r.get("route", ""), "expected": r.get("expected", ""),
            "actual": r.get("actual", ""), "verdict": r.get("verdict", ""),
            "ms": r.get("ms", ""),
        })

    return [
        (SHEET_FLOWS, FLOW_COLS, frows, {"status": STATUS_STYLE}, ()),
        (SHEET_CASES, CASE_COLS, crows, {"Status": STATUS_STYLE},
         (("Status", STATUS_VALUES),)),
        (SHEET_RESULTS, RESULT_COLS, rrows, {"verdict": STATUS_STYLE}, ()),
    ]


def same_content(path, sheets):
    """True when the workbook already says exactly this.

    An unchanged verdict must not rewrite the file -- a run that changed nothing
    should leave the spreadsheet untouched, so a diff shows only what moved.
    """
    existing = read_workbook(path)
    if not existing:
        return False
    for name, cols, rows, _s, _v in sheets:
        old = existing.get(name)
        if old is None or len(old) != len(rows):
            return False
        for o, n in zip(old, rows):
            for col in cols:
                if (o.get(col, "") or "") != (str(n.get(col, "") or "")):
                    return False
    return True


# ---------------------------------------------------------------- subcommands

def arg(name, default=None):
    flag = "--" + name
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def cmd_export():
    xlsx = arg("xlsx")
    cases = read_csv(arg("cases"))
    flows = read_flows(arg("flows"))
    results = read_csv(arg("results"))
    prev = read_workbook(xlsx).get(SHEET_FLOWS, []) if os.path.exists(xlsx) else []
    sheets = build_sheets(cases, flows, results, prev)
    if same_content(xlsx, sheets):
        print("xlsx: no change")
        return 0
    write_workbook(xlsx, sheets)
    print("xlsx: %s (%d cases, %d flows, %d results)"
          % (xlsx, len(cases), len(flows), len(results)))
    return 0


def one_line(value):
    """A cell as one line. The engine reads the CSV a line at a time, so a line
    break typed into a cell (Alt+Enter) would split the record in two. Steps are
    already pipe-separated by convention, so a break becomes one."""
    lines = (value or "").splitlines()
    return " | ".join(p.strip() for p in lines if p.strip())


def clean_case(row):
    out = {c: one_line(row.get(c)) for c in CASE_COLS}
    out["Status"] = qa_status(out["Status"])
    return out


def legacy_case_row(row):
    """A row from a pre-1.0 sheet, under the current labels."""
    if "Test Case ID" in row or "id" not in row:
        return row
    out = {new: row.get(old, "") for old, new in LEGACY_CASE_LABELS.items()}
    who = (row.get("who") or "").strip()
    if who:
        out["Preconditions"] = ("Not logged in" if who in ("nobody", "anonymous")
                                else "Logged in as %s" % who)
    return out


def write_csv(path, columns, rows):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=columns, lineterminator="\n",
                           extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def cmd_import():
    """Workbook -> the human CSV the engine reads, plus the rows that are new.

    Hand edits win: whatever the sheet says for a human column is the value.
    Reference columns are generated, so a stale copy in a spreadsheet is
    ignored. A row deleted from the sheet is reported, never deleted here.
    """
    xlsx = arg("xlsx")
    out_human = arg("out-human")
    out_new = arg("out-new")
    # The engine's joined CSV uses short keys; re-key it by the sheet labels.
    known = {}
    for c in read_csv(arg("cases")):
        cid = field(c, "Test Case ID", "id")
        if cid:
            known[cid] = {label: field(c, label, key) for label, key in CASE_FIELDS}

    sheet = [legacy_case_row(r) for r in read_workbook(xlsx).get(SHEET_CASES, [])]
    if not sheet:
        print("xlsx: nothing to import", file=sys.stderr)
        return 0

    rows, new_rows, seen = [], [], set()
    prefix_max = {}
    for cid in known:
        m = re.match(r"^([A-Z][A-Z0-9-]*?)-(\d+)$", cid)
        if m:
            prefix_max[m.group(1)] = max(prefix_max.get(m.group(1), 0),
                                         int(m.group(2)))

    for row in sheet:
        cid = (row.get("Test Case ID") or "").strip()
        if not cid:
            area = (row.get("Module") or "new").strip().upper()
            prefix = re.sub(r"[^A-Z0-9]", "", area)[:4] or "CASE"
            prefix_max[prefix] = prefix_max.get(prefix, 0) + 1
            cid = "%s-%03d" % (prefix, prefix_max[prefix])
            row = dict(row)
            row["Test Case ID"] = cid
            new_rows.append(row)
        elif cid not in known:
            new_rows.append(row)
        seen.add(cid)
        rows.append(clean_case(row))

    # A row deleted from the sheet stays in the suite, as promised above. The
    # engine also refuses an import that would shrink the store.
    missing = [i for i in known if i not in seen]
    for cid in missing:
        rows.append(clean_case(known[cid]))

    write_csv(out_human, CASE_COLS, rows)
    write_csv(out_new, CASE_COLS, [clean_case(r) for r in new_rows])

    print("xlsx: imported %d cases (%d new)" % (len(rows), len(new_rows)))
    if missing:
        print("xlsx: %d case(s) are in the suite but not in the sheet, kept: %s"
              % (len(missing), ", ".join(sorted(missing)[:8])), file=sys.stderr)
    return 0


def cmd_status():
    """Write verdicts back in after a run, and roll the flows up."""
    xlsx = arg("xlsx")
    cases = read_csv(arg("cases"))
    results = read_csv(arg("results"))
    flows = read_flows(arg("flows"))
    if not flows:
        flows = [{k: f.get(k, "") for k in
                  ["id", "name", "actor", "trigger", "steps", "code path",
                   "writes", "branches", "cases"]}
                 for f in read_workbook(xlsx).get(SHEET_FLOWS, [])]

    prev = read_workbook(xlsx).get(SHEET_FLOWS, [])
    sheets = build_sheets(cases, flows, results, prev)
    if same_content(xlsx, sheets):
        print("xlsx: no verdict changed")
        return 0
    write_workbook(xlsx, sheets)
    changed = sum(1 for r in results if r.get("verdict"))
    print("xlsx: updated %s (%d verdicts)" % (xlsx, changed))
    return 0


# ---------------------------------------------------------------- bug report

def bug_sheet(bugs):
    """The one sheet of tests/bug-report.xlsx. case_id stays in the store."""
    rows = [{c: one_line(b.get(c)) for c in BUG_COLS} for b in bugs]
    return [(SHEET_BUGS, BUG_COLS, rows,
             {"Status(QA)": BUG_STATUS_STYLE, "Severity": SEVERITY_STYLE},
             (("Status(QA)", BUG_STATUS_VALUES), ("Severity", SEVERITY_VALUES),
              ("Priority", PRIORITY_VALUES)))]


def cmd_bugs_export():
    xlsx = arg("xlsx")
    bugs = read_csv(arg("bugs"))
    sheets = bug_sheet(bugs)
    if same_content(xlsx, sheets):
        print("xlsx: bug report unchanged")
        return 0
    write_workbook(xlsx, sheets)
    open_n = sum(1 for b in bugs
                 if (b.get("Status(QA)") or "") not in ("Closed", "Not a Bug", "Fixed"))
    print("xlsx: %s (%d bugs, %d open)" % (xlsx, len(bugs), open_n))
    return 0


def cmd_bugs_import():
    """bug-report.xlsx -> bugs.csv.

    A person owns six columns: Status(QA), QA Comments, Severity, Priority,
    Bug Link and Dev Comment. Those come from the sheet. Everything else was
    filled from the failing case and is kept from the store, so a stale copy in
    a spreadsheet cannot overwrite it. A row typed into the sheet with no Bug No
    is a bug a person raised by hand: it gets the next number and every column.
    """
    xlsx = arg("xlsx")
    out = arg("out")
    store = read_csv(arg("bugs"))
    by_no = {b.get("Bug No"): b for b in store if b.get("Bug No")}

    sheet = read_workbook(xlsx).get(SHEET_BUGS, [])
    if not sheet:
        print("xlsx: no bug report to import", file=sys.stderr)
        write_csv(out, BUG_STORE_COLS, store)
        return 0

    top = 0
    for no in by_no:
        m = re.match(r"^BUG-(\d+)$", no or "")
        if m:
            top = max(top, int(m.group(1)))

    merged, seen, added = [], set(), 0
    for row in sheet:
        no = (row.get("Bug No") or "").strip()
        if no and no in by_no:
            b = dict(by_no[no])
            for col in BUG_PEOPLE_OWN:
                if col in row:
                    b[col] = one_line(row.get(col))
            merged.append(b)
            seen.add(no)
        elif not no:
            if not any((row.get(c) or "").strip() for c in BUG_COLS):
                continue
            top += 1
            b = {c: one_line(row.get(c)) for c in BUG_COLS}
            b["Bug No"] = "BUG-%03d" % top
            b["Status(QA)"] = b.get("Status(QA)") or "Open"
            b["found date"] = b.get("found date") or datetime.date.today().isoformat()
            b["case_id"] = ""
            merged.append(b)
            added += 1
        else:
            print("xlsx: %s is in the sheet but not the store -- ignored" % no,
                  file=sys.stderr)

    # A bug deleted from the sheet stays: deleting a bug report by deleting a
    # spreadsheet row is not something to do silently.
    kept = [b for no, b in by_no.items() if no not in seen]
    merged.extend(kept)

    write_csv(out, BUG_STORE_COLS, merged)
    print("xlsx: imported %d bugs (%d new by hand)" % (len(merged), added))
    if kept:
        print("xlsx: %d bug(s) missing from the sheet were kept" % len(kept),
              file=sys.stderr)
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1
    try:
        return {"export": cmd_export, "import": cmd_import,
                "status": cmd_status, "bugs-export": cmd_bugs_export,
                "bugs-import": cmd_bugs_import}[sys.argv[1]]()
    except KeyError:
        print("tf-xlsx: unknown subcommand %r" % sys.argv[1], file=sys.stderr)
        return 1
    except Exception as exc:                      # noqa: BLE001
        print("tf-xlsx: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
