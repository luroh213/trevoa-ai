import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function memoryStorage() {
  const map = new Map();
  return {
    getItem: (k) => (map.has(String(k)) ? map.get(String(k)) : null),
    setItem: (k, v) => { map.set(String(k), String(v)); },
    removeItem: (k) => { map.delete(String(k)); },
    clear: () => { map.clear(); },
    key: (i) => [...map.keys()][i] || null,
    get length() { return map.size; },
  };
}

function el() {
  const node = {
    hidden: false,
    innerHTML: "",
    textContent: "",
    value: "",
    className: "",
    disabled: false,
    checked: false,
    style: {},
    dataset: {},
    classList: {
      toggle() {},
      add() {},
      remove() {},
      contains() { return false; },
    },
    addEventListener() {},
    removeEventListener() {},
    querySelector() { return el(); },
    querySelectorAll() { return []; },
    closest() { return null; },
    insertAdjacentElement() {},
    scrollIntoView() {},
    appendChild() {},
    remove() {},
  };
  return node;
}

export function loadApp() {
  const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
  const start = html.indexOf("/* ═══════════════════════ ESTADO");
  const end = html.lastIndexOf("</script>");
  if (start < 0 || end < 0) throw new Error("script do Nossa Casa não encontrado");
  const scriptOpen = html.lastIndexOf("<script>", start);
  const src = html.slice(scriptOpen + "<script>".length, end);

  const localStorage = memoryStorage();
  const sessionStorage = memoryStorage();
  const dummy = el();

  const document = {
    hidden: false,
    body: dummy,
    documentElement: dummy,
    getElementById: () => el(),
    querySelector: () => el(),
    querySelectorAll: () => [],
    createElement: () => el(),
    addEventListener() {},
    removeEventListener() {},
  };

  const sandbox = {
    NC_TEST: true,
    NC_AI: { enabled: false, apiKey: "", provider: "groq" },
    NC_CLOUD: { enabled: false },
    NCCloud: {
      configured: () => false,
      getMeta: () => ({}),
      getToken: () => "",
      carregar: async () => ({}),
      login: async () => ({ ok: false }),
    },
    localStorage,
    sessionStorage,
    document,
    navigator: { serviceWorker: undefined, onLine: true },
    location: { protocol: "https:", href: "https://example.test/nossacasa/", pathname: "/nossacasa/" },
    crypto: globalThis.crypto,
    fetch: async () => ({ ok: false, status: 0, json: async () => ({}) }),
    alert() {},
    confirm: () => true,
    scrollTo() {},
    setTimeout: globalThis.setTimeout.bind(globalThis),
    clearTimeout: globalThis.clearTimeout.bind(globalThis),
    addEventListener() {},
    Notification: undefined,
    console,
    Date,
    Math,
    JSON,
    Number,
    String,
    Boolean,
    Array,
    Object,
    Error,
    TypeError,
    RangeError,
    SyntaxError,
    RegExp,
    Map,
    Set,
    WeakMap,
    Promise,
    parseInt,
    parseFloat,
    isNaN,
    isFinite,
    Infinity,
    NaN,
    undefined,
    Intl,
    URL,
    encodeURIComponent,
    decodeURIComponent,
    encodeURI,
    decodeURI,
    Uint8Array,
    ArrayBuffer,
    Float64Array,
    TextEncoder,
    TextDecoder,
    Symbol,
    Reflect,
    Proxy,
    Function,
    parseURI: undefined,
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;

  const ctx = vm.createContext(sandbox);
  vm.runInContext(src, ctx, { filename: "nossacasa/index.html" });
  if (!ctx.__NC__) throw new Error("__NC__ não exportou — NC_TEST falhou");
  return ctx.__NC__;
}
