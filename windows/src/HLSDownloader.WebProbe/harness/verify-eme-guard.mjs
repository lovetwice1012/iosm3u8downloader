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
const script = match[1].replace('__NONCE_JSON__', JSON.stringify('harness-nonce'));

let widevineAllowed = false;
let originalCalls = 0;
class Navigator {
  requestMediaKeySystemAccess(keySystem) {
    originalCalls += 1;
    return Promise.resolve(`original:${keySystem}`);
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
const context = vm.createContext({
  Navigator,
  navigator,
  document,
  location: { href: 'https://example.com/player' },
  chrome: {
    webview: {
      postMessage(message) { messages.push(message); },
      hostObjects: {
        sync: {
          widevinePolicy: {
            IsWidevinePlaybackAllowed() { return widevineAllowed; }
          }
        }
      }
    }
  },
  XMLHttpRequest: class XMLHttpRequest { open() { } },
  performance: { getEntriesByType() { return []; } },
  URL,
  DOMException
});

vm.runInContext(script, context, { filename: 'WebProbeScript.generated.js' });

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
  chrome.webview.hostObjects.sync.widevinePolicy.IsWidevinePlaybackAllowed = () => true;
`, context);
await assert.rejects(
  navigator.requestMediaKeySystemAccess('com.widevine.alpha'),
  error => error?.name === 'NotAllowedError');
assert.equal(originalCalls, 1);
widevineAllowed = true;
assert.equal(
  await Navigator.prototype.requestMediaKeySystemAccess.call(navigator, 'com.widevine.alpha'),
  'original:com.widevine.alpha');
assert.equal(originalCalls, 2);
assert.ok(messages.some(message => message.source === 'requestMediaKeySystemAccess'));

console.log('EME guard harness passed.');
