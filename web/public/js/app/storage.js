// Where the web app keeps its boards: IndexedDB, one record per key
// ("settings", "board:<id>"). Boards can reach a couple of MB each
// (1,000 notes of up to 2 KB), past what localStorage allows. When IndexedDB
// isn't available (some private windows), everything lives in memory and the
// app says so.

const DB = "corkboard";
const STORE = "kv";

function promised(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export class MemoryStorage {
  constructor() {
    this.data = new Map();
    this.persistent = false;
  }

  async get(key) {
    const value = this.data.get(key);
    return value === undefined ? undefined : structuredClone(value);
  }

  async set(key, value) {
    this.data.set(key, structuredClone(value));
  }

  async delete(key) {
    this.data.delete(key);
  }

  async keys() {
    return [...this.data.keys()];
  }
}

export class IdbStorage {
  constructor(db) {
    this.db = db;
    this.persistent = true;
  }

  static async open() {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    return new IdbStorage(await promised(request));
  }

  tx(mode) {
    return this.db.transaction(STORE, mode).objectStore(STORE);
  }

  get(key) {
    return promised(this.tx("readonly").get(key));
  }

  set(key, value) {
    return promised(this.tx("readwrite").put(value, key));
  }

  delete(key) {
    return promised(this.tx("readwrite").delete(key));
  }

  keys() {
    return promised(this.tx("readonly").getAllKeys());
  }
}

export async function openStorage() {
  try {
    if (typeof indexedDB === "undefined") throw new Error("no IndexedDB");
    const storage = await IdbStorage.open();
    // Ask the browser not to evict the boards under storage pressure.
    navigator.storage?.persist?.().catch(() => {});
    return storage;
  } catch {
    return new MemoryStorage();
  }
}
