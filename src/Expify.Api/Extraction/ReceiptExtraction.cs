namespace Expify.Api.Extraction;

/// <summary>
/// Reads a receipt photo with the AI model mapped to <c>modelAlias</c> and returns one result shape
/// regardless of which model answered.
/// </summary>
public interface IReceiptExtractor
{
    /// <exception cref="ExtractionFailedException">
    /// The call failed, was refused, or returned output that does not match the schema.
    /// </exception>
    Task<ExtractedReceipt> ExtractAsync(string modelAlias, Stream image, string mediaType, CancellationToken ct);
}

/// <summary>
/// Extracted receipt fields plus run metadata. Serialized as camelCase JSON.
/// </summary>
/// <param name="Store">Store name as printed, or null when unreadable.</param>
/// <param name="PurchaseDate">Purchase date as <c>yyyy-MM-dd</c>, or null when unreadable.</param>
/// <param name="Currency">Currency code; expected <c>PLN</c>.</param>
/// <param name="Total">The printed total (not a sum of items), or null when unreadable.</param>
/// <param name="Items">Line items as read from the receipt.</param>
/// <param name="ModelAlias">Alias the caller asked for (for example <c>claude</c>).</param>
/// <param name="Model">OpenRouter model slug the alias mapped to.</param>
/// <param name="ServedBy">Backend provider that served the call, when OpenRouter reports it.</param>
/// <param name="ProviderMs">Milliseconds spent in the model call.</param>
/// <param name="InputTokens">Prompt tokens reported by the provider, if any.</param>
/// <param name="OutputTokens">Completion tokens reported by the provider, if any.</param>
public sealed record ExtractedReceipt(
    string? Store,
    string? PurchaseDate,
    string Currency,
    decimal? Total,
    IReadOnlyList<ExtractedReceiptItem> Items,
    string ModelAlias,
    string Model,
    string? ServedBy,
    long ProviderMs,
    int? InputTokens,
    int? OutputTokens);

/// <param name="Name">Item name as printed.</param>
/// <param name="Price">Item price, or null when unreadable.</param>
/// <param name="Category">One of <see cref="ExtractionPrompt.Categories"/>.</param>
public sealed record ExtractedReceiptItem(string Name, decimal? Price, string Category);

/// <summary>
/// Thrown by an <see cref="IReceiptExtractor"/> when the model call fails, is refused, or returns
/// output that does not match the schema. The endpoint maps it to 502. The message must never
/// contain the API key.
/// </summary>
public sealed class ExtractionFailedException : Exception
{
    public ExtractionFailedException(string message) : base(message) { }

    public ExtractionFailedException(string message, Exception innerException) : base(message, innerException) { }
}
