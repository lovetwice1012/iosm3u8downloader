using System.Text.Json;

namespace HLSDownloader.WebProbe;

public static class WebProbeScript
{
    public static string CreateDocumentStartScript(string nonce)
    {
        if (string.IsNullOrWhiteSpace(nonce) || nonce.Length > 256)
        {
            throw new ArgumentException("A valid probe nonce is required.", nameof(nonce));
        }

        return ScriptTemplate.Replace("__NONCE_JSON__", JsonSerializer.Serialize(nonce), StringComparison.Ordinal);
    }

    private const string ScriptTemplate = """
(() => {
  'use strict';
  if (globalThis.__hlsDownloaderProbeInstalled === true) return;
  Object.defineProperty(globalThis, '__hlsDownloaderProbeInstalled', { value: true });

  const CHANNEL = 'hls-downloader-probe';
  const NONCE = __NONCE_JSON__;
  const MAX_SIGNALS = 4000;
  const seen = new Set();
  let sequence = 0;

  // Capture the EME guard's security-sensitive intrinsics before page scripts
  // can replace globals or prototype methods. The guarded function below must
  // not consult mutable page-world helpers when it makes its allow/deny choice.
  const safeString = globalThis.String;
  const safeToLowerCase = globalThis.String.prototype.toLowerCase;
  const safeIncludes = globalThis.String.prototype.includes;
  const safeReflectApply = globalThis.Reflect.apply;
  const SafeDOMException = globalThis.DOMException;
  const SafeTypeError = globalThis.TypeError;
  const SafePromise = globalThis.Promise;
  const safePromiseReject = SafePromise.reject.bind(SafePromise);
  const safeLocation = globalThis.location;
  const safeWidevinePolicy = globalThis.chrome?.webview?.hostObjects?.sync?.widevinePolicy;
  const safeIsWidevinePlaybackAllowed = safeWidevinePolicy?.IsWidevinePlaybackAllowed;

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
        return Reflect.apply(originalFetch, this, arguments);
      };
    }
  } catch (_) { }

  try {
    const originalOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url) {
      emit('network', url, 'xhr');
      return Reflect.apply(originalOpen, this, arguments);
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
          let allowed = false;
          try {
            allowed = typeof safeIsWidevinePlaybackAllowed === 'function'
              && safeReflectApply(
                safeIsWidevinePlaybackAllowed,
                safeWidevinePolicy,
                [safeLocation.href]) === true;
          } catch (_) { }
          if (!allowed) {
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
