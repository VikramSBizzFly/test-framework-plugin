// Converts a Surefire/Failsafe JUnit report into the framework's results CSV:
// id,type,role,route,expected,actual,verdict,ms
//
// Standard library only (javax.xml.parsers, part of the JDK) — no extra
// dependency to compile or download.
//
// Usage: java JunitToCsv.java <junit.xml> <out.csv>
import org.w3c.dom.*;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import java.io.File;
import java.io.FileWriter;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class JunitToCsv {
    // skills/test-codegen/references/java.md's naming convention: a case id
    // like INV-014 is encoded in the method name as INV_014 (hyphen ->
    // underscore, since a hyphen is not a legal Java identifier).
    // Multi-segment prefixes are real: `tf.sh rbac` emits RBAC-USER-002,
    // which codegen writes as the method name RBAC_USER_002_...
    private static final Pattern ID_RE =
            Pattern.compile("([A-Z][A-Z0-9]*(?:_[A-Z][A-Z0-9]*)*)_(\\d+)");

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("usage: JunitToCsv <junit.xml> <out.csv>");
            System.exit(1);
        }

        DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
        DocumentBuilder db = dbf.newDocumentBuilder();
        Document doc = db.parse(new File(args[0]));
        NodeList cases = doc.getElementsByTagName("testcase");

        StringBuilder csv = new StringBuilder("id,type,role,route,expected,actual,verdict,ms\n");
        int written = 0;

        for (int i = 0; i < cases.getLength(); i++) {
            Element testcase = (Element) cases.item(i);
            String name = testcase.getAttribute("name");
            Matcher m = ID_RE.matcher(name);
            if (!m.find()) continue; // not one of ours (a helper method, etc.)
            String id = m.group(1).replace('_', '-') + "-" + m.group(2);

            long ms = Math.round(parseDoubleOr(testcase.getAttribute("time"), 0) * 1000);

            String verdict = "PASS";
            String actual = "ok";
            NodeList failures = testcase.getElementsByTagName("failure");
            NodeList errors = testcase.getElementsByTagName("error");
            NodeList skipped = testcase.getElementsByTagName("skipped");
            if (errors.getLength() > 0) {
                verdict = "ERROR";
                actual = ((Element) errors.item(0)).getAttribute("message");
            } else if (failures.getLength() > 0) {
                verdict = "FAIL";
                actual = ((Element) failures.item(0)).getAttribute("message");
            } else if (skipped.getLength() > 0) {
                verdict = "SKIP";
                actual = ((Element) skipped.item(0)).getAttribute("message");
            }

            // type/role/route never reach JUnit output; only the id was
            // stamped into the method name. The caller folds those back in
            // from testcases.csv by id -- this adapter's job is verdict+timing.
            csv.append(csvJoin(id, "ui", "", "", "", actual, verdict, String.valueOf(ms))).append('\n');
            written++;
        }

        try (FileWriter w = new FileWriter(args[1])) {
            w.write(csv.toString());
        }
        System.err.println("JunitToCsv: wrote " + written + " rows to " + args[1]);
    }

    private static double parseDoubleOr(String s, double fallback) {
        try {
            return s == null || s.isEmpty() ? fallback : Double.parseDouble(s);
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static String csvJoin(String... fields) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < fields.length; i++) {
            if (i > 0) out.append(',');
            String f = fields[i] == null ? "" : fields[i];
            if (f.contains(",") || f.contains("\"") || f.contains("\n")) {
                out.append('"').append(f.replace("\"", "\"\"")).append('"');
            } else {
                out.append(f);
            }
        }
        return out.toString();
    }
}
