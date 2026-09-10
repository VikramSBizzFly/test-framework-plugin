// Converts the JUnit-style XML `dotnet test` emits (via
// --logger "junit;LogFilePath=...") into the framework's results CSV:
// id,type,role,route,expected,actual,verdict,ms
//
// Standard library only (System.Xml.Linq, System.Text.RegularExpressions) --
// no extra package reference.
//
// Usage: dotnet run --project JunitToCsv.cs -- <junit.xml> <out.csv>
// (or compile as a top-level program: `dotnet JunitToCsv.cs <in> <out>`)
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

if (args.Length != 2)
{
    Console.Error.WriteLine("usage: JunitToCsv <junit.xml> <out.csv>");
    return 1;
}

// skills/test-codegen/references/dotnet.md's naming convention: a case id
// like INV-014 is encoded in the method name as INV_014 (hyphen ->
// underscore, since a hyphen is not a legal C# identifier).
// Multi-segment prefixes are real: `tf.sh rbac` emits RBAC-USER-002,
// which codegen writes as the method name RBAC_USER_002_...
var idRe = new Regex(@"([A-Z][A-Z0-9]*(?:_[A-Z][A-Z0-9]*)*)_(\d+)");

var doc = XDocument.Load(args[0]);
// NUnit/`dotnet test` JUnit writers use <testcase name="..."> just like the
// other stacks' runners; some nest it as <testsuite><testcase>, others also
// wrap in <testsuites> -- Descendants() is agnostic to either shape.
var cases = doc.Descendants("testcase");

var csv = new StringBuilder("id,type,role,route,expected,actual,verdict,ms\n");
int written = 0;

foreach (var testcase in cases)
{
    var name = (string?)testcase.Attribute("name") ?? "";
    var m = idRe.Match(name);
    if (!m.Success) continue; // not one of ours

    var id = $"{m.Groups[1].Value.Replace('_', '-')}-{m.Groups[2].Value}";
    var timeAttr = (string?)testcase.Attribute("time") ?? "0";
    var ms = (long)Math.Round(double.Parse(timeAttr, System.Globalization.CultureInfo.InvariantCulture) * 1000);

    string verdict = "PASS";
    string actual = "ok";
    var failure = testcase.Element("failure");
    var error = testcase.Element("error");
    var skipped = testcase.Element("skipped");
    if (error is not null) { verdict = "ERROR"; actual = (string?)error.Attribute("message") ?? ""; }
    else if (failure is not null) { verdict = "FAIL"; actual = (string?)failure.Attribute("message") ?? ""; }
    else if (skipped is not null) { verdict = "SKIP"; actual = (string?)skipped.Attribute("message") ?? ""; }

    // type/role/route never reach JUnit output; only the id was stamped
    // into the method name. The caller folds those back in from
    // testcases.csv by id -- this adapter's job is verdict+timing.
    csv.AppendLine(CsvJoin(id, "ui", "", "", "", actual, verdict, ms.ToString()));
    written++;
}

File.WriteAllText(args[1], csv.ToString());
Console.Error.WriteLine($"JunitToCsv: wrote {written} rows to {args[1]}");
return 0;

static string CsvJoin(params string[] fields)
{
    var parts = fields.Select(f =>
        f.Contains(',') || f.Contains('"') || f.Contains('\n')
            ? "\"" + f.Replace("\"", "\"\"") + "\""
            : f);
    return string.Join(",", parts);
}
