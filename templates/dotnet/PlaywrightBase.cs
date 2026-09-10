// Copied into the target project only after Tier 1 detection confirms
// Microsoft.Playwright.NUnit already resolves from the project's own
// .csproj. This framework never `dotnet add package`s it for you.
using System.Text.Json;
using Microsoft.Playwright;
using Microsoft.Playwright.NUnit;
using NUnit.Framework;

namespace Tests;

/// <summary>
/// Inherited by one generated fixture per feature. Owns storage-state
/// loading so specs never touch a login form.
/// </summary>
public abstract class PlaywrightBase : PageTest
{
    /// <summary>Override per feature/role; default matches the shared example.</summary>
    protected virtual string Role => "admin";

    public override BrowserNewContextOptions ContextOptions()
    {
        var stateFile = Path.Combine("tests", ".auth", $"{Role}.json");
        if (!File.Exists(stateFile))
        {
            Assert.Ignore($"no saved session for role '{Role}' — run /test-auth {Role}");
        }

        return new BrowserNewContextOptions
        {
            BaseURL = BaseUrl(),
            StorageStatePath = stateFile,
        };
    }

    /// <summary>
    /// base_url from tests/credentials.json, via System.Text.Json — part of
    /// the BCL since .NET Core 3, not an added dependency.
    /// </summary>
    protected static string BaseUrl()
    {
        var json = File.ReadAllText(Path.Combine("tests", "credentials.json"));
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.GetProperty("base_url").GetString()
            ?? throw new InvalidOperationException("no base_url in tests/credentials.json");
    }
}
