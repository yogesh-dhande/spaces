/**
 * A strict JSON parser that produces the Editor's JSON tree model directly, in one recursive-descent
 * pass over the buffer.
 *
 * The tree is a read-only view of what the file says, so the model keeps every number's source
 * lexeme rather than a JavaScript `number`: `JSON.parse` rounds `9007199254740993` to
 * `9007199254740992` and rewrites `1.00` as `1` before the tree could ever see them, and neither is
 * recoverable afterwards.
 *
 * Nothing here materializes a JavaScript object or array from the document. A member is an entry in
 * a list, so a `"__proto__"` key is an ordinary key rather than a write through the prototype
 * setter that `Object.entries` would then not report, and a value's shape is its own `kind` tag
 * rather than something the renderer has to duck-type out of a plain object.
 *
 * The parse is bounded the way the delimited-table parse is, by two budgets: a container retains at
 * most `MAX_CONTAINER_CHILDREN` members, the most the tree can ever render, and a document retains
 * at most `MAX_DOCUMENT_NODES` values in total. Everything past either budget is validated and
 * counted without building a model for it. A 10 MiB array of a few million scalars, and a 10 MiB
 * matrix of containers that each sit inside the per-container cap, therefore cost the bounded set of
 * models the tree shows rather than one model object per value, on the open and on every keystroke
 * after it.
 *
 * The grammar accepted is exactly RFC 8259, matching `JSON.parse`: no comments, no trailing commas,
 * no single quotes, no unquoted keys, and the same string escapes. A lone `\u` surrogate escape is
 * accepted and kept as the lone code unit, as `JSON.parse` keeps it.
 */

/**
 * The most members one container retains, and so the most children the tree can render for it.
 * It lives here, with the parser that enforces it, because the renderer reads the same constant for
 * its trailing note: a second copy would let the parser start dropping members the tree still wants
 * the moment one of them moved.
 *
 * The bound is the DOM's, not the document's: a single array of a hundred thousand objects would
 * build a hundred thousand rows the moment its triangle is clicked, which freezes the pane for as
 * long as it takes. Each container still carries its real member count, so the note names what the
 * file holds.
 */
export const MAX_CONTAINER_CHILDREN = 2000;

/**
 * The most values one document retains, counted across every model the parse builds: each scalar,
 * each object, each array, at every depth.
 *
 * The per-container cap bounds what a single container costs, not what a document costs. A matrix
 * of 2000 arrays of 2000 scalars is about 8 MiB of text in which every container sits inside that
 * cap, and it would still build about four million models, on the open and on every keystroke after
 * it. This budget is what bounds the document as a whole.
 *
 * Past it the parse retains nothing further: the rest of the document is validated and counted by
 * the same skip routines a container past its own cap uses, so a syntax error anywhere is still the
 * file's, and every container the parse had already started keeps counting its remaining members.
 * The tree's trailing note reads that count against the members actually retained, so a container
 * cut short by this budget names the file's real total exactly as one cut short by the per-container
 * cap does.
 */
export const MAX_DOCUMENT_NODES = 100_000;

/**
 * The deepest a container (object or array) may nest before the parser gives up rather than
 * recurse further, on both the retaining and the skip path.
 *
 * The parser is recursive: one call frame per nested container. How deep a JavaScript engine can
 * actually recurse before it runs out of native stack is a runtime detail, not a language
 * guarantee, and in this bundle's runtime it sits around 10,000 levels. Without a bound of its own,
 * a validly-nested document deep enough to approach that figure would read as invalid JSON (an
 * uncaught `RangeError`, not a `JSONSyntaxError`) on a machine or engine build whose actual limit
 * sits lower, and as valid on one whose limit sits higher: the same file would parse differently on
 * different machines. 512 sits far below any of that, and far beyond any document a person edits by
 * hand or a tool reasonably generates, so a container that opens past it always reads the same way
 * regardless of the host engine: the parse throws `JSONDepthError` rather than recursing further,
 * the Tree segment goes unavailable the same way it does for a document that does not parse at all
 * (see `parseStrictJSON`), and Text still holds the file. This is accepted behavior, not a defect an
 * iterative rewrite of the parser would need to fix.
 */
export const MAX_NESTING_DEPTH = 512;

/** One `"key": value` member of an object, in the position the document first wrote that key. */
export interface JSONMember {
  key: string;
  value: JSONValue;
}

/** A parsed JSON value. Every leaf carries exactly what the tree prints: a string its decoded text,
 *  a number the lexeme the file wrote, character for character. A container carries the members it
 *  retained plus `count`, every member the document gave it, so a capped container still reports
 *  its real size. */
export type JSONValue =
  | { kind: "object"; entries: JSONMember[]; count: number }
  | { kind: "array"; items: JSONValue[]; count: number }
  | { kind: "string"; value: string }
  | { kind: "number"; lexeme: string }
  | { kind: "boolean"; value: boolean }
  | { kind: "null" };

/** A parse failure, carrying the offset into the source where the parser gave up so a caller can
 *  point at it. It is a `SyntaxError`, which is what `JSON.parse` throws, so a caller that only
 *  cares that the document does not parse treats both identically. */
export class JSONSyntaxError extends SyntaxError {
  readonly offset: number;

  constructor(message: string, offset: number) {
    super(`${message} at offset ${offset}`);
    this.name = "JSONSyntaxError";
    this.offset = offset;
  }
}

/**
 * Thrown when a container opens deeper than `MAX_NESTING_DEPTH` allows. Deliberately not a
 * `JSONSyntaxError` (nor a `SyntaxError` at all): the document past this point may be perfectly
 * well-formed JSON, so this is a distinct outcome from a syntax error, one the parser refuses to
 * find out about by recursing further to look. It carries `offset`, like `JSONSyntaxError` does, so
 * a caller that wants to point at where the parser gave up can.
 */
export class JSONDepthError extends Error {
  readonly offset: number;

  constructor(message: string, offset: number) {
    super(`${message} at offset ${offset}`);
    this.name = "JSONDepthError";
    this.offset = offset;
  }
}

/** The source characters the scanner branches on, by code unit. Comparing code units rather than
 *  single-character strings keeps the hot loops allocation-free. */
const CHAR_TAB = 0x09;
const CHAR_LINE_FEED = 0x0a;
const CHAR_CARRIAGE_RETURN = 0x0d;
const CHAR_SPACE = 0x20;
const CHAR_QUOTE = 0x22;
const CHAR_PLUS = 0x2b;
const CHAR_COMMA = 0x2c;
const CHAR_MINUS = 0x2d;
const CHAR_DOT = 0x2e;
const CHAR_ZERO = 0x30;
const CHAR_NINE = 0x39;
const CHAR_COLON = 0x3a;
const CHAR_OPEN_BRACKET = 0x5b;
const CHAR_BACKSLASH = 0x5c;
const CHAR_CLOSE_BRACKET = 0x5d;
const CHAR_OPEN_BRACE = 0x7b;
const CHAR_CLOSE_BRACE = 0x7d;

/** The two-character escapes JSON defines, mapped to what each stands for. `\u` is handled
 *  separately, since it consumes four more characters. */
const SIMPLE_ESCAPES: Readonly<Record<string, string>> = {
  '"': '"',
  "\\": "\\",
  "/": "/",
  b: "\b",
  f: "\f",
  n: "\n",
  r: "\r",
  t: "\t",
};

class Parser {
  private readonly text: string;
  private index = 0;
  /** Models built so far, across the whole document: the `MAX_DOCUMENT_NODES` budget's counter. */
  private retainedNodes = 0;
  /** Containers currently open, on both the retaining and the skip path: the `MAX_NESTING_DEPTH`
   *  budget's counter. */
  private depth = 0;

  constructor(text: string) {
    this.text = text;
  }

  /** The whole document: one value, surrounded by optional whitespace and nothing else. */
  parseDocument(): JSONValue {
    this.skipWhitespace();
    const value = this.parseValue();
    this.skipWhitespace();
    if (this.index < this.text.length) throw this.error("Unexpected trailing content");
    return value;
  }

  /** Whether the document budget still admits a model. Every call site that would retain one asks
   *  first and skips the value instead when it does not, which is what keeps `retainedNodes` from
   *  ever passing `MAX_DOCUMENT_NODES`. */
  private canRetain(): boolean {
    return this.retainedNodes < MAX_DOCUMENT_NODES;
  }

  /** Marks one more container open, on top of whatever depth the caller is already nested at, and
   *  rejects the document rather than recursing into it once that passes `MAX_NESTING_DEPTH`. Every
   *  container-opening method (`parseObject`, `parseArray`, `skipObject`, `skipArray`) calls this
   *  first and `exitContainer` in a `finally`, so the count reflects containers actually on the call
   *  stack right now, whether or not their contents are being retained. */
  private enterContainer(): void {
    this.depth += 1;
    if (this.depth > MAX_NESTING_DEPTH) {
      throw new JSONDepthError(`Exceeded maximum nesting depth of ${MAX_NESTING_DEPTH}`, this.index);
    }
  }

  private exitContainer(): void {
    this.depth -= 1;
  }

  /** One value the tree can show, built as a model. Every value built is one against the document
   *  budget, at every depth, which is what makes the budget bound the document rather than any one
   *  container in it. */
  private parseValue(): JSONValue {
    this.retainedNodes += 1;
    const code = this.text.charCodeAt(this.index);
    if (this.index >= this.text.length) throw this.error("Unexpected end of input");
    if (code === CHAR_OPEN_BRACE) return this.parseObject();
    if (code === CHAR_OPEN_BRACKET) return this.parseArray();
    if (code === CHAR_QUOTE) return { kind: "string", value: this.readString(true) };
    if (code === CHAR_MINUS || (code >= CHAR_ZERO && code <= CHAR_NINE)) return this.parseNumber();
    if (this.text.startsWith("true", this.index)) {
      this.index += 4;
      return { kind: "boolean", value: true };
    }
    if (this.text.startsWith("false", this.index)) {
      this.index += 5;
      return { kind: "boolean", value: false };
    }
    if (this.text.startsWith("null", this.index)) {
      this.index += 4;
      return { kind: "null" };
    }
    throw this.error("Unexpected token");
  }

  /**
   * An object, keeping its first `MAX_CONTAINER_CHILDREN` members in the order the document writes
   * them, for as long as the document budget admits them, and counting every member either way.
   *
   * A repeated key is resolved the way `JSON.parse` resolves it: the last value wins, and it takes
   * the position of the key's first occurrence, which is where an object built by assignment would
   * have kept it. The index map is what makes that a lookup rather than a scan of everything read
   * so far, and it is a `Map`, so a key like `"__proto__"` is data here rather than a prototype
   * write. The map holds only retained keys, so a repeat of one of them still lands on its entry
   * however far past the cap it sits, while a key first seen past the cap is counted and dropped.
   *
   * `count` is therefore members counted rather than members read: a repeat that resolved into a
   * retained entry is not a second member, so an object under the cap counts exactly the keys the
   * tree shows.
   */
  private parseObject(): JSONValue {
    this.enterContainer();
    try {
      this.index += 1; // {
      const entries: JSONMember[] = [];
      const positions = new Map<string, number>();
      let count = 0;
      this.skipWhitespace();
      if (this.consumeIfCode(CHAR_CLOSE_BRACE)) return { kind: "object", entries, count };
      for (;;) {
        this.skipWhitespace();
        if (this.text.charCodeAt(this.index) !== CHAR_QUOTE) throw this.error("Expected a member name");
        const key = this.readString(true);
        this.skipWhitespace();
        if (!this.consumeIfCode(CHAR_COLON)) throw this.error("Expected ':'");
        this.skipWhitespace();
        const existing = positions.get(key);
        if (existing !== undefined) {
          // A repeat of a retained key always replaces that member, even past the document budget: the
          // replacement is parsed as any value is, one node charged for the value itself, and if the
          // budget is already exhausted its own children are skipped rather than retained, the same as
          // any other container the budget did not admit. The member therefore always shows the last
          // value written, matching `JSON.parse`, whether or not that value's full subtree fit.
          //
          // The nodes of the value this replaces stay charged against `retainedNodes`: the budget is a
          // ceiling on models ever built, not a live count of what the tree currently shows, so a
          // replaced value's earlier subtree is deliberately not refunded. That only makes the ceiling
          // more conservative.
          entries[existing] = { key, value: this.parseValue() };
        } else if (entries.length < MAX_CONTAINER_CHILDREN && this.canRetain()) {
          positions.set(key, entries.length);
          entries.push({ key, value: this.parseValue() });
          count += 1;
        } else {
          this.skipValue();
          count += 1;
        }
        this.skipWhitespace();
        if (this.consumeIfCode(CHAR_COMMA)) continue;
        if (this.consumeIfCode(CHAR_CLOSE_BRACE)) return { kind: "object", entries, count };
        throw this.error("Expected ',' or '}'");
      }
    } finally {
      this.exitContainer();
    }
  }

  /** An array, keeping its first `MAX_CONTAINER_CHILDREN` items for as long as the document budget
   *  admits them, and counting every item either way. Every item past what it keeps is still
   *  parsed, so a syntax error anywhere in the array is still the file's. */
  private parseArray(): JSONValue {
    this.enterContainer();
    try {
      this.index += 1; // [
      const items: JSONValue[] = [];
      let count = 0;
      this.skipWhitespace();
      if (this.consumeIfCode(CHAR_CLOSE_BRACKET)) return { kind: "array", items, count };
      for (;;) {
        this.skipWhitespace();
        if (items.length < MAX_CONTAINER_CHILDREN && this.canRetain()) items.push(this.parseValue());
        else this.skipValue();
        count += 1;
        this.skipWhitespace();
        if (this.consumeIfCode(CHAR_COMMA)) continue;
        if (this.consumeIfCode(CHAR_CLOSE_BRACKET)) return { kind: "array", items, count };
        throw this.error("Expected ',' or ']'");
      }
    } finally {
      this.exitContainer();
    }
  }

  /**
   * One value the tree will never show, validated and stepped over without building anything for
   * it. The grammar it accepts is `parseValue`'s, so a document is rejected on exactly the same
   * text whether the offending value fell inside a container's retained members or past its cap.
   */
  private skipValue(): void {
    const code = this.text.charCodeAt(this.index);
    if (this.index >= this.text.length) throw this.error("Unexpected end of input");
    if (code === CHAR_OPEN_BRACE) return this.skipObject();
    if (code === CHAR_OPEN_BRACKET) return this.skipArray();
    if (code === CHAR_QUOTE) {
      this.readString(false);
      return;
    }
    if (code === CHAR_MINUS || (code >= CHAR_ZERO && code <= CHAR_NINE)) return this.scanNumber();
    if (this.text.startsWith("true", this.index)) {
      this.index += 4;
      return;
    }
    if (this.text.startsWith("false", this.index)) {
      this.index += 5;
      return;
    }
    if (this.text.startsWith("null", this.index)) {
      this.index += 4;
      return;
    }
    throw this.error("Unexpected token");
  }

  /** An object inside a skipped value: its members are skipped in turn, keys included, so nothing
   *  nested under a dropped member is retained either. */
  private skipObject(): void {
    this.enterContainer();
    try {
      this.index += 1; // {
      this.skipWhitespace();
      if (this.consumeIfCode(CHAR_CLOSE_BRACE)) return;
      for (;;) {
        this.skipWhitespace();
        if (this.text.charCodeAt(this.index) !== CHAR_QUOTE) throw this.error("Expected a member name");
        this.readString(false);
        this.skipWhitespace();
        if (!this.consumeIfCode(CHAR_COLON)) throw this.error("Expected ':'");
        this.skipWhitespace();
        this.skipValue();
        this.skipWhitespace();
        if (this.consumeIfCode(CHAR_COMMA)) continue;
        if (this.consumeIfCode(CHAR_CLOSE_BRACE)) return;
        throw this.error("Expected ',' or '}'");
      }
    } finally {
      this.exitContainer();
    }
  }

  private skipArray(): void {
    this.enterContainer();
    try {
      this.index += 1; // [
      this.skipWhitespace();
      if (this.consumeIfCode(CHAR_CLOSE_BRACKET)) return;
      for (;;) {
        this.skipWhitespace();
        this.skipValue();
        this.skipWhitespace();
        if (this.consumeIfCode(CHAR_COMMA)) continue;
        if (this.consumeIfCode(CHAR_CLOSE_BRACKET)) return;
        throw this.error("Expected ',' or ']'");
      }
    } finally {
      this.exitContainer();
    }
  }

  /**
   * A string token. The scan copies whole runs of ordinary characters at a time and only falls into
   * the per-character path at an escape, so a document of long plain strings costs one slice each
   * rather than one concatenation per character.
   *
   * `retain` false walks and validates the same characters without assembling the decoded text,
   * which is what a string past a container's cap costs: the parse still rejects an unterminated
   * string or a bad escape inside it, and nothing survives the call.
   */
  private readString(retain: boolean): string {
    this.index += 1; // opening quote
    let value = "";
    let runStart = this.index;
    for (;;) {
      if (this.index >= this.text.length) throw this.error("Unterminated string");
      const code = this.text.charCodeAt(this.index);
      if (code === CHAR_QUOTE) {
        if (retain) value += this.text.slice(runStart, this.index);
        this.index += 1;
        return value;
      }
      if (code < CHAR_SPACE) throw this.error("Unescaped control character in string");
      if (code !== CHAR_BACKSLASH) {
        this.index += 1;
        continue;
      }
      if (retain) value += this.text.slice(runStart, this.index);
      this.index += 1;
      const escaped = this.parseEscape();
      if (retain) value += escaped;
      runStart = this.index;
    }
  }

  /** One escape sequence, positioned just past its backslash. A `\u` escape is taken as the single
   *  code unit it names, including an unpaired surrogate, which is what `JSON.parse` does too. */
  private parseEscape(): string {
    if (this.index >= this.text.length) throw this.error("Unterminated escape");
    const char = this.text[this.index]!;
    const simple = SIMPLE_ESCAPES[char];
    if (simple !== undefined) {
      this.index += 1;
      return simple;
    }
    if (char !== "u") throw this.error("Invalid escape");
    this.index += 1;
    const digits = this.text.slice(this.index, this.index + 4);
    if (digits.length < 4 || !/^[0-9a-fA-F]{4}$/.test(digits)) throw this.error("Invalid unicode escape");
    this.index += 4;
    return String.fromCharCode(parseInt(digits, 16));
  }

  private parseNumber(): JSONValue {
    const start = this.index;
    this.scanNumber();
    return { kind: "number", lexeme: this.text.slice(start, this.index) };
  }

  /** Walks a number token, validating it. The grammar is JSON's own: an optional minus, an integer
   *  part with no leading zeros, an optional fraction, an optional exponent. */
  private scanNumber(): void {
    this.consumeIfCode(CHAR_MINUS);
    if (this.consumeIfCode(CHAR_ZERO)) {
      // A leading zero stands alone: `01` is two tokens to JSON, which is a syntax error here.
    } else {
      if (!this.consumeDigits()) throw this.error("Expected a digit");
    }
    if (this.consumeIfCode(CHAR_DOT)) {
      if (!this.consumeDigits()) throw this.error("Expected a digit after '.'");
    }
    const exponent = this.text[this.index];
    if (exponent === "e" || exponent === "E") {
      this.index += 1;
      const sign = this.text.charCodeAt(this.index);
      if (sign === CHAR_PLUS || sign === CHAR_MINUS) this.index += 1;
      if (!this.consumeDigits()) throw this.error("Expected a digit in the exponent");
    }
  }

  private consumeDigits(): boolean {
    const start = this.index;
    while (this.index < this.text.length) {
      const code = this.text.charCodeAt(this.index);
      if (code < CHAR_ZERO || code > CHAR_NINE) break;
      this.index += 1;
    }
    return this.index > start;
  }

  private consumeIfCode(code: number): boolean {
    if (this.text.charCodeAt(this.index) !== code) return false;
    this.index += 1;
    return true;
  }

  /** JSON's whitespace is exactly these four characters; anything else is a token. */
  private skipWhitespace(): void {
    while (this.index < this.text.length) {
      const code = this.text.charCodeAt(this.index);
      if (code !== CHAR_SPACE && code !== CHAR_TAB && code !== CHAR_LINE_FEED && code !== CHAR_CARRIAGE_RETURN) return;
      this.index += 1;
    }
  }

  private error(message: string): JSONSyntaxError {
    return new JSONSyntaxError(message, this.index);
  }
}

/** Parses `text` as strict JSON, or throws a `JSONSyntaxError` naming where it stopped. */
export function parseJSONDocument(text: string): JSONValue {
  return new Parser(text).parseDocument();
}
