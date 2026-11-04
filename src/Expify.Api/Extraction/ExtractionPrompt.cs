using System.Text.Json;
using System.Text.Json.Nodes;

namespace Expify.Api.Extraction;

/// <summary>
/// Instructions, category list and JSON schema shared by every model, so each one gets identical
/// input. S-02 lifts this file as the starting point for the real upload flow.
/// </summary>
public static class ExtractionPrompt
{
    /// <summary>Name sent with the JSON-schema response format.</summary>
    public const string SchemaName = "receipt_extraction";

    // PROVISIONAL: this list is a placeholder for the spike only. Whether categories are a fixed
    // list or free text is Open Roadmap Question 6, to be settled in the S-02 plan. Category
    // accuracy is reported by the spike, not gated.
    public static readonly IReadOnlyList<string> Categories =
    [
        "groceries",
        "dining",
        "household",
        "personal-care",
        "health",
        "clothing",
        "electronics",
        "transport",
        "entertainment",
        "other",
    ];

    public static string Instructions { get; } = $"""
        You read photos of Polish shop receipts (paragon fiskalny) and return their contents as JSON
        matching the provided schema. Return only the JSON object.

        Rules:
        - store: the shop or company name as printed at the top of the receipt.
        - purchaseDate: the date of purchase printed on the receipt, formatted as yyyy-MM-dd.
        - currency: the ISO 4217 code of the receipt currency; Polish receipts are PLN.
        - total: the printed total to pay (for example "SUMA PLN" or "DO ZAPŁATY"). Read the printed
          value; do not compute it as a sum of the items.
        - items: every purchased line item, in printed order. name is the item text as printed;
          price is the final line amount for that item, after any discount printed for it.
        - category: assign each item exactly one of: {string.Join(", ", Categories)}.
        - Write all amounts as decimal numbers with a dot as the decimal separator (12.34), not a comma.
        - Use null for any field you cannot read with confidence. Never guess a value.
        """;

    /// <summary>
    /// Strict JSON schema for the model output: the receipt fields without run metadata.
    /// All fields are required; nullable fields allow <c>null</c>; no additional properties.
    /// </summary>
    public static JsonObject Schema => (JsonObject)JsonNode.Parse(SchemaJson)!;

    private static readonly string SchemaJson = $$"""
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["store", "purchaseDate", "currency", "total", "items"],
          "properties": {
            "store": { "type": ["string", "null"] },
            "purchaseDate": {
              "type": ["string", "null"],
              "description": "Purchase date as yyyy-MM-dd."
            },
            "currency": { "type": "string", "description": "ISO 4217 code, expected PLN." },
            "total": { "type": ["number", "null"], "description": "Printed total, not a sum of items." },
            "items": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["name", "price", "category"],
                "properties": {
                  "name": { "type": "string" },
                  "price": { "type": ["number", "null"] },
                  "category": { "type": "string", "enum": {{JsonSerializer.Serialize(Categories)}} }
                }
              }
            }
          }
        }
        """;
}
