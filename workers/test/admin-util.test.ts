/**
 * Unit tests for CMS form/array helpers (pure functions).
 */

import { describe, it, expect } from "vitest";
import {
  formInt,
  formStr,
  parseBool,
  parseTags,
  pgArrayToList,
  toPgTextArray,
} from "../src/admin/util.js";

describe("parseTags", () => {
  it("trims, drops empties, de-dupes, preserves order", () => {
    expect(parseTags(" azaan , New ,azaan,, ")).toEqual(["azaan", "New"]);
  });
  it("returns [] for undefined / empty", () => {
    expect(parseTags(undefined)).toEqual([]);
    expect(parseTags("   ")).toEqual([]);
  });
});

describe("toPgTextArray", () => {
  it("renders an empty literal", () => {
    expect(toPgTextArray([])).toBe("{}");
  });
  it("quotes each element and escapes quotes/backslashes", () => {
    expect(toPgTextArray(["a", "jumma mubarak"])).toBe('{"a","jumma mubarak"}');
    expect(toPgTextArray(['he said "hi"'])).toBe('{"he said \\"hi\\""}');
  });
});

describe("pgArrayToList", () => {
  it("parses simple and quoted literals", () => {
    expect(pgArrayToList("{}")).toEqual([]);
    expect(pgArrayToList("{Azaan,New}")).toEqual(["Azaan", "New"]);
    expect(pgArrayToList('{"jumma mubarak",azaan}')).toEqual(["jumma mubarak", "azaan"]);
  });
  it("passes through real arrays and ignores non-strings", () => {
    expect(pgArrayToList(["a", "b"])).toEqual(["a", "b"]);
    expect(pgArrayToList(null)).toEqual([]);
    expect(pgArrayToList(42)).toEqual([]);
  });
  it("round-trips with toPgTextArray", () => {
    const tags = ["Azaan", "jumma mubarak", "New"];
    expect(pgArrayToList(toPgTextArray(tags))).toEqual(tags);
  });
});

describe("parseBool", () => {
  it("treats checkbox 'on'/'true'/true as true, everything else false", () => {
    expect(parseBool("on")).toBe(true);
    expect(parseBool("true")).toBe(true);
    expect(parseBool(true)).toBe(true);
    expect(parseBool(undefined)).toBe(false);
    expect(parseBool("false")).toBe(false);
    expect(parseBool("")).toBe(false);
  });
});

describe("formStr / formInt", () => {
  it("formStr trims strings and returns '' for non-strings", () => {
    expect(formStr({ a: "  hi " }, "a")).toBe("hi");
    expect(formStr({ a: 3 }, "a")).toBe("");
    expect(formStr({}, "missing")).toBe("");
  });
  it("formInt parses ints with a fallback", () => {
    expect(formInt({ n: "5" }, "n")).toBe(5);
    expect(formInt({ n: "" }, "n", 9)).toBe(9);
    expect(formInt({ n: "x" }, "n", 7)).toBe(7);
    expect(formInt({}, "n", 0)).toBe(0);
  });
});
