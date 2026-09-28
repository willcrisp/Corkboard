// The web app's model: note text (links in and out of the editor), the note
// kinds the game writes, and identity.

import { test } from "node:test";
import assert from "node:assert/strict";

import * as sanitise from "../public/js/core/sanitise.js";
import { collectLinks, nameIndex, parse, plain, toEditable, toText } from "../public/js/model/text.js";
import {
  chainBefore, CHAIN_MAX, cleanPlayerName, decodeDone, decodePlayer, decodeQuests, decodeRecipes, encodePlayer, gear,
  groupChains, notes, playerEntries, playerKey, questLinks, questLogs, QUESTS_DONE_MAX, recipeLists,
} from "../public/js/model/formats.js";
import { byline, editorHeader, matches, nextNoteId, shortAge, shortName, webName } from "../public/js/model/view.js";

const FIERY = "|cffa335ee|Hitem:17010::::::::60:::::|h[Fiery Core]|h|r";
const QUEST = "|cffffff00|Hquest:7848:60|h[Attunement to the Core]|h|r";
const NAMED = "|cnIQ4:|Hitem:19019::|h[Thunderfury]|h|r";

test("parse splits text into runs and links", () => {
  const segs = parse(`Need 2x ${FIERY} || spares`);
  assert.deepEqual(segs.map((s) => s.type), ["text", "link", "text"]);
  assert.equal(segs[1].label, "[Fiery Core]");
  assert.equal(segs[1].color, "#a335ee");
  assert.equal(segs[1].raw, FIERY);
  assert.equal(segs[2].text, " | spares");
  assert.equal(parse(NAMED)[0].color, "#a335ee");
  assert.equal(plain(`${QUEST} done`), "[Attunement to the Core] done");
});

test("colours that don't wrap a link are counted and shown", () => {
  const segs = parse("|cffff0000red|r plain");
  assert.equal(segs.strays, 2);
  assert.deepEqual(segs.map((s) => [s.text, s.color]), [["red", "#ff0000"], [" plain", null]]);
});

test("the editor round-trips links and pipes byte for byte", () => {
  for (const text of [`Need 4x ${FIERY} and ${QUEST}.`, `a || b ${NAMED}`, "line one\nline two", FIERY + FIERY]) {
    const { text: editable, links } = toEditable(text);
    assert.equal(toText(editable, links), text);
  }
  const { text: editable, links } = toEditable(`Bring ${FIERY}`);
  assert.equal(editable, "Bring [Fiery Core]");
  // A typed pipe is escaped; a typed [Fiery Core] becomes the link; unknown brackets stay text.
  const out = toText("a|b [Fiery Core] [Not a link] [Fiery Core]", links);
  assert.equal(out, `a||b ${FIERY} [Not a link] ${FIERY}`);
  assert.ok(sanitise.text(out)[0]);
  assert.equal(toText("x\r\ny", new Map()), "x\ny");
});

test("links are collected once and name quests and recipes", () => {
  const recipe = "|cffffd000|Henchant:3753|h[Leatherworking: Handstitched Leather Belt]|h|r";
  const links = collectLinks([`${FIERY} ${QUEST}`, `${FIERY} ${recipe}`, "plain"]);
  assert.deepEqual(links.map((l) => l.label), ["[Attunement to the Core]", "[Fiery Core]", "[Leatherworking: Handstitched Leather Belt]"]);
  const names = nameIndex(links);
  assert.equal(names.get("quest:7848"), "Attunement to the Core");
  assert.equal(names.get("spell:3753"), "Leatherworking: Handstitched Leather Belt");
});

test("player notes encode and decode like Core/Players.lua", () => {
  assert.deepEqual(encodePlayer("  Gankalot  ", "avoid", " Ninja looted. "), ["P1;avoid;Gankalot\nNinja looted.", null]);
  assert.deepEqual(encodePlayer("Aprune   Proudshield", "good", ""), ["P1;good;Aprune Proudshield", null]);
  assert.deepEqual(encodePlayer("Bad;Name", "avoid", ""), [null, "player_name"]);
  assert.deepEqual(encodePlayer("Name", "meh", ""), [null, "verdict"]);
  assert.deepEqual(encodePlayer("Name", "avoid", "|Tbad|t"), [null, "escape"]);
  assert.deepEqual(encodePlayer("-", "avoid", ""), [null, "player_name"]);
  assert.deepEqual(decodePlayer(`P1;avoid;Gankalot\nRolled on ${FIERY}`),
    { name: "Gankalot", verdict: "avoid", reason: `Rolled on ${FIERY}`, key: "gankalot" });
  assert.equal(decodePlayer("P1;maybe;Gankalot"), null);
  assert.equal(decodePlayer("P1;avoid; Gankalot"), null); // not tidied: written by something else
  assert.equal(playerKey("Aprune Proudshield-Realm"), "aprune");
  assert.equal(playerKey("Øystein-Realm"), "Øystein"); // Lua's lower() only folds ASCII
  assert.deepEqual(cleanPlayerName("x".repeat(65)), [null, "player_name"]);
});

test("recipe lists and quest logs decode", () => {
  const text = "R1;165;47;75;3;Leatherworking\n1ki,2,1";
  assert.deepEqual(decodeRecipes(text), { id: 165, name: "Leatherworking", skill: 47, max: 75, learned: 3, recipes: [2034, 2036, 2037], details: {} });
  assert.equal(decodeRecipes("R1;165;47;75;3;Leatherworking\n1ki,,2"), null);
  assert.deepEqual(decodeRecipes("R1;356;1;300;0;Fishing").recipes, []);
  // R2 adds each recipe's level and armour type (the same text as recipes_spec.lua).
  const r2 = decodeRecipes("R2;165;47;75;4;Leatherworking\n3,4,r2lc,1\n,25l,5,p");
  assert.deepEqual(r2.recipes, [3, 7, 1263079, 1263080]);
  assert.deepEqual(r2.details, { 7: { level: 25, armour: "leather" }, 1263079: { level: 5 }, 1263080: { armour: "plate" } });
  for (const bad of [
    "R3;165;47;75;1;Leatherworking\n1",
    "R1;165;47;75;1;Leatherworking\n1\n5l",
    "R2;165;47;75;2;Leatherworking\n1,1\n5l",
    "R2;165;47;75;1;Leatherworking\n1\n5l,",
    "R2;165;47;75;1;Leatherworking\n1\n05",
    "R2;165;47;75;1;Leatherworking\n1\n1000",
    "R2;165;47;75;1;Leatherworking\n1\nl5",
    "R2;165;47;75;1;Leatherworking\n1\n5s",
    "R2;165;47;75;1;Leatherworking\n1\n5\n",
    "R1;165;47;75;1;Leatherworking\n1,2",
  ]) assert.equal(decodeRecipes(bad), null, bad);
  assert.deepEqual(decodeQuests("7:5,46:10,x:1,166:18"), [{ id: 7, level: 5 }, { id: 46, level: 10 }, { id: 166, level: 18 }]);
});

test("completed quests and chains decode as the addon writes them", () => {
  // The same texts as quest_history_spec.lua.
  assert.deepEqual(decodeQuests("7:5,15:3/7,46:10/46\nD1;46.10.1790000050.7"),
    [{ id: 7, level: 5 }, { id: 15, level: 3, prev: 7 }, { id: 46, level: 10 }]);
  const done = [{ id: 46, level: 10, at: 1790000050, prev: 7 }, { id: 7, level: 5, at: 1790000000 }, { id: 9, level: 0, at: 1789999991 }];
  assert.deepEqual(decodeDone("7:5,166:18\nD1;46.10.1790000050.7,7.5.1790000000,9.0.1789999991"), done);
  assert.deepEqual(decodeDone("\nD1;46.10.1790000050.7,7.5.1790000000,9.0.1789999991"), done);
  assert.deepEqual(decodeDone("7:5,166:18"), []);
  assert.deepEqual(decodeDone("\nD1;x.1.2,0.5.1,5.5.5.5,9.3.100,9.3.50,12.1.2.3.4,13.1"),
    [{ id: 5, level: 5, at: 5 }, { id: 9, level: 3, at: 100 }]);
  const many = Array.from({ length: 40 }, (_, i) => `${i + 1}.1.${1000 - i}`).join(",");
  assert.equal(decodeDone(`\nD1;${many}`).length, QUESTS_DONE_MAX);

  const base = { editor: "B-R", color: 1, deleted: false, created: 10, rev: 10, kind: "quests" };
  const board = { notes: {
    "aaaaaaaa-0": { ...base, id: "aaaaaaaa-0", author: "Bob-R", text: "166:18/54\nD1;54.7.300.15,46.10.200,15.3.100.7,7.5.50" },
    "bbbbbbbb-0": { ...base, id: "bbbbbbbb-0", author: "Carol-R", text: "15:3/8,54:7/15" },
    "cccccccc-0": { ...base, id: "cccccccc-0", author: "Dan-R", text: "15:3/7" },
  } };
  const { links, levels } = questLinks(board);
  assert.deepEqual([...links].sort((a, b) => a[0] - b[0]), [[15, 7], [54, 15], [166, 54]]);
  assert.equal(levels.get(166), 18);
  assert.deepEqual(chainBefore(links, 166), [7, 15, 54]);
  assert.deepEqual(chainBefore(new Map([[3, 1], [1, 2], [2, 1]]), 3), [2, 1]);
  assert.equal(chainBefore(new Map(Array.from({ length: 49 }, (_, i) => [i + 2, i + 1])), 50).length, CHAIN_MAX);
  const grouped = groupChains(decodeDone(board.notes["aaaaaaaa-0"].text), links);
  assert.deepEqual(grouped.map((e) => [e.id, e.up, e.down]), [[54, false, true], [15, true, true], [7, true, false], [46, false, false]]);
});

test("board views pick the right kinds", () => {
  const base = { author: "A-R", editor: "A-R", color: 1, deleted: false, created: 10, rev: 10 };
  const board = { notes: {
    "aaaaaaaa-0001": { ...base, id: "aaaaaaaa-0001", text: "note" },
    "aaaaaaaa-0002": { ...base, id: "aaaaaaaa-0002", text: FIERY, kind: "gear", created: 20 },
    "aaaaaaaa-0003": { ...base, id: "aaaaaaaa-0003", text: "R1;165;1;75;0;Leatherworking", kind: "recipes" },
    "aaaaaaaa-0": { ...base, id: "aaaaaaaa-0", text: "7:5", kind: "quests" },
    "aaaaaaaa-0004": { ...base, id: "aaaaaaaa-0004", text: "P1;good;Bob", kind: "player" },
    "aaaaaaaa-0005": { ...base, id: "aaaaaaaa-0005", text: "", deleted: true },
  } };
  assert.deepEqual(notes(board).map((n) => n.id), ["aaaaaaaa-0001"]);
  assert.deepEqual(gear(board).map((n) => n.id), ["aaaaaaaa-0002"]);
  assert.equal(recipeLists(board).length, 1);
  assert.deepEqual([...questLogs(board).keys()], ["A-R"]);
  assert.deepEqual(playerEntries(board).map((e) => e.name), ["Bob"]);
});

test("web names get a -Web realm unless they have one", () => {
  assert.deepEqual(webName("  Will  "), ["Will-Web", null]);
  assert.deepEqual(webName("Aprune  Proudshield"), ["Aprune Proudshield-Web", null]);
  assert.deepEqual(webName("Will-Stormrage"), ["Will-Stormrage", null]);
  assert.deepEqual(webName("Will-"), ["Will-Web", null]);
  for (const bad of ["", "   ", "-x", "a|b", "a\u0001b", "x".repeat(70), "!!!"]) {
    assert.deepEqual(webName(bad), [null, "web_name"], JSON.stringify(bad));
  }
  for (const good of ["Will", "Øystein", "Aprune Proudshield-ClassicBetaPvP2"]) {
    assert.ok(sanitise.name(webName(good)[0]), good);
  }
});

test("note ids follow Store.nextNoteId", () => {
  const board = { notes: { "0123abcd-0007": {}, "0123abcd-0": {}, "ffffffff-0100": {} } };
  assert.deepEqual(nextNoteId(board, "0123abcd"), ["0123abcd-0008", null]);
  assert.deepEqual(nextNoteId({ notes: {} }, "0123abcd"), ["0123abcd-0001", null]);
  assert.deepEqual(nextNoteId({ notes: { "0123abcd-999999999": {} } }, "0123abcd"), [null, "id_space"]);
  assert.ok(sanitise.noteId(nextNoteId(board, "0123abcd")[0]));
});

test("labels read like the game's", () => {
  assert.equal(shortAge(59), "now");
  assert.equal(shortAge(3599), "59m");
  assert.equal(shortAge(7200), "2h");
  assert.equal(shortAge(3 * 86400), "3d");
  assert.equal(shortName("Kaelthra-Stormrage"), "Kaelthra");
  assert.equal(byline({ author: "Kaelthra-R", editor: "Mira-R" }), "Kaelthra · edited by Mira");
  assert.equal(editorHeader("MC", { author: "Will-R", editor: "Bob-R", created: 0, rev: 7200 }, 7200 + 840),
    "MC · created by Will 2h ago · edited by Bob 14m ago");
  assert.ok(matches("Need Fiery Core\nWill-R", "fiery WILL"));
  assert.ok(!matches("Need Fiery Core", "lava"));
});
