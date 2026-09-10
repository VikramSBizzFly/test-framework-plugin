// Copied into the target project only after Tier 1 detection confirms
// com.microsoft.playwright already resolves from pom.xml/build.gradle. This
// framework never adds the dependency or runs `mvn install` on your behalf.
package tests;

import com.microsoft.playwright.*;
import com.microsoft.playwright.options.AriaRole;
import org.junit.jupiter.api.*;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Extended by one generated test class per feature. Owns the browser
 * lifecycle and storage-state loading so specs never touch either. */
public abstract class PlaywrightBase {
    protected static Playwright playwright;
    protected static Browser browser;
    protected BrowserContext context;
    protected Page page;

    /** Override per feature/role; default matches the shared example. */
    protected String role() {
        return "admin";
    }

    @BeforeAll
    static void launchBrowser() {
        playwright = Playwright.create();
        browser = playwright.chromium().launch();
    }

    @AfterAll
    static void closeBrowser() {
        if (browser != null) browser.close();
        if (playwright != null) playwright.close();
    }

    @BeforeEach
    void openContext() {
        Path stateFile = Paths.get("tests/.auth/" + role() + ".json");
        if (!Files.exists(stateFile)) {
            Assumptions.assumeTrue(false,
                "no saved session for role '" + role() + "' — run /test-auth " + role());
        }
        Browser.NewContextOptions opts = new Browser.NewContextOptions()
            .setBaseURL(baseUrl())
            .setStorageStatePath(stateFile);
        context = browser.newContext(opts);
        page = context.newPage();
    }

    @AfterEach
    void closeContext() {
        if (context != null) context.close();
    }

    /** base_url from tests/credentials.json. No JSON dependency is assumed
     * present, so this reads the one flat key it needs by hand — the same
     * approach scripts/tf.sh's own json_get takes for the same reason. */
    protected static String baseUrl() {
        try {
            String json = Files.readString(Paths.get("tests/credentials.json"));
            Matcher m = Pattern.compile("\"base_url\"\\s*:\\s*\"([^\"]*)\"").matcher(json);
            if (m.find()) return m.group(1);
            throw new IllegalStateException("no base_url in tests/credentials.json");
        } catch (IOException e) {
            throw new IllegalStateException("cannot read tests/credentials.json", e);
        }
    }

    /** Convenience matching skills/test-codegen/references/java.md's table. */
    protected Locator role(AriaRole role, String name) {
        return page.getByRole(role, new Page.GetByRoleOptions().setName(name));
    }
}
