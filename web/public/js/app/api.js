// The sync API client (docs/design.md §7.3). The app is served from the same
// host as the API, so paths are relative and no CORS is involved.

export class ApiError extends Error {
  constructor(status, error, retryAfter) {
    super(`${status} ${error}`);
    this.status = status;
    this.error = error;
    this.retryAfter = retryAfter;
  }
}

const TIMEOUT = 20000;

export class Api {
  constructor({ base = "", fetch: fetchImpl = globalThis.fetch.bind(globalThis) } = {}) {
    this.base = base;
    this.fetch = fetchImpl;
  }

  async request(method, path, body, token) {
    const headers = { "Content-Type": "application/json" };
    if (token) headers.Authorization = `Bearer ${token}`;
    const controller = typeof AbortController === "undefined" ? null : new AbortController();
    const timer = controller ? setTimeout(() => controller.abort(), TIMEOUT) : null;
    let response;
    try {
      response = await this.fetch(`${this.base}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller?.signal,
        cache: "no-store",
      });
    } catch {
      throw new ApiError(0, "offline");
    } finally {
      if (timer) clearTimeout(timer);
    }
    let data = null;
    try {
      data = await response.json();
    } catch {
      data = null;
    }
    if (!response.ok) {
      const retry = Number(response.headers.get("Retry-After")) || null;
      throw new ApiError(response.status, (data && data.error) || "http", retry);
    }
    return data;
  }

  sync(board, body) {
    return this.request("POST", `/v1/boards/${board.id}/sync`, body, `${board.id}.${board.secret}`);
  }

  register(board) {
    return this.request("POST", "/v1/boards", { id: board.id, secret: board.secret });
  }
}
