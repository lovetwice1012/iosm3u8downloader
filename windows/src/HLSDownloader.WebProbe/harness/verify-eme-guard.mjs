import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const directory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.resolve(directory, '..', 'WebProbeScript.cs');
const source = fs.readFileSync(sourcePath, 'utf8');
const match = source.match(/private const string ScriptTemplate = """\r?\n([\s\S]*?)\r?\n""";/);
assert.ok(match, 'WebProbeScript raw template was not found.');
const script = match[1]
  .replace('__NONCE_JSON__', JSON.stringify('harness-nonce'))
  .replace(
    '__ALLOWED_WIDEVINE_HOSTS_JSON__',
    JSON.stringify(['widevine.sprink.cloud']));

let originalCalls = 0;
class Navigator {
  requestMediaKeySystemAccess(keySystem) {
    originalCalls += 1;
    return Promise.resolve(`original:${keySystem}`);
  }
}

class MediaKeySession {
  generateRequest() {
    return Promise.resolve(undefined);
  }

  update() {
    return Promise.resolve(undefined);
  }
}

const navigator = new Navigator();
const messages = [];
const document = {
  baseURI: 'https://example.com/player',
  title: 'Harness',
  readyState: 'loading',
  addEventListener() { }
};
class HarnessHeaders {
  constructor(mime) { this.mime = mime; }
  get(name) {
    return String(name).toLowerCase() === 'content-type' ? this.mime : null;
  }
}
class HarnessResponse {
  constructor(url, status, mime) {
    this.responseUrl = String(url);
    this.status = status;
    this.responseHeaders = new HarnessHeaders(mime);
  }
  get ok() { return this.status >= 200 && this.status < 300; }
  get url() { return this.responseUrl; }
  get headers() { return this.responseHeaders; }
}
class HarnessLocation {
  constructor(href) {
    this.locationHref = String(href);
    Object.defineProperty(this, 'href', {
      configurable: false,
      enumerable: true,
      get: () => this.locationHref
    });
  }
}
class HarnessMediaSource {
  addSourceBuffer(mime) { return { mime }; }
}
let objectUrlSequence = 0;
URL.createObjectURL = () => `blob:https://example.com/${++objectUrlSequence}`;
URL.revokeObjectURL = () => { };
const hostMessageListeners = [];
const nativeFetch = input => Promise.resolve(
  new HarnessResponse(input, 200, 'application/dash+xml'));
const location = new HarnessLocation('https://example.com/player');
const context = vm.createContext({
  Navigator,
  navigator,
  MediaKeySession,
  document,
  location,
  chrome: {
    webview: {
      postMessage(message) { messages.push(message); },
      addEventListener(kind, listener) {
        if (kind === 'message') hostMessageListeners.push(listener);
      }
    }
  },
  fetch: nativeFetch,
  Headers: HarnessHeaders,
  Response: HarnessResponse,
  XMLHttpRequest: class XMLHttpRequest { open() { } },
  performance: { getEntriesByType() { return []; } },
  URL,
  Blob,
  MediaSource: HarnessMediaSource,
  TextDecoder,
  ArrayBuffer,
  Uint8Array,
  Map,
  WeakMap,
  WeakRef,
  crypto: globalThis.crypto,
  setTimeout,
  DOMException
});

const harnessCreateObjectUrl = URL.createObjectURL;
vm.runInContext(script, context, { filename: 'WebProbeScript.generated.js' });
assert.notEqual(context.URL.createObjectURL, harnessCreateObjectUrl);

const hlsBlob = new context.Blob([
  '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nhttps://example.com/one.ts\n'
], { type: 'application/octet-stream' });
assert.ok(hlsBlob.size > 0);
const hlsBlobUrl = context.URL.createObjectURL(hlsBlob);
assert.match(hlsBlobUrl, /^blob:/);
await new Promise(resolve => setTimeout(resolve, 50));
const blobMessage = messages.find(message => message.kind === 'browser-blob');
assert.ok(blobMessage, 'Browser Blob signal was not emitted.');
assert.equal(blobMessage.container, 'hls');
assert.equal(blobMessage.mime, 'application/octet-stream');
assert.equal(blobMessage.url, 'https://example.com/player');
assert.match(blobMessage.objectId, /^blob-[0-9a-f]{32}-[0-9]+$/);
assert.equal('blobUrl' in blobMessage, false);
assert.equal('data' in blobMessage, false);

const browserBlobSignalsBeforeSpoof = messages.filter(
  message => message.kind === 'browser-blob').length;
context.URL.createObjectURL(new context.Blob(['<html>not media</html>'], { type: 'video/mp4' }));
await new Promise(resolve => setTimeout(resolve, 50));
assert.equal(
  messages.filter(message => message.kind === 'browser-blob').length,
  browserBlobSignalsBeforeSpoof,
  'A MIME-only Blob must not be accepted without supported media magic.');

const mediaSource = new context.MediaSource();
const mediaSourceUrl = context.URL.createObjectURL(mediaSource);
assert.match(mediaSourceUrl, /^blob:/);
mediaSource.addSourceBuffer('video/webm; codecs="vp9,opus"');
const mediaSourceMessage = messages.find(
  message => message.kind === 'media-source' && message.container === 'webm');
assert.ok(mediaSourceMessage, 'MediaSource signal was not emitted.');
assert.equal(mediaSourceMessage.byteLength, null);

const prototypeDescriptor = Object.getOwnPropertyDescriptor(
  Navigator.prototype,
  'requestMediaKeySystemAccess');
const instanceDescriptor = Object.getOwnPropertyDescriptor(
  navigator,
  'requestMediaKeySystemAccess');
assert.equal(prototypeDescriptor.configurable, false);
assert.equal(prototypeDescriptor.writable, false);
assert.equal(instanceDescriptor.configurable, false);
assert.equal(instanceDescriptor.writable, false);

await assert.rejects(
  Navigator.prototype.requestMediaKeySystemAccess.call(navigator, 'com.widevine.alpha'),
  error => error?.name === 'NotAllowedError');
await assert.rejects(
  navigator.requestMediaKeySystemAccess('com.widevine.alpha'),
  error => error?.name === 'NotAllowedError');
let coercions = 0;
await assert.rejects(
  navigator.requestMediaKeySystemAccess({
    toString() {
      coercions += 1;
      return coercions === 1 ? 'com.apple.fps' : 'com.widevine.alpha';
    }
  }),
  error => error?.name === 'TypeError');
assert.equal(coercions, 0);
assert.equal(originalCalls, 0);
assert.equal(Reflect.deleteProperty(navigator, 'requestMediaKeySystemAccess'), false);
assert.equal(Reflect.set(navigator, 'requestMediaKeySystemAccess', () => Promise.resolve()), false);
assert.throws(() => Object.defineProperty(navigator, 'requestMediaKeySystemAccess', {
  value: () => Promise.resolve()
}), TypeError);

assert.equal(await navigator.requestMediaKeySystemAccess('com.apple.fps'), 'original:com.apple.fps');
vm.runInContext(`
  String.prototype.toLowerCase = () => 'com.apple.fps';
  String.prototype.includes = () => false;
  String = () => 'com.apple.fps';
  Reflect.apply = () => Promise.resolve('bypassed');
  Promise.reject = () => Promise.resolve('bypassed');
  Headers.prototype.get = () => 'text/html';
  Object.defineProperty(Response.prototype, 'ok', { get: () => false });
  Object.defineProperty(Response.prototype, 'url', {
    get: () => 'https://example.com/bypassed.mpd'
  });
  Object.defineProperty(Response.prototype, 'headers', {
    get: () => new Headers('text/html')
  });
  URL = class URL {};
`, context);
await assert.rejects(
  navigator.requestMediaKeySystemAccess('com.widevine.alpha'),
  error => error?.name === 'NotAllowedError');
assert.equal(originalCalls, 1);

await context.fetch('https://widevine.sprink.cloud/video/manifest.mpd');
await assert.rejects(
  Navigator.prototype.requestMediaKeySystemAccess.call(navigator, 'com.widevine.alpha'),
  error => error?.name === 'NotAllowedError');
assert.equal(originalCalls, 1);

location.locationHref = 'https://widevine.sprink.cloud/player';
assert.equal(
  await Navigator.prototype.requestMediaKeySystemAccess.call(navigator, 'com.widevine.alpha'),
  'original:com.widevine.alpha');
assert.equal(originalCalls, 2);

const mediaKeySession = new MediaKeySession();
await mediaKeySession.generateRequest('cenc', new Uint8Array([1, 2, 3, 4]));
await context.fetch('https://widevine.sprink.cloud/license?token=not-for-the-bridge', {
  method: 'POST',
  body: new Uint8Array([5, 6, 7, 8])
});
await mediaKeySession.update(new Uint8Array([9, 10, 11, 12]));

const lifecycleMessages = messages.filter(message => message.kind === 'eme-lifecycle');
assert.deepEqual(
  lifecycleMessages.map(message => message.phase),
  ['generate-request-started', 'generate-request-succeeded', 'update-succeeded']);
for (const message of lifecycleMessages) {
  assert.equal(message.keySystem, 'com.widevine.alpha');
  assert.equal(message.url, 'https://widevine.sprink.cloud/player');
  assert.equal('body' in message, false);
  assert.equal('headers' in message, false);
  assert.equal('initData' in message, false);
  assert.equal('response' in message, false);
}

await context.fetch('https://example.com/video/manifest.mpd');
await assert.rejects(
  navigator.requestMediaKeySystemAccess('com.widevine.alpha'),
  error => error?.name === 'NotAllowedError');
assert.equal(originalCalls, 2);
assert.ok(messages.some(message => message.source === 'requestMediaKeySystemAccess'));

console.log('EME guard harness passed.');
