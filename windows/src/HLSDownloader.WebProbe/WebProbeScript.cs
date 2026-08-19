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
  let widevineAccessGranted = false;
  let browserObjectSequence = 0;

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
  const safeURLHrefGetter = safeGetOwnPropertyDescriptor(SafeURL.prototype, 'href')?.get;
  const safeURLHashSetter = safeGetOwnPropertyDescriptor(SafeURL.prototype, 'hash')?.set;
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
  const SafeMediaKeySession = globalThis.MediaKeySession;
  const mediaKeySessionPrototype = SafeMediaKeySession?.prototype;
  const originalGenerateRequestDescriptor = mediaKeySessionPrototype
    ? safeGetOwnPropertyDescriptor(mediaKeySessionPrototype, 'generateRequest')
    : undefined;
  const originalUpdateDescriptor = mediaKeySessionPrototype
    ? safeGetOwnPropertyDescriptor(mediaKeySessionPrototype, 'update')
    : undefined;
  const originalGenerateRequest = originalGenerateRequestDescriptor?.value;
  const originalUpdate = originalUpdateDescriptor?.value;
  const SafeBlob = globalThis.Blob;
  const safeBlobSizeGetter = SafeBlob
    ? safeGetOwnPropertyDescriptor(SafeBlob.prototype, 'size')?.get
    : undefined;
  const safeBlobTypeGetter = SafeBlob
    ? safeGetOwnPropertyDescriptor(SafeBlob.prototype, 'type')?.get
    : undefined;
  const safeBlobSlice = SafeBlob?.prototype?.slice;
  const safeBlobArrayBuffer = SafeBlob?.prototype?.arrayBuffer;
  const SafeMediaSource = globalThis.MediaSource;
  const safeMediaSourceAddSourceBuffer = SafeMediaSource?.prototype?.addSourceBuffer;
  const safeCreateObjectURL = SafeURL?.createObjectURL;
  const safeRevokeObjectURL = SafeURL?.revokeObjectURL;
  const SafeMap = globalThis.Map;
  const SafeWeakMap = globalThis.WeakMap;
  const SafeWeakRef = globalThis.WeakRef;
  const SafeCrypto = globalThis.crypto;
  const safeCryptoGetRandomValues = SafeCrypto?.getRandomValues;
  const SafeUint8Array = globalThis.Uint8Array;
  const SafeArrayBuffer = globalThis.ArrayBuffer;
  const SafeTextDecoder = globalThis.TextDecoder;
  const safeStringFromCharCode = globalThis.String.fromCharCode;
  const browserObjects = new SafeMap();
  const browserObjectUrls = new SafeMap();
  const mediaSourceIds = new SafeWeakMap();
  const MAX_BROWSER_OBJECTS = 64;
  const MAX_BROWSER_BLOB_BYTES = 20 * 1024 * 1024 * 1024;
  const MAX_SNIFF_BYTES = 64 * 1024;

  let documentObjectPrefix = '';
  try {
    if (typeof safeCryptoGetRandomValues === 'function') {
      const randomBytes = new SafeUint8Array(16);
      safeReflectApply(safeCryptoGetRandomValues, SafeCrypto, [randomBytes]);
      for (let index = 0; index < randomBytes.length; index += 1) {
        documentObjectPrefix += randomBytes[index].toString(16).padStart(2, '0');
      }
    }
  } catch (_) { }

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
      const url = new SafeURL(safeString(value || ''), safeString(document.baseURI || ''));
      const protocol = lower(readURLPart(safeURLProtocolGetter, url));
      const username = readURLPart(safeURLUsernameGetter, url);
      const password = readURLPart(safeURLPasswordGetter, url);
      const hostname = readURLPart(safeURLHostnameGetter, url);
      if ((protocol !== 'https:' && protocol !== 'http:')
          || username
          || password
          || !hostname) return '';
      if (typeof safeURLHashSetter === 'function') {
        safeReflectApply(safeURLHashSetter, url, ['']);
      }
      return safeString(readURLPart(safeURLHrefGetter, url)).slice(0, 8192);
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
    if (kind !== 'media'
        && kind !== 'eme'
        && kind !== 'eme-lifecycle'
        && !looksLikeManifest(url, extra.mime)) return;
    if (kind !== 'eme-lifecycle') {
      const key = `${kind}\n${url}\n${String(extra.keySystem || '')}`;
      if (seen.has(key)) return;
      seen.add(key);
    }
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
        phase: text(extra.phase, 80),
        pageUrl: absoluteHttpUrl(location.href)
      });
    } catch (_) { }
  };

  const normalizeMediaMime = value => lower(value).split(';', 1)[0].trim();

  const containerFromMime = value => {
    const mime = normalizeMediaMime(value);
    if (safeReflectApply(safeIncludes, mime, ['mpegurl'])) return 'hls';
    if (safeReflectApply(safeIncludes, mime, ['dash+xml'])) return 'dash';
    if (mime === 'video/mp4') return 'mp4';
    if (mime === 'video/quicktime' || mime === 'video/x-m4v') return 'quicktime';
    if (mime === 'audio/mp4' || mime === 'audio/x-m4a') return 'm4a';
    if (mime === 'video/mp2t' || mime === 'video/mpeg') return 'mpegts';
    if (mime === 'video/webm' || mime === 'audio/webm') return 'webm';
    if (mime === 'audio/mpeg') return 'mp3';
    if (mime === 'audio/aac') return 'aac';
    if (mime === 'audio/ogg' || mime === 'application/ogg') return 'ogg';
    if (mime === 'audio/opus') return 'opus';
    return 'unknown';
  };

  const startsWithAscii = (bytes, offset, expected) => {
    if (!bytes || offset < 0 || bytes.length < offset + expected.length) return false;
    for (let index = 0; index < expected.length; index += 1) {
      if (bytes[offset + index] !== expected.charCodeAt(index)) return false;
    }
    return true;
  };

  const classifyMediaPrefix = (buffer, mime) => {
    const bytes = new SafeUint8Array(buffer || new SafeArrayBuffer(0));
    let offset = 0;
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      offset = 3;
    }
    while (offset < bytes.length
           && (bytes[offset] === 0x20 || bytes[offset] === 0x09
               || bytes[offset] === 0x0d || bytes[offset] === 0x0a)) offset += 1;
    if (startsWithAscii(bytes, offset, '#EXTM3U')) return 'hls';
    const xmlPrefix = new SafeTextDecoder('utf-8', { fatal: false })
      .decode(bytes.subarray(offset, Math.min(bytes.length, offset + 4096)));
    if (/<MPD(?:\s|>|\/)/i.test(xmlPrefix)) return 'dash';
    if (bytes.length >= 12 && startsWithAscii(bytes, 4, 'ftyp')) {
      const brand = lower(safeReflectApply(
        safeStringFromCharCode,
        safeString,
        [bytes[8], bytes[9], bytes[10], bytes[11]]));
      return brand === 'm4a ' || normalizeMediaMime(mime) === 'audio/mp4' ? 'm4a' : 'mp4';
    }
    if (bytes.length >= 4 && bytes[0] === 0x1a && bytes[1] === 0x45
        && bytes[2] === 0xdf && bytes[3] === 0xa3) return 'webm';
    if (bytes.length >= 377 && bytes[0] === 0x47
        && bytes[188] === 0x47 && bytes[376] === 0x47) return 'mpegts';
    if (bytes.length >= 4 && startsWithAscii(bytes, 0, 'OggS')) return 'ogg';
    if (bytes.length >= 3 && startsWithAscii(bytes, 0, 'ID3')) return 'mp3';
    if (bytes.length >= 2 && bytes[0] === 0xff && (bytes[1] & 0xf6) === 0xf0) return 'aac';
    if (bytes.length >= 2 && bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0) return 'mp3';
    return 'unknown';
  };

  const extensionForContainer = container => ({
    hls: 'm3u8', dash: 'mpd', mp4: 'mp4', quicktime: 'mov', mpegts: 'ts',
    webm: 'webm', m4a: 'm4a', mp3: 'mp3', aac: 'aac', ogg: 'ogg', opus: 'opus'
  })[container] || 'bin';

  const emitBrowserObject = (kind, objectId, mime, byteLength, container, source) => {
    if (sequence >= MAX_SIGNALS || typeof objectId !== 'string') return;
    const pageUrl = absoluteHttpUrl(currentFrameURL());
    if (!pageUrl) return;
    const key = `${kind}\n${objectId}\n${container}\n${mime}`;
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
        url: pageUrl,
        pageUrl,
        source: text(source, 80),
        mime: text(mime, 160),
        title: text(document.title, 512),
        objectId,
        byteLength,
        container
      });
    } catch (_) { }
  };

  const inspectBrowserBlob = async (objectId, blob, mime, byteLength) => {
    try {
      if (typeof safeBlobSlice !== 'function' || typeof safeBlobArrayBuffer !== 'function') return;
      const prefixBlob = safeReflectApply(
        safeBlobSlice,
        blob,
        [0, Math.min(byteLength, MAX_SNIFF_BYTES)]);
      const buffer = await safeReflectApply(safeBlobArrayBuffer, prefixBlob, []);
      const container = classifyMediaPrefix(buffer, mime);
      if (container !== 'unknown') {
        const entry = browserObjects.get(objectId);
        if (entry) entry.container = container;
        emitBrowserObject('browser-blob', objectId, mime, byteLength, container, 'createObjectURL');
      }
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
    if (typeof safeCreateObjectURL === 'function') {
      SafeURL.createObjectURL = function(object) {
        const objectUrl = safeReflectApply(safeCreateObjectURL, this, [object]);
        let blobSize;
        let blobType = '';
        try {
          if (typeof safeBlobSizeGetter === 'function' && typeof safeBlobTypeGetter === 'function') {
            blobSize = safeReflectApply(safeBlobSizeGetter, object, []);
            blobType = safeReflectApply(safeBlobTypeGetter, object, []);
          }
        } catch (_) { }

        if (documentObjectPrefix
            && Number.isSafeInteger(blobSize) && blobSize > 0 && blobSize <= MAX_BROWSER_BLOB_BYTES
            && browserObjects.size < MAX_BROWSER_OBJECTS) {
          const objectId = `blob-${documentObjectPrefix}-${++browserObjectSequence}`;
          browserObjects.set(objectId, {
            kind: 'blob',
            object: typeof SafeWeakRef === 'function' ? new SafeWeakRef(object) : null,
            objectUrl,
            mime: safeString(blobType || ''),
            byteLength: blobSize,
            container: containerFromMime(blobType),
            revoked: false
          });
          browserObjectUrls.set(objectUrl, objectId);
          void inspectBrowserBlob(objectId, object, blobType, blobSize);
        } else if (documentObjectPrefix
                   && SafeMediaSource && typeof safeMediaSourceAddSourceBuffer === 'function'
                   && object instanceof SafeMediaSource) {
          if (browserObjects.size < MAX_BROWSER_OBJECTS) {
            const objectId = `mse-${documentObjectPrefix}-${++browserObjectSequence}`;
            browserObjects.set(objectId, {
              kind: 'media-source', objectUrl, mime: '', container: 'unknown', revoked: false
            });
            browserObjectUrls.set(objectUrl, objectId);
            mediaSourceIds.set(object, objectId);
            emitBrowserObject('media-source', objectId, '', null, 'unknown', 'createObjectURL');
          }
        }
        return objectUrl;
      };
    }

    if (typeof safeRevokeObjectURL === 'function') {
      SafeURL.revokeObjectURL = function(objectUrl) {
        const normalized = safeString(objectUrl || '');
        const objectId = browserObjectUrls.get(normalized);
        if (objectId) {
          const entry = browserObjects.get(objectId);
          if (entry) entry.revoked = true;
          browserObjectUrls.delete(normalized);
        }
        return safeReflectApply(safeRevokeObjectURL, this, [objectUrl]);
      };
    }
  } catch (_) { }

  try {
    if (SafeMediaSource && typeof safeMediaSourceAddSourceBuffer === 'function') {
      SafeMediaSource.prototype.addSourceBuffer = function(mime) {
        const sourceBuffer = safeReflectApply(safeMediaSourceAddSourceBuffer, this, [mime]);
        const objectId = mediaSourceIds.get(this);
        if (objectId) {
          const normalizedMime = safeString(mime || '').slice(0, 160);
          const container = containerFromMime(normalizedMime);
          const entry = browserObjects.get(objectId);
          if (entry) {
            entry.mime = normalizedMime;
            entry.container = container;
          }
          emitBrowserObject('media-source', objectId, normalizedMime, null, container, 'addSourceBuffer');
        }
        return sourceBuffer;
      };
    }
  } catch (_) { }

  try {
    globalThis.chrome?.webview?.addEventListener?.('message', event => {
      try {
        if (event?.isTrusted !== true) return;
        const command = event.data;
        if (!command || command.channel !== CHANNEL || command.nonce !== NONCE
            || command.command !== 'download-browser-blob'
            || typeof command.objectId !== 'string'
            || typeof command.downloadToken !== 'string'
            || !/^[A-Za-z0-9_-]{16,96}$/.test(command.downloadToken)) return;
        const entry = browserObjects.get(command.objectId);
        if (!entry || entry.kind !== 'blob') return;
        let objectUrl = entry.revoked ? '' : entry.objectUrl;
        if (!objectUrl) {
          const object = typeof entry.object?.deref === 'function'
            ? entry.object.deref()
            : entry.object;
          if (!object || typeof safeCreateObjectURL !== 'function') return;
          objectUrl = safeReflectApply(safeCreateObjectURL, SafeURL, [object]);
        }
        const anchor = document.createElement('a');
        anchor.href = objectUrl;
        anchor.download = `hls-downloader-${command.downloadToken}.${extensionForContainer(entry.container)}`;
        anchor.style.display = 'none';
        (document.documentElement || document.body)?.appendChild(anchor);
        anchor.click();
        anchor.remove();
        if (entry.revoked && typeof safeRevokeObjectURL === 'function') {
          globalThis.setTimeout?.(() => {
            try { safeReflectApply(safeRevokeObjectURL, SafeURL, [objectUrl]); } catch (_) { }
          }, 30_000);
        }
      } catch (_) { }
    });
  } catch (_) { }

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
        const accessPromise = safeReflectApply(
          originalRequest,
          this,
          [normalizedKeySystem, ...configurations]);
        if (!safeReflectApply(safeIncludes, loweredKeySystem, ['widevine'])) {
          return accessPromise;
        }
        return safeReflectApply(safePromiseThen, accessPromise, [access => {
          widevineAccessGranted = true;
          return access;
        }]);
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

  try {
    if (mediaKeySessionPrototype
        && typeof originalGenerateRequest === 'function'
        && typeof originalUpdate === 'function') {
      const canSignalWidevineLifecycle = () => widevineAccessGranted
        && isDownloadableWidevineURL(currentFrameURL())
        && allowedWidevineManifestObserved
        && !disallowedWidevineManifestObserved;
      const signalLifecycle = phase => emit(
        'eme-lifecycle',
        currentFrameURL(),
        'media-key-session',
        { keySystem: 'com.widevine.alpha', phase });

      const observedGenerateRequest = function() {
        const shouldSignal = canSignalWidevineLifecycle();
        if (shouldSignal) signalLifecycle('generate-request-started');
        const operation = safeReflectApply(originalGenerateRequest, this, arguments);
        if (!shouldSignal) return operation;
        return safeReflectApply(safePromiseThen, operation, [value => {
          signalLifecycle('generate-request-succeeded');
          return value;
        }]);
      };

      const observedUpdate = function() {
        const shouldSignal = canSignalWidevineLifecycle();
        const operation = safeReflectApply(originalUpdate, this, arguments);
        if (!shouldSignal) return operation;
        return safeReflectApply(safePromiseThen, operation, [value => {
          signalLifecycle('update-succeeded');
          return value;
        }]);
      };

      Object.defineProperty(mediaKeySessionPrototype, 'generateRequest', {
        value: observedGenerateRequest,
        enumerable: originalGenerateRequestDescriptor?.enumerable === true,
        configurable: originalGenerateRequestDescriptor?.configurable === true,
        writable: originalGenerateRequestDescriptor?.writable === true
      });
      Object.defineProperty(mediaKeySessionPrototype, 'update', {
        value: observedUpdate,
        enumerable: originalUpdateDescriptor?.enumerable === true,
        configurable: originalUpdateDescriptor?.configurable === true,
        writable: originalUpdateDescriptor?.writable === true
      });
    }
  } catch (_) {
    // Lifecycle hints are optional and never weaken the native allowlist gate.
  }
})();
""";
}
