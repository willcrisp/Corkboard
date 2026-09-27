// The web app's boards (docs/design.md §7.4): joined from an invite, kept in
// the browser, changed with the merge core, and synced with the API's
// /v1/boards/{id}/sync, the same route the desktop companion uses.
//
// A board here has the addon's replicated fields (clock, notes, members,
// meta) plus local ones that never leave the device:
//   cursor   the API sequence number reached
//   pending  { notes: { id: rev }, meta: rev }: local changes not yet accepted
//   sync     { at, state, error, rejected }: the last sync's outcome

import * as merge from "../core/merge.js";
import * as invite from "../core/invite.js";
import { byteLen } from "../core/util.js";
import { encodePlayer, PLAYER_KIND } from "../model/formats.js";
import { newPrefix, nextNoteId, webName } from "../model/view.js";
import { ApiError } from "./api.js";

const BATCH_BYTES = 48000; // records per request, under the API's 64 KB body limit
const MAX_PAGES = 20; // pages pulled in one sync; the next sync carries on

function now() {
  return Math.floor(Date.now() / 1000);
}

function newBoard(inv, at) {
  return {
    id: inv.id,
    secret: inv.secret,
    owner: inv.owner,
    joined: at,
    clock: 0,
    notes: {},
    members: {},
    meta: null,
    cursor: 0,
    pending: { notes: {}, meta: null },
    sync: { at: null, state: "new", error: null, rejected: 0 },
  };
}

export class Boards {
  constructor({ storage, api, clock = now, random = Math.random }) {
    this.storage = storage;
    this.api = api;
    this.clock = clock;
    this.random = random;
    this.settings = null;
    this.boards = new Map();
    this.listeners = new Set();
    this.running = new Map();
    this.again = new Set();
  }

  async load() {
    this.settings = (await this.storage.get("settings")) || {};
    if (!this.settings.prefix) {
      this.settings.prefix = newPrefix(this.random);
      await this.saveSettings();
    }
    for (const key of await this.storage.keys()) {
      if (typeof key === "string" && key.startsWith("board:")) {
        const board = await this.storage.get(key);
        if (board && invite.validId(board.id)) this.boards.set(board.id, board);
      }
    }
    if (this.settings.current && !this.boards.has(this.settings.current)) this.settings.current = null;
    return this;
  }

  onChange(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  emit(change) {
    for (const fn of this.listeners) fn(change);
  }

  async saveSettings() {
    await this.storage.set("settings", this.settings);
  }

  async save(board) {
    await this.storage.set(`board:${board.id}`, board);
  }

  // Identity ---------------------------------------------------------------------

  get me() {
    return this.settings.name || null;
  }

  async setName(input) {
    const [name, reason] = webName(input);
    if (!name) return [null, reason];
    this.settings.name = name;
    await this.saveSettings();
    this.emit({ kind: "settings" });
    return [name, null];
  }

  async setSetting(key, value) {
    this.settings[key] = value;
    await this.saveSettings();
  }

  // Boards -----------------------------------------------------------------------

  list() {
    return [...this.boards.values()].sort((a, b) => {
      const an = (a.meta ? a.meta.name : a.id).toLowerCase();
      const bn = (b.meta ? b.meta.name : b.id).toLowerCase();
      return an < bn ? -1 : an > bn ? 1 : 0;
    });
  }

  get(id) {
    return this.boards.get(id) || null;
  }

  get current() {
    return this.get(this.settings.current) || this.list()[0] || null;
  }

  async select(id) {
    this.settings.current = id;
    await this.saveSettings();
    this.emit({ kind: "select", board: id });
  }

  // Joins a board from an invite, or updates the secret of one already held.
  // Returns [board, null] or [null, reason].
  async join(text) {
    const [inv, reason] = invite.decode(text);
    if (!inv) return [null, reason];
    let board = this.boards.get(inv.id);
    if (!board) {
      board = newBoard(inv, this.clock());
      this.boards.set(board.id, board);
    } else {
      // A new secret (after a rotation), or the same invite again: either
      // way it's worth another try if the server refused the last one.
      board.secret = inv.secret;
      if (board.sync.state === "refused") board.sync.state = "new";
      board.sync.error = null;
    }
    await this.save(board);
    await this.select(board.id);
    return [board, null];
  }

  async leave(id) {
    this.boards.delete(id);
    await this.storage.delete(`board:${id}`);
    if (this.settings.current === id) this.settings.current = this.list()[0]?.id || null;
    await this.saveSettings();
    this.emit({ kind: "board", board: id });
  }

  // Local changes --------------------------------------------------------------------

  async changed(board, kind, ids) {
    await this.save(board);
    this.emit({ kind, board: board.id, ids, local: true });
  }

  author() {
    return this.me ? [this.me, null] : [null, "author"];
  }

  async rename(id, name) {
    const board = this.get(id);
    if (!board) return [null, "missing"];
    const [editor, why] = this.author();
    if (!editor) return [null, why];
    name = name.trim();
    if (board.meta && board.meta.name === name) return [board.meta, null];
    const [meta, reason] = merge.setMeta(board, name, editor, this.clock());
    if (!meta) return [null, reason];
    board.pending.meta = meta.rev;
    await this.changed(board, "meta");
    return [meta, null];
  }

  async addNote(id, text, color, kind) {
    const board = this.get(id);
    if (!board) return [null, "missing"];
    const [author, why] = this.author();
    if (!author) return [null, why];
    const [noteId, full] = nextNoteId(board, this.settings.prefix);
    if (!noteId) return [null, full];
    const [note, reason] = merge.createNote(board, { id: noteId, author, text, color, kind }, this.clock());
    if (!note) return [null, reason];
    board.pending.notes[note.id] = note.rev;
    await this.changed(board, "note", [note.id]);
    return [note, null];
  }

  // Edits a note. An unchanged save writes nothing (View.changes), so it
  // doesn't bump the rev and resend the note.
  async editNote(id, noteId, changes) {
    const board = this.get(id);
    if (!board) return [null, "missing"];
    const [editor, why] = this.author();
    if (!editor) return [null, why];
    const held = board.notes[noteId];
    if (held && !held.deleted && (changes.text ?? held.text) === held.text
      && (changes.color ?? held.color) === held.color) {
      return [held, null];
    }
    const [note, reason] = merge.editNote(board, noteId, changes, editor, this.clock());
    if (!note) return [null, reason];
    board.pending.notes[note.id] = note.rev;
    await this.changed(board, "note", [note.id]);
    return [note, null];
  }

  async deleteNote(id, noteId) {
    const board = this.get(id);
    if (!board) return [null, "missing"];
    const [editor, why] = this.author();
    if (!editor) return [null, why];
    const [note, reason] = merge.deleteNote(board, noteId, editor, this.clock());
    if (!note) return [null, reason];
    board.pending.notes[note.id] = note.rev;
    await this.changed(board, "note", [note.id]);
    return [note, null];
  }

  async addPlayer(id, name, verdict, reason) {
    const [text, why] = encodePlayer(name, verdict, reason);
    if (!text) return [null, why];
    return this.addNote(id, text, 1, PLAYER_KIND);
  }

  async editPlayer(id, noteId, name, verdict, reason) {
    const [text, why] = encodePlayer(name, verdict, reason);
    if (!text) return [null, why];
    return this.editNote(id, noteId, { text });
  }

  pendingCount(board) {
    return Object.keys(board.pending.notes).length + (board.pending.meta ? 1 : 0);
  }

  // Sync ----------------------------------------------------------------------------

  // Syncs one board. Concurrent calls share one run, and a call made during a
  // run starts another after it, so a change made meanwhile isn't missed.
  sync(id) {
    if (this.running.has(id)) {
      this.again.add(id);
      return this.running.get(id);
    }
    const run = (async () => {
      try {
        do {
          this.again.delete(id);
          await this.syncOnce(id);
        } while (this.again.has(id) && this.boards.has(id));
      } finally {
        this.running.delete(id);
      }
    })();
    this.running.set(id, run);
    return run;
  }

  async syncOnce(id) {
    const board = this.get(id);
    if (!board) return;
    board.sync.state = "syncing";
    this.emit({ kind: "sync", board: id });
    try {
      await this.exchange(board);
      board.sync.state = "synced";
      board.sync.error = null;
      board.sync.at = this.clock();
    } catch (err) {
      const error = err instanceof ApiError ? err : new ApiError(0, "offline");
      board.sync.state = error.status === 0 ? "offline" : error.error === "refused" ? "refused" : "error";
      board.sync.error = error.error;
      board.sync.retryAfter = error.retryAfter || null;
    }
    if (this.boards.has(id)) await this.save(board);
    this.emit({ kind: "sync", board: id });
  }

  // The records to push, in batches under the request limit.
  batches(board) {
    for (const noteId of Object.keys(board.pending.notes)) {
      if (!board.notes[noteId]) delete board.pending.notes[noteId];
    }
    // The board's current version goes, which may be newer than the local
    // change if a remote edit arrived since: the server just keeps the newer.
    const notes = Object.keys(board.pending.notes).map((noteId) => board.notes[noteId]);
    const batches = [];
    let batch = [];
    let size = 0;
    for (const note of notes) {
      const bytes = byteLen(JSON.stringify(note)) + 1;
      if (batch.length && size + bytes > BATCH_BYTES) {
        batches.push(batch);
        batch = [];
        size = 0;
      }
      batch.push(note);
      size += bytes;
    }
    if (batch.length || board.pending.meta) batches.push(batch);
    return batches;
  }

  async post(board, body) {
    try {
      return await this.api.sync(board, body);
    } catch (err) {
      if (!(err instanceof ApiError) || err.status !== 401) throw err;
      // An unknown board or a wrong secret. Registering tells them apart,
      // as the companion does (§7.1): 201 means the board is new to the
      // server, 409 that it uses another secret.
      try {
        await this.api.register(board);
      } catch (reg) {
        if (reg instanceof ApiError && reg.status === 409) throw new ApiError(401, "refused");
        throw reg;
      }
      return this.api.sync(board, body);
    }
  }

  apply(board, response) {
    const [notes, dropped] = merge.applyNotes(board, Array.isArray(response.notes) ? response.notes : []);
    const [members] = merge.applyMembers(board, Array.isArray(response.members) ? response.members : []);
    let meta = false;
    if (response.meta) [meta] = merge.applyMeta(board, response.meta);
    if (Number.isInteger(response.cursor) && response.cursor > board.cursor) board.cursor = response.cursor;
    if (notes.length || members.length || meta) {
      this.emit({ kind: "remote", board: board.id, notes, members, meta, dropped: dropped.length });
    }
  }

  async exchange(board) {
    let rejected = 0;
    let more = true; // whether the server may hold rows past our cursor
    for (const batch of this.batches(board)) {
      const sent = batch.map((note) => [note.id, note.rev]);
      const meta = board.pending.meta && board.meta ? board.meta : null;
      const response = await this.post(board, { cursor: board.cursor, notes: batch, members: [], meta });
      // The server merged what we sent: our record either won or lost to a
      // newer one it now returns. Either way it needn't go again, unless it
      // changed while the request was out.
      for (const [noteId, rev] of sent) {
        if (board.pending.notes[noteId] <= rev) delete board.pending.notes[noteId];
      }
      if (meta && board.pending.meta === meta.rev) board.pending.meta = null;
      rejected += Array.isArray(response.rejected) ? response.rejected.length : 0;
      this.apply(board, response);
      await this.save(board);
      more = Boolean(response.more);
    }
    for (let page = 0; more && page < MAX_PAGES; page++) {
      const response = await this.post(board, { cursor: board.cursor, notes: [], members: [], meta: null });
      this.apply(board, response);
      more = Boolean(response.more);
    }
    board.sync.rejected = rejected;
  }
}
