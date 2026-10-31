import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  COMMENT_MAX_CHARS, COMMENT_MAX_LINE_BREAKS, normalizeCommentBody, normalizeCommentLanguage,
} from "../src/routes/comments";

describe("normalizeCommentBody", () => {
  it("trims and keeps line breaks", () => {
    assert.equal(normalizeCommentBody("  สวัสดี\nhello  "), "สวัสดี\nhello");
  });
  it("rejects empty, non-string and too long text", () => {
    assert.equal(normalizeCommentBody("   "), null);
    assert.equal(normalizeCommentBody(42), null);
    assert.equal(normalizeCommentBody("a".repeat(COMMENT_MAX_CHARS + 1)), null);
    assert.equal(normalizeCommentBody("a".repeat(COMMENT_MAX_CHARS)), "a".repeat(COMMENT_MAX_CHARS));
  });
  it("strips control characters", () => {
    assert.equal(normalizeCommentBody("a\u0000b\u0007c"), "abc");
    assert.equal(normalizeCommentBody("a\u009bb\u0080c\u009fd"), "abcd");
    // U+0085 is a line break, so it stays.
    assert.equal(normalizeCommentBody("a\u0085b"), "a\u0085b");
  });
  it("drops every C0 and C1 control character and DEL, and keeps tab, line feed, carriage return and NEL", () => {
    const kept = new Set([0x09, 0x0a, 0x0d, 0x85]);
    const controls = [
      ...Array.from({ length: 0x20 }, (_, index) => index),
      ...Array.from({ length: 0x21 }, (_, index) => 0x7f + index),
    ];
    for (const code of controls) {
      const text = `a${String.fromCharCode(code)}b`;
      assert.equal(normalizeCommentBody(text), kept.has(code) ? text : "ab", `U+${code.toString(16).padStart(4, "0")}`);
    }
  });
  it("keeps tabs and line breaks inside the text", () => {
    assert.equal(normalizeCommentBody("a\tb\r\nc"), "a\tb\r\nc");
  });
  it("keeps the first ten line breaks and stores the rest as spaces", () => {
    assert.equal(COMMENT_MAX_LINE_BREAKS, 10);
    const atTheLimit = "a" + "\n".repeat(10) + "b";
    assert.equal(normalizeCommentBody(atTheLimit), atTheLimit);
    assert.equal(normalizeCommentBody("a" + "\n".repeat(11) + "b"), "a" + "\n".repeat(10) + " b");
    // One letter and four hundred blank lines would be a row about eight thousand points tall.
    assert.equal(normalizeCommentBody("x" + "\n".repeat(400) + "y"), "x" + "\n".repeat(10) + " ".repeat(390) + "y");
  });
  it("counts a CRLF as one line break", () => {
    const atTheLimit = "a\r\n".repeat(10) + "b";
    assert.equal(normalizeCommentBody(atTheLimit), atTheLimit);
    assert.equal(normalizeCommentBody("a\r\n".repeat(11) + "b"), "a\r\n".repeat(10) + "a b");
  });
  it("counts every kind of line break the same", () => {
    // CR, LF, NEL and the Unicode line and paragraph separators: thirteen words, twelve breaks between them.
    const kinds = ["\n", "\r", "\u0085", "\u2028", "\u2029"];
    const words = "abcdefghijklm".split("");
    const join = (between: (index: number) => string) =>
      words.map((word, index) => (index < words.length - 1 ? word + between(index) : word)).join("");
    assert.equal(
      normalizeCommentBody(join((index) => kinds[index % kinds.length])),
      join((index) => (index < COMMENT_MAX_LINE_BREAKS ? kinds[index % kinds.length] : " ")),
    );
  });
  it("limits line breaks after trimming, not before", () => {
    // The eight leading breaks are trimmed away first, so the eight inside the text all stay.
    assert.equal(normalizeCommentBody("\n".repeat(8) + "a" + "\n".repeat(8) + "b"), "a" + "\n".repeat(8) + "b");
  });
  it("counts the characters that were sent, not what is left after the line-break limit", () => {
    // 501 code points. Eleven CRLFs would shrink once limited, but the text was too long when it arrived.
    assert.equal(normalizeCommentBody("x" + "\r\n".repeat(11) + "y".repeat(478)), null);
    assert.equal(
      normalizeCommentBody("x" + "\r\n".repeat(11) + "y".repeat(477)),
      "x" + "\r\n".repeat(10) + " " + "y".repeat(477),
    );
  });
  it("limits line breaks after the control characters are gone", () => {
    // Without the NUL the CR and the LF are one CRLF, the tenth break. Counted before the strip they would be two.
    assert.equal(
      normalizeCommentBody("a" + "\n".repeat(9) + "\r\u0000\n" + "b"),
      "a" + "\n".repeat(9) + "\r\n" + "b",
    );
  });
  it("does not take other whitespace for a line break", () => {
    // A no-break space, an ideographic space and a zero-width space stay as they are, even past the tenth break.
    const text = "a" + "\n".repeat(10) + "b\u00a0c\u3000d\u200be";
    assert.equal(normalizeCommentBody(text), text);
  });
  it("does not end in a space the line-break limit made", () => {
    // Only the app trims a NEL, so a Worker client can end a comment with them. The eleventh would become a space.
    assert.equal(normalizeCommentBody("x" + "\u0085".repeat(11)), "x" + "\u0085".repeat(10));
    assert.equal(normalizeCommentBody("x" + "\n".repeat(10) + "\u0085"), "x");
  });
  it("gives text that is already in its final form", () => {
    const pieces = ["a", " ", "\t", "\n", "\r", "\r\n", "\u0085", "\u2028", "\u2029", "\u00a0", "\u200b", "\u0000", "😀"];
    let seed = 20261101;
    const next = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) >> 8;
    let accepted = 0;
    for (let round = 0; round < 1000; round++) {
      // Any piece may come first or last, so the text can start or end in whitespace.
      let text = "";
      for (let count = next() % 60; count > 0; count--) text += pieces[next() % pieces.length];
      const once = normalizeCommentBody(text);
      if (once === null) continue;
      accepted++;
      assert.equal(normalizeCommentBody(once), once, JSON.stringify(text));
      assert.equal(once, once.trim(), JSON.stringify(text));
    }
    assert.ok(accepted > 500, `${accepted} of 1000 texts were accepted`);
  });
  it("limits line breaks like a plain walk through the text does", () => {
    const pieces = ["a", " ", "\t", "\n", "\r", "\r\n", "\u0085", "\u2028", "\u2029", "😀"];
    let seed = 20261031;
    const next = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) >> 8;
    for (let round = 0; round < 500; round++) {
      // Starts and ends with a letter, so trimming and the visible-character rule leave the text alone.
      let text = "x";
      for (let count = next() % 60; count > 0; count--) text += pieces[next() % pieces.length];
      text += "y";
      let seen = 0;
      let expected = "";
      for (let index = 0; index < text.length; index++) {
        const unit = text[index];
        const isBreak = unit === "\r" || unit === "\n" || unit === "\u0085" || unit === "\u2028" || unit === "\u2029";
        if (!isBreak) { expected += unit; continue; }
        const lineBreak = unit === "\r" && text[index + 1] === "\n" ? "\r\n" : unit;
        index += lineBreak.length - 1;
        expected += ++seen > COMMENT_MAX_LINE_BREAKS ? " " : lineBreak;
      }
      assert.equal(normalizeCommentBody(text), expected, JSON.stringify(text));
    }
  });
  it("rejects text nobody can see", () => {
    const invisible = [
      "\u200b", "\u200b\u200b", "\u2060", "\ufeff", "\u00ad", "\u2800", "\u3164", "\u115f\u1160", "\uffa0",
      " \u200b \u00a0 ", "\u0000\u200b", "\ufe0f", "\ufe00\ufe0e", "\u034f", "\ufffc", "\u0085", "\u2028\u2029",
      // trim() leaves whitespace that sits between zero-width characters; the C1 controls are dropped before the check.
      "\u200b \u200b", "\u200b\u00a0\u200b", "\u200b\u2028\u200b", "\u0080", "\u009b\u200b",
    ];
    for (const text of invisible) {
      assert.equal(normalizeCommentBody(text), null, JSON.stringify(text));
    }
  });
  it("keeps invisible characters that sit inside real text", () => {
    assert.equal(normalizeCommentBody("\u200bhi"), "\u200bhi");
    assert.equal(normalizeCommentBody("a\u200db"), "a\u200db");
    assert.equal(normalizeCommentBody("ไม่\u200cได้"), "ไม่\u200cได้");
    assert.equal(normalizeCommentBody("\u3164x\u3164"), "\u3164x\u3164");
  });
  it("accepts emoji sequences and combining marks", () => {
    assert.equal(normalizeCommentBody("👨‍👩‍👧‍👦"), "👨‍👩‍👧‍👦");
    assert.equal(normalizeCommentBody("ก้"), "ก้");
    assert.equal(normalizeCommentBody("้"), "้");
  });
  it("rejects an unpaired surrogate", () => {
    for (const text of ["\ud800", "ok \udc00", "\ud83d no pair", "a\ud83d", "\ude00\ud83d"]) {
      assert.equal(normalizeCommentBody(text), null, JSON.stringify(text));
    }
    assert.equal(normalizeCommentBody("😀"), "😀");
  });
  it("counts characters as code points", () => {
    assert.equal(normalizeCommentBody("😀".repeat(COMMENT_MAX_CHARS))?.length, COMMENT_MAX_CHARS * 2);
    assert.equal(normalizeCommentBody("😀".repeat(COMMENT_MAX_CHARS + 1)), null);
  });
});

describe("normalizeCommentLanguage", () => {
  it("reduces a locale to a supported base language", () => {
    assert.equal(normalizeCommentLanguage("th-TH"), "th");
    assert.equal(normalizeCommentLanguage("zh_Hans"), "zh");
    assert.equal(normalizeCommentLanguage("no"), "nb");
  });
  it("ignores case and padding", () => {
    assert.equal(normalizeCommentLanguage(" TH "), "th");
    assert.equal(normalizeCommentLanguage("PT-br"), "pt");
  });
  it("reads every Norwegian variant as nb", () => {
    for (const tag of ["no", "nb", "nn", "NN", "nb-NO", "nn_NO", "no-NO"]) {
      assert.equal(normalizeCommentLanguage(tag), "nb", tag);
    }
  });
  it("returns null for unsupported or missing languages", () => {
    assert.equal(normalizeCommentLanguage("xx"), null);
    assert.equal(normalizeCommentLanguage(null), null);
  });
});
