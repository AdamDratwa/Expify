using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Options;

namespace Expify.Api.Extraction;

/// <summary>
/// Reads a receipt photo through OpenRouter's OpenAI-compatible chat-completions API.
/// Every failure (transport, timeout, non-2xx, 200-with-error, refusal, schema mismatch) surfaces
/// as <see cref="ExtractionFailedException"/>; a cancellation requested by the caller propagates.
/// The API key is only ever written to the Authorization header, never to a message.
/// </summary>
public sealed class OpenRouterReceiptExtractor(HttpClient http, IOptions<ExtractionOptions> options) : IReceiptExtractor
{
    private const int MaxTokens = 16_000;
    private const int MaxErrorDetailLength = 500;

    public async Task<ExtractedReceipt> ExtractAsync(string modelAlias, Stream image, string mediaType, CancellationToken ct)
    {
        var settings = options.Value;
        if (!settings.TryGetModel(modelAlias, out var slug))
        {
            throw new ExtractionFailedException($"Unknown model alias '{modelAlias}'.");
        }

        if (string.IsNullOrWhiteSpace(settings.ApiKey))
        {
            throw new ExtractionFailedException($"The OpenRouter key is not configured ({ExtractionOptions.ApiKeyPath}).");
        }

        using var buffer = new MemoryStream();
        await image.CopyToAsync(buffer, ct);
        var dataUri = $"data:{mediaType};base64,{Convert.ToBase64String(buffer.GetBuffer(), 0, (int)buffer.Length)}";

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{settings.BaseUrl.TrimEnd('/')}/chat/completions")
        {
            Content = new StringContent(BuildRequestBody(slug, dataUri).ToJsonString(), Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", settings.ApiKey);
        // Optional app attribution; a generic name only.
        request.Headers.Add("X-Title", "Expify");

        HttpStatusCodeAndBody response;
        long providerMs;
        try
        {
            var stopwatch = Stopwatch.StartNew();
            using var httpResponse = await http.SendAsync(request, HttpCompletionOption.ResponseContentRead, ct);
            var body = await httpResponse.Content.ReadAsStringAsync(ct);
            stopwatch.Stop();
            providerMs = stopwatch.ElapsedMilliseconds;
            response = new HttpStatusCodeAndBody((int)httpResponse.StatusCode, httpResponse.IsSuccessStatusCode, body);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException ex)
        {
            throw new ExtractionFailedException("The OpenRouter call timed out.", ex);
        }
        catch (HttpRequestException ex)
        {
            throw new ExtractionFailedException($"The OpenRouter call failed: {ex.Message}", ex);
        }

        if (!response.IsSuccess)
        {
            var detail = TryReadErrorMessage(response.Body) ?? "no error message";
            throw new ExtractionFailedException($"OpenRouter returned HTTP {response.StatusCode}: {detail}");
        }

        try
        {
            return ParseResponse(response.Body, modelAlias, slug, providerMs);
        }
        catch (JsonException ex)
        {
            throw new ExtractionFailedException($"OpenRouter returned a reply that is not valid JSON: {ex.Message}", ex);
        }
    }

    private static JsonObject BuildRequestBody(string slug, string dataUri) => new()
    {
        ["model"] = slug,
        ["messages"] = new JsonArray
        {
            new JsonObject
            {
                ["role"] = "system",
                ["content"] = ExtractionPrompt.Instructions,
            },
            new JsonObject
            {
                ["role"] = "user",
                ["content"] = new JsonArray
                {
                    new JsonObject
                    {
                        ["type"] = "image_url",
                        ["image_url"] = new JsonObject { ["url"] = dataUri },
                    },
                },
            },
        },
        ["response_format"] = new JsonObject
        {
            ["type"] = "json_schema",
            ["json_schema"] = new JsonObject
            {
                ["name"] = ExtractionPrompt.SchemaName,
                ["strict"] = true,
                ["schema"] = ExtractionPrompt.Schema,
            },
        },
        // Route only to backends that do not collect data and that honor every parameter
        // (in particular the JSON-schema response format).
        ["provider"] = new JsonObject
        {
            ["data_collection"] = "deny",
            ["require_parameters"] = true,
        },
        ["max_tokens"] = MaxTokens,
    };

    private static ExtractedReceipt ParseResponse(string body, string modelAlias, string slug, long providerMs)
    {
        using var document = JsonDocument.Parse(body);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new ExtractionFailedException("OpenRouter returned a reply that is not a JSON object.");
        }

        if (root.TryGetProperty("error", out var topError) && topError.ValueKind != JsonValueKind.Null)
        {
            throw new ExtractionFailedException($"OpenRouter reported an error: {DescribeError(topError)}");
        }

        if (!root.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array || choices.GetArrayLength() == 0)
        {
            throw new ExtractionFailedException("OpenRouter returned no choices.");
        }

        var choice = choices[0];
        if (choice.TryGetProperty("error", out var choiceError) && choiceError.ValueKind != JsonValueKind.Null)
        {
            throw new ExtractionFailedException($"The model reported an error: {DescribeError(choiceError)}");
        }

        var finishReason = GetString(choice, "finish_reason");
        if (!string.Equals(finishReason, "stop", StringComparison.Ordinal))
        {
            var native = GetString(choice, "native_finish_reason");
            throw new ExtractionFailedException(
                $"The model stopped abnormally (finish_reason '{finishReason ?? "none"}'{(native is null ? "" : $", native '{native}'")}).");
        }

        string? content = null;
        if (choice.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.Object)
        {
            content = GetString(message, "content");
        }

        if (string.IsNullOrWhiteSpace(content))
        {
            throw new ExtractionFailedException("The model returned empty content.");
        }

        var fields = ParseFields(StripCodeFence(content));

        int? inputTokens = null;
        int? outputTokens = null;
        if (root.TryGetProperty("usage", out var usage) && usage.ValueKind == JsonValueKind.Object)
        {
            inputTokens = GetInt(usage, "prompt_tokens");
            outputTokens = GetInt(usage, "completion_tokens");
        }

        return fields with
        {
            ModelAlias = modelAlias,
            Model = slug,
            ServedBy = GetString(root, "provider"),
            ProviderMs = providerMs,
            InputTokens = inputTokens,
            OutputTokens = outputTokens,
        };
    }

    /// <summary>Validates the model's JSON against the extraction schema and maps it.</summary>
    private static ExtractedReceipt ParseFields(string content)
    {
        using var document = JsonDocument.Parse(content);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw SchemaMismatch("the reply is not a JSON object");
        }

        var store = RequireNullableString(root, "store");
        var purchaseDate = RequireNullableString(root, "purchaseDate");
        var currency = RequireNullableString(root, "currency") ?? throw SchemaMismatch("'currency' is null");
        var total = RequireNullableDecimal(root, "total");

        if (!root.TryGetProperty("items", out var itemsElement) || itemsElement.ValueKind != JsonValueKind.Array)
        {
            throw SchemaMismatch("'items' is missing or not an array");
        }

        var items = new List<ExtractedReceiptItem>();
        foreach (var item in itemsElement.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object)
            {
                throw SchemaMismatch("an item is not an object");
            }

            var name = RequireNullableString(item, "name") ?? throw SchemaMismatch("an item 'name' is null");
            var price = RequireNullableDecimal(item, "price");
            var category = RequireNullableString(item, "category") ?? throw SchemaMismatch("an item 'category' is null");
            if (!ExtractionPrompt.Categories.Contains(category))
            {
                throw SchemaMismatch($"item category '{category}' is not in the category list");
            }

            items.Add(new ExtractedReceiptItem(name, price, category));
        }

        return new ExtractedReceipt(store, purchaseDate, currency, total, items, "", "", null, 0, null, null);
    }

    /// <summary>Some models wrap JSON in a single ``` fence even with a JSON-schema response format.</summary>
    private static string StripCodeFence(string content)
    {
        var trimmed = content.Trim();
        if (!trimmed.StartsWith("```", StringComparison.Ordinal) || !trimmed.EndsWith("```", StringComparison.Ordinal) || trimmed.Length < 6)
        {
            return trimmed;
        }

        var firstNewline = trimmed.IndexOf('\n');
        if (firstNewline < 0 || firstNewline + 1 > trimmed.Length - 3)
        {
            return trimmed;
        }

        return trimmed[(firstNewline + 1)..^3].Trim();
    }

    private static string? RequireNullableString(JsonElement obj, string property)
    {
        if (!obj.TryGetProperty(property, out var value))
        {
            throw SchemaMismatch($"'{property}' is missing");
        }

        return value.ValueKind switch
        {
            JsonValueKind.Null => null,
            JsonValueKind.String => value.GetString(),
            _ => throw SchemaMismatch($"'{property}' is not a string"),
        };
    }

    private static decimal? RequireNullableDecimal(JsonElement obj, string property)
    {
        if (!obj.TryGetProperty(property, out var value))
        {
            throw SchemaMismatch($"'{property}' is missing");
        }

        return value.ValueKind switch
        {
            JsonValueKind.Null => null,
            JsonValueKind.Number when value.TryGetDecimal(out var number) => number,
            _ => throw SchemaMismatch($"'{property}' is not a number"),
        };
    }

    private static ExtractionFailedException SchemaMismatch(string reason) =>
        new($"The model reply does not match the extraction schema: {reason}.");

    private static string? GetString(JsonElement obj, string property) =>
        obj.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int? GetInt(JsonElement obj, string property) =>
        obj.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)
            ? number
            : null;

    private static string DescribeError(JsonElement error)
    {
        if (error.ValueKind == JsonValueKind.Object)
        {
            var text = GetString(error, "message") ?? "no message";
            var code = error.TryGetProperty("code", out var codeElement) ? codeElement.ToString() : null;
            return Truncate(string.IsNullOrEmpty(code) ? text : $"{text} (code {code})");
        }

        return Truncate(error.ToString());
    }

    /// <summary>Reads OpenRouter's <c>error.message</c> from a non-2xx body; it never echoes the key.</summary>
    private static string? TryReadErrorMessage(string body)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("error", out var error))
            {
                return DescribeError(error);
            }
        }
        catch (JsonException)
        {
            // Not JSON (for example an HTML gateway page); fall back to the raw text below.
        }

        return Truncate(body);
    }

    private static string Truncate(string text) =>
        text.Length <= MaxErrorDetailLength ? text : text[..MaxErrorDetailLength] + "…";

    private readonly record struct HttpStatusCodeAndBody(int StatusCode, bool IsSuccess, string Body);
}
