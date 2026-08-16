namespace HLSDownloader.Core;

public sealed record TextFetchResult(string Text, Uri EffectiveUri, string? MediaType = null);

public interface ITextResourceFetcher
{
    Task<TextFetchResult> FetchTextAsync(Uri uri, Uri? referer = null, CancellationToken cancellationToken = default);
}

public sealed record HtmlDiscoveryOptions(
    int MaximumDepth = 3,
    int MaximumDocuments = 16,
    int MaximumResults = 64,
    int MaximumHtmlCharacters = 8 * 1024 * 1024)
{
    internal void Validate()
    {
        if (MaximumDepth is < 0 or > 8 || MaximumDocuments is < 1 or > 128 ||
            MaximumResults is < 1 or > 512 || MaximumHtmlCharacters is < 1024 or > 16 * 1024 * 1024)
            throw new ArgumentOutOfRangeException(nameof(HtmlDiscoveryOptions));
    }
}

public sealed class HtmlMediaDiscovery(ITextResourceFetcher fetcher, HtmlDiscoveryOptions? options = null)
{
    private readonly HtmlDiscoveryOptions _options = options ?? new();

    public async Task<IReadOnlyList<MediaCandidate>> DiscoverAsync(
        Uri pageUri,
        CancellationToken cancellationToken = default)
    {
        if (!UriUtilities.IsHttp(pageUri) || !string.IsNullOrEmpty(pageUri.UserInfo))
            throw new UnsafeNetworkTargetException("The page URI is not a safe HTTP(S) URI.");
        _options.Validate();
        var root = await fetcher.FetchTextAsync(pageUri, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!UriUtilities.IsSameOrigin(pageUri, root.EffectiveUri))
            throw new UnsafeNetworkTargetException("The root page redirected across origins.");
        return await DiscoverAsync(root.Text, root.EffectiveUri, cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<MediaCandidate>> DiscoverAsync(
        string rootHtml,
        Uri rootUri,
        CancellationToken cancellationToken = default)
    {
        _options.Validate();
        var queue = new Queue<Work>();
        queue.Enqueue(new(rootHtml, rootUri, 0));
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var results = new List<MediaCandidate>();
        var resultKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var documents = 0;

        while (queue.Count > 0 && documents < _options.MaximumDocuments && results.Count < _options.MaximumResults)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var work = queue.Dequeue();
            if (work.Html.Length > _options.MaximumHtmlCharacters || !visited.Add(work.Uri.AbsoluteUri)) continue;
            documents++;
            var extraction = HtmlMediaExtractor.Extract(work.Html, work.Uri);
            foreach (var reference in extraction.Media)
            {
                if (reference.Kind == MediaCandidateKind.WidevineDash &&
                    !WidevineDownloadPolicy.IsDownloadableWidevineDomain(reference.Uri)) continue;
                var key = $"{reference.Kind}:{reference.Uri.AbsoluteUri}";
                if (!resultKeys.Add(key)) continue;
                results.Add(new(reference.Uri, reference.Kind,
                    work.Depth == 0 ? reference.Origin : MediaCandidateOrigin.Iframe,
                    work.Uri, work.Depth, reference.PosterUri, reference.Title ?? extraction.Title));
                if (results.Count == _options.MaximumResults) break;
            }
            if (work.Depth >= _options.MaximumDepth) continue;
            var srcdocIndex = 0;
            foreach (var frame in extraction.Frames)
            {
                if (!string.IsNullOrEmpty(frame.SourceDocument))
                {
                    // A fragment distinguishes multiple srcdoc documents without creating a network target.
                    var builder = new UriBuilder(work.Uri) { Fragment = $"hls-srcdoc-{work.Depth + 1}-{srcdocIndex++}" };
                    queue.Enqueue(new(frame.SourceDocument, builder.Uri, work.Depth + 1));
                    continue;
                }
                if (frame.Uri is null || !UriUtilities.IsSameOrigin(rootUri, frame.Uri) || visited.Contains(frame.Uri.AbsoluteUri))
                    continue;
                try
                {
                    var fetched = await fetcher.FetchTextAsync(frame.Uri, work.Uri, cancellationToken).ConfigureAwait(false);
                    if (!UriUtilities.IsSameOrigin(rootUri, fetched.EffectiveUri) ||
                        fetched.Text.Length > _options.MaximumHtmlCharacters) continue;
                    queue.Enqueue(new(fetched.Text, fetched.EffectiveUri, work.Depth + 1));
                }
                catch (CoreException) { }
                catch (HttpRequestException) { }
            }
        }
        return results;
    }

    private sealed record Work(string Html, Uri Uri, int Depth);
}
