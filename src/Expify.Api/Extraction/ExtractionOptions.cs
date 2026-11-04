namespace Expify.Api.Extraction;

/// <summary>
/// OpenRouter settings bound from <c>Extraction:OpenRouter</c>.
/// The API key comes from <c>dotnet user-secrets</c> locally (App Service settings in production)
/// and is never stored in appsettings files.
/// </summary>
public sealed class ExtractionOptions
{
    public const string SectionName = "Extraction:OpenRouter";

    /// <summary>Configuration path of the key, used in error messages instead of its value.</summary>
    public const string ApiKeyPath = SectionName + ":ApiKey";

    public string? ApiKey { get; set; }

    public string BaseUrl { get; set; } = "https://openrouter.ai/api/v1";

    /// <summary>Model alias (for example <c>claude</c>, <c>gpt</c>) to OpenRouter model slug.</summary>
    public Dictionary<string, string> Models { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Case-insensitive alias lookup; the configuration binder may replace the dictionary's comparer.</summary>
    public bool TryGetModel(string? alias, out string slug)
    {
        slug = string.Empty;
        if (string.IsNullOrWhiteSpace(alias))
        {
            return false;
        }

        foreach (var (key, value) in Models)
        {
            if (string.Equals(key, alias, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(value))
            {
                slug = value;
                return true;
            }
        }

        return false;
    }
}
