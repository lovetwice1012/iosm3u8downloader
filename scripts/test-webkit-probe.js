'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const swift = fs.readFileSync('HLSDownloader/HLS/WebPageInspector.swift', 'utf8');
const template = swift.match(/probeJavaScriptTemplate = #"""([\s\S]*?)"""#/);
assert(template, 'WebKit probe template was not found');

async function runProbe() {
  const messages = [];
  const blobMessages = [];
  const nonce = '0123456789abcdef0123456789abcdef';
  const listeners = new Map();

  class MockMediaKeySession {
    addEventListener(name, callback) {
      listeners.set(name, callback);
    }

    generateRequest() {
      return Promise.resolve();
    }
  }

  class MockXMLHttpRequest {
    addEventListener() {}
    open() {}
    setRequestHeader() {}
    send() {}
    getResponseHeader() { return ''; }
  }

  class MockMediaSource {
    addSourceBuffer() { return {}; }
  }

  class MockURL extends URL {
    static createObjectURL() {
      return `blob:https://widevine.sprink.cloud/${Math.random().toString(36).slice(2)}`;
    }

    static revokeObjectURL() {}
  }

  const headers = new Headers();
  const response = {
    url: '',
    headers,
    clone() { return { body: null, headers }; }
  };
  const document = {
    baseURI: 'https://widevine.sprink.cloud/watch',
    title: 'Fixture',
    readyState: 'complete',
    documentElement: {},
    querySelector() { return null; },
    querySelectorAll() { return []; },
    addEventListener() {}
  };
  const context = {
    ArrayBuffer,
    Blob,
    FormData,
    Headers,
    MediaKeySession: MockMediaKeySession,
    MediaSource: MockMediaSource,
    MutationObserver: class { observe() {} },
    PerformanceObserver: class { observe() {} },
    Request,
    TextDecoder,
    TextEncoder,
    URL: MockURL,
    URLSearchParams,
    Uint8Array,
    XMLHttpRequest: MockXMLHttpRequest,
    btoa,
    crypto: { randomUUID: () => 'fixture-frame-token' },
    document,
    fetch: async value => ({ ...response, url: String(value) }),
    location: { href: document.baseURI },
    navigator: {
      requestMediaKeySystemAccess: async () => ({})
    },
    performance: { getEntriesByType: () => [] },
    setInterval() { return 1; },
    setTimeout(callback) { callback(); return 1; },
    webkit: {
      messageHandlers: {
        hlsDiscovery: {
          postMessage(message) { messages.push(message); }
        },
        hlsBlobExport: {
          async postMessage(message) {
            blobMessages.push(message);
            return true;
          }
        }
      }
    }
  };
  context.window = context;
  context.self = context;

  const script = template[1]
    .replaceAll('__HLS_DOWNLOADER_INTERACTIVE__', 'true')
    .replaceAll('__HLS_DOWNLOADER_MESSAGE_NONCE__', nonce);
  vm.runInNewContext(script, context, { timeout: 2_000 });

  const mp4Bytes = Uint8Array.from([
    0x00, 0x00, 0x00, 0x10,
    0x66, 0x74, 0x79, 0x70,
    0x69, 0x73, 0x6f, 0x6d,
    0x30, 0x30, 0x30, 0x30
  ]);
  const capturedURL = context.URL.createObjectURL(
    new Blob([mp4Bytes], { type: 'video/mp4' })
  );
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (blobMessages.some(message => message.eventKind === 'blobFinish')) break;
    await new Promise(resolve => setImmediate(resolve));
  }
  const blobStart = blobMessages.find(message => message.eventKind === 'blobStart');
  const blobChunk = blobMessages.find(message => message.eventKind === 'blobChunk');
  const blobFinish = blobMessages.find(message => message.eventKind === 'blobFinish');
  assert(blobStart, 'complete Blob capture did not start');
  assert(blobChunk, 'complete Blob capture did not stream a chunk');
  assert(blobFinish, 'complete Blob capture did not finish');
  assert.equal(blobStart.url, capturedURL);
  assert.equal(blobStart.size, mp4Bytes.byteLength);
  assert.equal(blobChunk.offset, 0);
  assert.equal(Buffer.from(blobChunk.data, 'base64').byteLength, mp4Bytes.byteLength);
  assert(blobMessages.every(message => message.nonce === nonce));
  assert(!messages.some(message => Object.hasOwn(message, 'data')));

  const mediaSource = new context.MediaSource();
  context.URL.createObjectURL(mediaSource);
  mediaSource.addSourceBuffer('video/mp4; codecs="avc1.42E01E"');
  assert.equal(
    messages.filter(message => message.eventKind === 'mediaSource').length,
    1,
    'MSE must be signaled once without exporting SourceBuffer bytes'
  );

  await context.fetch('https://widevine.sprink.cloud/video/manifest.mpd');
  await context.navigator.requestMediaKeySystemAccess('com.widevine.alpha', []);
  const session = new context.MediaKeySession();
  await session.generateRequest('cenc', new Uint8Array([1]).buffer);
  const challenge = new Uint8Array([10, 20, 30, 40]);
  listeners.get('message')({ message: challenge.buffer });

  const beforeAnalytics = messages.length;
  await context.fetch('https://telemetry.example/collect', {
    method: 'POST',
    body: new Uint8Array([99, 98, 97])
  });
  assert.equal(
    messages.slice(beforeAnalytics).filter(message => message.eventKind === 'licenseRequest').length,
    0,
    'an unrelated POST must not become an EME-correlated license request'
  );

  await context.fetch('https://license.example/opaque-endpoint', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer secret-must-not-cross',
      'Content-Type': 'application/octet-stream'
    },
    body: challenge
  });
  const rawLicense = messages.find(
    message => message.eventKind === 'licenseRequest'
      && message.source === 'emeCorrelatedFetch'
  );
  assert(rawLicense, 'matching raw challenge was not detected');
  assert.equal(rawLicense.nonce, nonce);
  assert.deepEqual(Array.from(rawLicense.headerNames), ['authorization', 'content-type']);
  assert.equal(rawLicense.bodyKind, 'binary');
  assert(!Object.hasOwn(rawLicense, 'body'));
  assert(!Object.hasOwn(rawLicense, 'headerValues'));
  assert(!JSON.stringify(rawLicense).includes('secret-must-not-cross'));

  const encoded = Buffer.from(challenge).toString('base64');
  await context.fetch('https://license.example/json-endpoint', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ challenge: encoded })
  });
  const jsonLicense = messages.find(
    message => message.eventKind === 'licenseRequest'
      && message.url.endsWith('/json-endpoint')
  );
  assert(jsonLicense, 'base64-wrapped challenge was not detected');
  assert.equal(jsonLicense.source, 'emeCorrelatedFetch');
  assert.equal(jsonLicense.bodyKind, 'json');

  await context.fetch('https://license.example/form-endpoint', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ challenge: encoded })
  });
  const formLicense = messages.find(
    message => message.eventKind === 'licenseRequest'
      && message.url.endsWith('/form-endpoint')
  );
  assert(formLicense, 'form-wrapped challenge was not detected');
  assert.equal(formLicense.source, 'emeCorrelatedFetch');
  assert.equal(formLicense.bodyKind, 'formURLEncoded');

  assert(messages.some(message => message.eventKind === 'widevineEME'));
  assert(messages.every(message => message.nonce === nonce));
}

runProbe()
  .then(() => console.log('WebKit probe behavior OK'))
  .catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
