using Expify.Api.Extraction;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Options;
using System.Diagnostics;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
// Learn more about configuring OpenAPI at https://aka.ms/aspnet/openapi
builder.Services.AddOpenApi();
builder.Services.AddSwaggerGen();

// App Service terminates TLS at its front end and forwards plain HTTP.
// Trust X-Forwarded-For/Proto so the app sees the original scheme (Secure cookies, HTTPS redirect).
// The front end's address is not loopback, so the default known networks/proxies must be cleared.
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    options.KnownNetworks.Clear();
    options.KnownProxies.Clear();
});

// The receipt extraction spike is Development-only: production neither binds nor needs these settings.
if (builder.Environment.IsDevelopment())
{
    builder.Services.Configure<ExtractionOptions>(builder.Configuration.GetSection(ExtractionOptions.SectionName));
}

var app = builder.Build();

app.UseForwardedHeaders();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
    // Swagger UI is a local testing aid only; never served in Production.
    app.UseSwagger();
    app.UseSwaggerUI(c => c.SwaggerEndpoint("/swagger/v1/swagger.json", "Expify API V1"));
}

app.UseHttpsRedirection();

// The Angular build is copied into wwwroot at publish time, so the SPA and API share one origin.
app.UseDefaultFiles();
app.UseStaticFiles();

app.MapGet("/api/health", () => Results.Ok(new { status = "ok" }))
    .WithName("GetHealth");

// Extraction spike endpoint: mapped only in Development, before the /api fallback,
// so production answers 404 for it.
if (app.Environment.IsDevelopment())
{
    app.MapPost("/api/dev/receipts/extract", ExtractReceiptAsync)
        .WithName("DevExtractReceipt")
        .DisableAntiforgery();
}

// Unknown /api routes return 404 instead of falling through to the SPA.
app.MapFallback("/api/{**rest}", () => Results.NotFound());

// Every other unmatched route serves the SPA so Angular deep links work.
app.MapFallbackToFile("index.html");

app.Run();

// The form is read by hand (not bound as IFormFile) so a request without a multipart body gets a
// 400 instead of a 415, and the extractor is resolved at request time because it is registered
// only once an adapter exists.
static async Task<IResult> ExtractReceiptAsync(
    HttpContext context,
    string? model,
    IOptions<ExtractionOptions> extractionOptions,
    CancellationToken ct)
{
    const long maxPhotoBytes = 10 * 1024 * 1024;
    string[] allowedMediaTypes = ["image/jpeg", "image/png", "image/webp"];

    if (!context.Request.HasFormContentType)
    {
        return Results.Problem("Send a multipart form with a 'photo' file.", statusCode: StatusCodes.Status400BadRequest);
    }

    IFormCollection form;
    try
    {
        form = await context.Request.ReadFormAsync(ct);
    }
    catch (InvalidDataException ex)
    {
        return Results.Problem($"The form could not be read: {ex.Message}", statusCode: StatusCodes.Status400BadRequest);
    }

    var photo = form.Files.GetFile("photo");
    if (photo is null || photo.Length == 0)
    {
        return Results.Problem("The 'photo' file is missing or empty.", statusCode: StatusCodes.Status400BadRequest);
    }

    var mediaType = photo.ContentType?.Split(';')[0].Trim().ToLowerInvariant() ?? string.Empty;
    if (!allowedMediaTypes.Contains(mediaType))
    {
        return Results.Problem(
            $"Unsupported photo type '{mediaType}'. Use {string.Join(", ", allowedMediaTypes)}.",
            statusCode: StatusCodes.Status400BadRequest);
    }

    if (photo.Length > maxPhotoBytes)
    {
        return Results.Problem("The photo is larger than 10 MB.", statusCode: StatusCodes.Status400BadRequest);
    }

    var options = extractionOptions.Value;
    if (!options.TryGetModel(model, out _))
    {
        var known = options.Models.Count == 0 ? "none configured" : string.Join(", ", options.Models.Keys);
        return Results.Problem(
            $"Unknown model alias '{model}'. Known aliases: {known} (Extraction:OpenRouter:Models).",
            statusCode: StatusCodes.Status400BadRequest);
    }

    if (string.IsNullOrWhiteSpace(options.ApiKey))
    {
        return Results.Problem(
            $"The OpenRouter key is not configured. Set {ExtractionOptions.ApiKeyPath} with dotnet user-secrets.",
            statusCode: StatusCodes.Status503ServiceUnavailable);
    }

    var extractor = context.RequestServices.GetService<IReceiptExtractor>();
    if (extractor is null)
    {
        return Results.Problem("No receipt extractor is registered.", statusCode: StatusCodes.Status503ServiceUnavailable);
    }

    try
    {
        await using var image = photo.OpenReadStream();
        var stopwatch = Stopwatch.StartNew();
        var receipt = await extractor.ExtractAsync(model!, image, mediaType, ct);
        stopwatch.Stop();
        return Results.Ok(receipt with { ProviderMs = stopwatch.ElapsedMilliseconds });
    }
    catch (ExtractionFailedException ex)
    {
        return Results.Problem(ex.Message, statusCode: StatusCodes.Status502BadGateway);
    }
}
