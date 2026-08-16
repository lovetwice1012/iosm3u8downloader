using System.Text.Json;

namespace HLSDownloader.WebProbe;

public static class WebProbeScript
{
    public static string CreateDocumentStartScript(
        string nonce,
        IEnumerable<string> downloadableWidevineHosts)
    {
        if (string.IsNullOrWhiteSpace(nonce) || nonce.Length > 256)
        {
            throw new ArgumentException("A valid probe nonce is required.", nameof(nonce));
        }

        ArgumentNullException.ThrowIfNull(downloadableWidevineHosts);
        var hosts = downloadableWidevineHosts
            .Select(host => host?.Trim().ToLowerInvariant())
            .Where(host => !string.IsNullOrEmpty(host))
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        if (hosts.Length == 0 || hosts.Length > 64 ||
            hosts.Any(host => host!.Length > 253 || Uri.CheckHostName(host) != UriHostNameType.Dns))
        {
            throw new ArgumentException("A valid Widevine host allowlist is required.", nameof(downloadableWidevineHosts));
        }

        return ScriptTemplate
            .Replace("__NONCE_JSON__", JsonSerializer.Serialize(nonce), StringComparison.Ordinal)
            .Replace(
                "__ALLOWED_WIDEVINE_HOSTS_JSON__",
                JsonSerializer.Serialize(hosts),
                StringComparison.Ordinal);
    }

    private const string ScriptTemplate = """
(() => {
  'use strict';
  if (globalThis.__hlsDownloaderProbeInstalled === true) return;
  Object.defineProperty(globalThis, '__hlsDownloaderProbeInstalled', { value: true });

  const CHANNEL = 'hls-downloader-probe';
  const NONCE = __NONCE_JSON__;
  const ALLOWED_WIDEVINE_HOSTS = __ALLOWED_WIDEVINE_HOSTS_JSON__;
  const MAX_SIGNALS = 4000;
  const seen = new Set();
  let sequence = 0;
  let allowedWidevineManifestObserved = false;
  let disallowedWidevineManifestObserved = false;

  // Capture the EME guard's security-sensitive intrinsics before page scripts
  // can replace globals or prototype methods. The guarded function below must
  // not consult mutable page-world helpers when it makes its allow/deny choice.
  const safeString = globalThis.String;
  const safeToLowerCase = globalThis.String.prototype.toLowerCase;
  const safeIncludes = globalThis.String.prototype.includes;
  const safeEndsWith = globalThis.String.prototype.endsWith;
  const safeReflectApply = globalThis.Reflect.apply;
  const safeGetOwnPropertyDescriptor = globalThis.Object.getOwnPropertyDescriptor;
  const SafeDOMException = globalThis.DOMException;
  const SafeTypeError = globalThis.TypeError;
  const SafePromise = globalThis.Promise;
  const safePromiseReject = SafePromise.reject.bind(SafePromise);
  const safePromiseThen = SafePromise.prototype.then;
  const safeLocation = globalThis.location;
  // Location.href is [LegacyUnforgeable] in Chromium, so its accessor lives on
  // the Location instance rather than Location.prototype.
  const safeLocationHrefGetter = safeGetOwnPropertyDescriptor(safeLocation, 'href')?.get;
  const SafeURL = globalThis.URL;
  const safeURLProtocolGetter = safeGetOwnPropertyDescriptor(SafeURL.prototype, 'protocol')?.get;
  const safeURLUsernameGetter = safeGetOwnPropertyDescriptor(SafeURL.prototype, 'username')?.get;
  const safeURLPasswordGetter = safeGetOwnPropertyDescriptor(SafeURL.prototype, 'password')?.get;
  const safeURLHostnameGetter = safeGetOwnPropertyDescriptor(SafeURL.prototype, 'hostname')?.get;
  const safeURLPathnameGetter = safeGetOwnPropertyDescriptor(SafeURL.prototype, 'pathname')?.get;
  const SafeResponse = globalThis.Response;
  const safeResponseOkGetter = SafeResponse
    ? safeGetOwnPropertyDescriptor(SafeResponse.prototype, 'ok')?.get
    : undefined;
  const safeResponseURLGetter = SafeResponse
    ? safeGetOwnPropertyDescriptor(SafeResponse.prototype, 'url')?.get
    : undefined;
  const safeResponseHeadersGetter = SafeResponse
    ? safeGetOwnPropertyDescriptor(SafeResponse.prototype, 'headers')?.get
    : undefined;
  const safeHeadersGet = globalThis.Headers?.prototype?.get;
  const SafeXHR = globalThis.XMLHttpRequest;
  const safeXHRStatusGetter = SafeXHR
    ? safeGetOwnPropertyDescriptor(SafeXHR.prototype, 'status')?.get
    : undefined;
  const safeXHRResponseURLGetter = SafeXHR
    ? safeGetOwnPropertyDescriptor(SafeXHR.prototype, 'responseURL')?.get
    : undefined;
  const safeXHRGetResponseHeader = SafeXHR?.prototype?.getResponseHeader;
  const safeEventTargetAddEventListener = globalThis.EventTarget?.prototype?.addEventListener;

  const lower = value => safeReflectApply(safeToLowerCase, safeString(value ?? ''), []);

  const readURLPart = (getter, url) =>
    typeof getter === 'function' ? safeReflectApply(getter, url, []) : '';

  const parseSafeURL = value => {
    try {
      return new SafeURL(safeString(value ?? ''));
    } catch (_) {
      return null;
    }
  };

  const isDownloadableWidevineURL = rawUrl => {
    const url = parseSafeURL(rawUrl);
    if (!url) return false;
    const protocol = lower(readURLPart(safeURLProtocolGetter, url));
    const username = readURLPart(safeURLUsernameGetter, url);
    const password = readURLPart(safeURLPasswordGetter, url);
    const hostname = lower(readURLPart(safeURLHostnameGetter, url));
    if (protocol !== 'https:' || username || password || !hostname) return false;
    for (let index = 0; index < ALLOWED_WIDEVINE_HOSTS.length; index += 1) {
      if (hostname === ALLOWED_WIDEVINE_HOSTS[index]) return true;
    }
    return false;
  };

  const looksLikeDashManifest = (rawUrl, mime) => {
    const type = lower(mime);
    if (safeReflectApply(safeIncludes, type, ['dash+xml'])) return true;
    const url = parseSafeURL(rawUrl);
    if (!url) return false;
    const path = lower(readURLPart(safeURLPathnameGetter, url));
    return safeReflectApply(safeEndsWith, path, ['.mpd']);
  };

  const observeDashResponse = (rawUrl, mime, succeeded) => {
    if (succeeded !== true || !looksLikeDashManifest(rawUrl, mime)) return;
    if (isDownloadableWidevineURL(rawUrl) && !disallowedWidevineManifestObserved) {
      allowedWidevineManifestObserved = true;
    } else {
      disallowedWidevineManifestObserved = true;
      allowedWidevineManifestObserved = false;
    }
  };

  const currentFrameURL = () => {
    try {
      return typeof safeLocationHrefGetter === 'function'
        ? safeReflectApply(safeLocationHrefGetter, safeLocation, [])
        : '';
    } catch (_) {
      return '';
    }
  };

  const observeFetchResponse = response => {
    try {
      if (typeof safeResponseOkGetter !== 'function'
          || typeof safeResponseURLGetter !== 'function'
          || typeof safeResponseHeadersGetter !== 'function'
          || typeof safeHeadersGet !== 'function') return response;
      const succeeded = safeReflectApply(safeResponseOkGetter, response, []) === true;
      const url = safeReflectApply(safeResponseURLGetter, response, []);
      const headers = safeReflectApply(safeResponseHeadersGetter, response, []);
      const mime = safeReflectApply(safeHeadersGet, headers, ['Content-Type']) || '';
      observeDashResponse(url, mime, succeeded);
    } catch (_) { }
    return response;
  };

  const text = (value, maximum) => {
    if (typeof value !== 'string') return '';
    return value.slice(0, maximum);
  };

  const absoluteHttpUrl = value => {
    try {
      const url = new URL(String(value || ''), document.baseURI);
      if (url.protocol !== 'https:' && url.protocol !== 'http:') return '';
      if (url.username || url.password || !url.hostname) return '';
      url.hash = '';
      return url.href.slice(0, 8192);
    } catch (_) {
      return '';
    }
  };

  const looksLikeManifest = (url, mime) => {
    const value = String(url || '').toLowerCase();
    const type = String(mime || '').toLowerCase();
    return /(?:\.m3u8|\.mpd)(?:$|[?#])/.test(value)
      || type.includes('mpegurl')
      || type.includes('dash+xml');
  };

  const emit = (kind, rawUrl, source, extra = {}) => {
    if (sequence >= MAX_SIGNALS) return;
    const url = absoluteHttpUrl(rawUrl);
    if (!url) return;
    if ((kind === 'manifest' || kind === 'network')
        && looksLikeDashManifest(url, extra.mime)
        && !isDownloadableWidevineURL(url)) {
      disallowedWidevineManifestObserved = true;
      allowedWidevineManifestObserved = false;
    }
    if (kind !== 'media' && kind !== 'eme' && !looksLikeManifest(url, extra.mime)) return;
    const key = `${kind}\n${url}\n${String(extra.keySystem || '')}`;
    if (seen.has(key)) return;
    seen.add(key);
    sequence += 1;
    try {
      globalThis.chrome?.webview?.postMessage({
        channel: CHANNEL,
        version: 1,
        nonce: NONCE,
        seq: sequence,
        kind,
        url,
        source: text(source, 80),
        mime: text(extra.mime, 160),
        thumbnail: absoluteHttpUrl(extra.thumbnail),
        title: text(extra.title || document.title, 512),
        keySystem: text(extra.keySystem, 160),
        pageUrl: absoluteHttpUrl(location.href)
      });
    } catch (_) { }
  };

  const scanMedia = root => {
    const elements = [];
    if (root?.matches?.('video,audio,source')) elements.push(root);
    try { elements.push(...(root?.querySelectorAll?.('video,audio,source') || [])); } catch (_) { }
    for (const element of elements) {
      const owner = element.closest?.('video,audio') || element;
      const source = element.currentSrc || element.src || element.getAttribute?.('src');
      const mime = element.type || element.getAttribute?.('type') || '';
      emit(looksLikeManifest(source, mime) ? 'manifest' : 'media', source, 'dom', {
        mime,
        thumbnail: owner.poster || owner.getAttribute?.('poster') || '',
        title: owner.getAttribute?.('aria-label') || owner.title || document.title
      });
    }
  };

  const observeDocument = () => {
    scanMedia(document);
    const root = document.documentElement;
    if (!root) return;
    new MutationObserver(records => {
      for (const record of records) {
        if (record.type === 'attributes') scanMedia(record.target);
        for (const node of record.addedNodes || []) {
          if (node?.nodeType === Node.ELEMENT_NODE) scanMedia(node);
        }
      }
    }).observe(root, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['src', 'type', 'poster']
    });
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', observeDocument, { once: true });
  } else {
    observeDocument();
  }

  try {
    const originalFetch = globalThis.fetch;
    if (typeof originalFetch === 'function') {
      globalThis.fetch = function(input, init) {
        const candidate = typeof input === 'string' ? input : input?.url;
        emit('network', candidate, 'fetch');
        const responsePromise = safeReflectApply(originalFetch, this, arguments);
        return safeReflectApply(safePromiseThen, responsePromise, [observeFetchResponse]);
      };
    }
  } catch (_) { }

  try {
    const originalOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url, ...rest) {
      emit('network', url, 'xhr');
      const xhr = this;
      if (typeof safeEventTargetAddEventListener === 'function') {
        safeReflectApply(safeEventTargetAddEventListener, xhr, ['loadend', () => {
          try {
            if (typeof safeXHRStatusGetter !== 'function'
                || typeof safeXHRResponseURLGetter !== 'function'
                || typeof safeXHRGetResponseHeader !== 'function') return;
            const status = safeReflectApply(safeXHRStatusGetter, xhr, []);
            const responseUrl = safeReflectApply(safeXHRResponseURLGetter, xhr, []);
            const mime = safeReflectApply(
              safeXHRGetResponseHeader,
              xhr,
              ['Content-Type']) || '';
            observeDashResponse(
              responseUrl,
              mime,
              Number.isInteger(status) && status >= 200 && status < 300);
          } catch (_) { }
        }, { once: true }]);
      }
      return safeReflectApply(originalOpen, xhr, [method, url, ...rest]);
    };
  } catch (_) { }

  try {
    const reportEntry = entry => emit('network', entry?.name, 'performance', {
      mime: entry?.contentType || ''
    });
    for (const entry of performance.getEntriesByType('resource')) reportEntry(entry);
    new PerformanceObserver(list => {
      for (const entry of list.getEntries()) reportEntry(entry);
    }).observe({ type: 'resource', buffered: true });
  } catch (_) { }

  document.addEventListener('encrypted', event => {
    const media = event.target;
    emit('eme', media?.currentSrc || media?.src || location.href, 'encrypted-event', {
      mime: event.initDataType || '',
      thumbnail: media?.poster || '',
      title: media?.getAttribute?.('aria-label') || document.title
    });
  }, true);

  try {
    const navigatorPrototype = globalThis.Navigator?.prototype || Object.getPrototypeOf(navigator);
    const originalDescriptor = Object.getOwnPropertyDescriptor(
      navigatorPrototype,
      'requestMediaKeySystemAccess');
    const originalRequest = originalDescriptor?.value;
    if (typeof originalRequest === 'function') {
      const guardedRequest = function(keySystem, ...configurations) {
        if (typeof keySystem !== 'string') {
          return safePromiseReject(new SafeTypeError('The key system must be a string.'));
        }
        const normalizedKeySystem = safeString(keySystem);
        emit('eme', safeLocation.href, 'requestMediaKeySystemAccess', {
          keySystem: normalizedKeySystem
        });
        const loweredKeySystem = safeReflectApply(safeToLowerCase, normalizedKeySystem, []);
        if (safeReflectApply(safeIncludes, loweredKeySystem, ['widevine'])) {
          if (!isDownloadableWidevineURL(currentFrameURL())
              || !allowedWidevineManifestObserved
              || disallowedWidevineManifestObserved) {
            return safePromiseReject(new SafeDOMException(
              'Widevine playback is not permitted for this host.',
              'NotAllowedError'));
          }
        }
        return safeReflectApply(
          originalRequest,
          this,
          [normalizedKeySystem, ...configurations]);
      };

      let prototypeLocked = false;
      let instanceLocked = false;
      try {
        Object.defineProperty(navigatorPrototype, 'requestMediaKeySystemAccess', {
          value: guardedRequest,
          enumerable: originalDescriptor?.enumerable === true,
          configurable: false,
          writable: false
        });
        const locked = Object.getOwnPropertyDescriptor(
          navigatorPrototype,
          'requestMediaKeySystemAccess');
        prototypeLocked = locked?.value === guardedRequest
          && locked?.configurable === false
          && locked?.writable === false;
      } catch (_) { }

      try {
        if (Object.prototype.hasOwnProperty.call(navigator, 'requestMediaKeySystemAccess')) {
          Reflect.deleteProperty(navigator, 'requestMediaKeySystemAccess');
        }
        Object.defineProperty(navigator, 'requestMediaKeySystemAccess', {
          value: guardedRequest,
          enumerable: false,
          configurable: false,
          writable: false
        });
        const locked = Object.getOwnPropertyDescriptor(navigator, 'requestMediaKeySystemAccess');
        instanceLocked = locked?.value === guardedRequest
          && locked?.configurable === false
          && locked?.writable === false;
      } catch (_) { }

      if (!prototypeLocked || !instanceLocked) {
        emit('eme', location.href, 'widevine-gate-install-failed', {
          keySystem: 'com.widevine.alpha'
        });
        try { globalThis.stop?.(); } catch (_) { }
      }
    }
  } catch (_) {
    emit('eme', location.href, 'widevine-gate-install-failed', {
      keySystem: 'com.widevine.alpha'
    });
    try { globalThis.stop?.(); } catch (_) { }
  }
})();
""";
}
