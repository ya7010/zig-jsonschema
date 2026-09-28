//! A small ECMA-262 regular expression engine (with the `u` flag's
//! semantics), used for the `pattern` / `patternProperties` keywords and the
//! `regex` format.
//!
//! Zig's standard library has no regex engine, so this implements a
//! backtracking VM over Unicode code points. Supported syntax:
//!
//! - alternation `|`, groups `(...)`, `(?:...)`, named groups `(?<n>...)`
//! - quantifiers `* + ? {n} {n,} {n,m}` and their lazy `?` variants
//! - assertions `^ $ \b \B (?= ) (?! ) (?<= ) (?<! )`
//! - `.`, character classes `[...]` / `[^...]` with ranges
//! - escapes `\d \D \w \W \s \S \p{..} \P{..} \t \n \v \f \r \0 \cX \xHH
//!   \uHHHH \u{H..}`, backreferences `\1` / `\k<name>`
//!
//! There are no flags: JSON Schema patterns are never case-insensitive or
//! multi-line, and are not implicitly anchored (`isMatch` searches).

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode_data = @import("unicode_data.zig");

pub const Error = error{InvalidRegex} || Allocator.Error;

/// Matching gave up: it exceeded its step budget, or the backtracking
/// stack exceeded `max_backtrack_frames` (see `Regex.isMatchLimited`).
pub const MatchError = error{RegexLimitExceeded} || Allocator.Error;

/// Default budget of steps per `isMatch` call, about 10 per input
/// character for ordinary patterns (so inputs of about a million
/// characters), and tens of milliseconds at worst.
pub const default_step_limit = 10_000_000;

/// Bound on the backtracking VM's stack (16 bytes per entry), independent of
/// the step budget.
pub const max_backtrack_frames = 1 << 20;

const max_repeat_expansion = 1000;

const Set = union(enum) {
    digit,
    word,
    space,
    property: []const []const unicode_data.Range,
};

const ClassItem = union(enum) {
    range: struct { lo: u21, hi: u21 },
    set: struct { set: Set, negated: bool },
};

const Class = struct {
    items: []const ClassItem,
    negated: bool,
};

const Inst = union(enum) {
    char: u21,
    any,
    class: u32,
    /// Try `x` first, then `y`.
    split: struct { x: u32, y: u32 },
    jmp: u32,
    save: u32,
    line_start,
    line_end,
    word_boundary: bool,
    /// Run the sub-program [start, end) as a zero-width assertion.
    look: struct { start: u32, end: u32, behind: bool, negated: bool },
    backref: u32,
    /// Stores the current position in a loop register (for empty-loop checks).
    mark: u32,
    /// Fails if the position did not advance since the matching `mark`.
    progress: u32,
    /// Succeeds only if the current position equals the lookbehind target.
    at_end_of_look,
    match,
};

pub const Regex = struct {
    insts: []const Inst,
    classes: []const Class,
    n_saves: u32,
    n_regs: u32,
    /// Backreferences and lookarounds need the backtracking VM; every other
    /// pattern is matched by NFA simulation in linear time.
    needs_backtracking: bool,

    /// Compiles `pattern`. Memory is owned by `allocator` (an arena is
    /// recommended; there is no `deinit`).
    pub fn compile(allocator: Allocator, pattern: []const u8) Error!Regex {
        const cps = decodeUtf8(allocator, pattern) catch return error.InvalidRegex;
        var parser: Parser = .{ .allocator = allocator, .src = cps };
        parser.countGroups();
        const ast = try parser.parseDisjunction();
        if (parser.pos != cps.len) return error.InvalidRegex;
        try parser.checkBackrefs();

        var c: Compiler = .{ .allocator = allocator, .group_names = parser.group_names.items };
        // Implicit group 0 around the whole pattern.
        try c.emit(.{ .save = 0 });
        try c.compileNode(ast);
        try c.emit(.{ .save = 1 });
        try c.emit(.match);
        const insts = try c.insts.toOwnedSlice(allocator);
        const needs_backtracking = for (insts) |inst| switch (inst) {
            .look, .backref, .at_end_of_look => break true,
            else => {},
        } else false;
        return .{
            .insts = insts,
            .classes = parser.classes.items,
            .n_saves = (parser.group_count + 1) * 2,
            .n_regs = c.n_regs,
            .needs_backtracking = needs_backtracking,
        };
    }

    /// Whether `pattern` is a syntactically valid ECMA-262 regex.
    pub fn isValid(allocator: Allocator, pattern: []const u8) Allocator.Error!bool {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = compile(arena.allocator(), pattern) catch |err| switch (err) {
            error.InvalidRegex => return false,
            else => |e| return e,
        };
        return true;
    }

    /// Returns true if the regex matches anywhere in `input` (UTF-8), within
    /// `default_step_limit` steps.
    pub fn isMatch(self: *const Regex, allocator: Allocator, input: []const u8) MatchError!bool {
        return self.isMatchLimited(allocator, input, default_step_limit);
    }

    /// Like `isMatch`, but gives up with `error.RegexLimitExceeded` after
    /// `step_limit` steps (for the whole search, over every start position).
    ///
    /// Patterns without backreferences and lookarounds (almost all JSON
    /// Schema patterns) run in O(input × pattern) time and O(pattern)
    /// memory, so catastrophic backtracking (`^(a+)+$`) cannot happen to
    /// them. The others use a backtracking VM, which the budget bounds.
    pub fn isMatchLimited(self: *const Regex, allocator: Allocator, input: []const u8, step_limit: usize) MatchError!bool {
        const cps = decodeUtf8(allocator, input) catch blk: {
            // Not valid UTF-8: fall back to treating each byte as a code point.
            const buf = try allocator.alloc(u21, input.len);
            for (input, 0..) |b, i| buf[i] = b;
            break :blk buf;
        };
        defer allocator.free(cps);
        if (!self.needs_backtracking) return self.simulate(allocator, cps, step_limit);
        return self.backtrack(allocator, cps, step_limit);
    }

    fn backtrack(self: *const Regex, allocator: Allocator, cps: []const u21, step_limit: usize) MatchError!bool {
        const saves = try allocator.alloc(usize, self.n_saves);
        defer allocator.free(saves);
        const regs = try allocator.alloc(usize, self.n_regs);
        defer allocator.free(regs);

        var vm: Vm = .{
            .re = self,
            .input = cps,
            .saves = saves,
            .regs = regs,
            .allocator = allocator,
            .step_limit = step_limit,
        };
        defer vm.stack.deinit(allocator);
        @memset(saves, std.math.maxInt(usize));
        @memset(regs, std.math.maxInt(usize));
        var start: usize = 0;
        while (start <= cps.len) : (start += 1) {
            // A failed run leaves the registers as it found them (unset).
            if (try vm.run(0, start, null)) return true;
        }
        return false;
    }

    /// Thompson NFA simulation: all threads advance in lock step over the
    /// input, each program counter at most once per position, so the time is
    /// O(input × program) and the memory O(program), whatever the pattern.
    /// Only whether a match exists is computed (captures, priorities and
    /// the empty-loop checks do not change that for these patterns).
    fn simulate(self: *const Regex, allocator: Allocator, input: []const u21, step_limit: usize) MatchError!bool {
        const n = self.insts.len;
        var current = try allocator.alloc(u32, n);
        defer allocator.free(current);
        var next = try allocator.alloc(u32, n);
        defer allocator.free(next);
        // `seen[pc] == sp + 1` once pc was added at position sp.
        const seen = try allocator.alloc(usize, n);
        defer allocator.free(seen);
        @memset(seen, 0);
        const pending = try allocator.alloc(u32, n);
        defer allocator.free(pending);

        var sim: Simulation = .{ .re = self, .input = input, .seen = seen, .pending = pending, .step_limit = step_limit };
        var current_len: usize = 0;
        var sp: usize = 0;
        while (true) : (sp += 1) {
            // Unanchored search: a match may start at every position.
            if (try sim.add(current, &current_len, 0, sp)) return true;
            if (sp == input.len) return false;
            var next_len: usize = 0;
            for (current[0..current_len]) |pc| {
                const c = input[sp];
                const consumes = switch (self.insts[pc]) {
                    .char => |ch| ch == c,
                    .any => !isLineTerminator(c),
                    .class => |i| classContains(self.classes[i], c),
                    else => unreachable,
                };
                if (consumes and try sim.add(next, &next_len, pc + 1, sp + 1)) return true;
            }
            std.mem.swap([]u32, &current, &next);
            current_len = next_len;
        }
    }
};

const Simulation = struct {
    re: *const Regex,
    input: []const u21,
    seen: []usize,
    pending: []u32,
    steps: usize = 0,
    step_limit: usize,

    /// Adds `pc` and everything reachable from it without consuming input
    /// (at position `sp`) to `list`. Returns true on reaching `.match`.
    fn add(sim: *Simulation, list: []u32, len: *usize, pc: u32, sp: usize) MatchError!bool {
        var top: usize = 0;
        if (sim.visit(pc, sp)) {
            sim.pending[top] = pc;
            top += 1;
        }
        while (top > 0) {
            top -= 1;
            const at = sim.pending[top];
            sim.steps += 1;
            if (sim.steps > sim.step_limit) return error.RegexLimitExceeded;
            const follow: [2]?u32 = switch (sim.re.insts[at]) {
                .match => return true,
                .char, .any, .class => {
                    list[len.*] = at;
                    len.* += 1;
                    continue;
                },
                .jmp => |t| .{ t, null },
                // Push `y` first so `x` is explored first (order only
                // matters for efficiency here).
                .split => |s| .{ s.y, s.x },
                .save, .mark, .progress => .{ at + 1, null },
                .line_start => if (sp == 0) .{ at + 1, null } else continue,
                .line_end => if (sp == sim.input.len) .{ at + 1, null } else continue,
                .word_boundary => |want| blk: {
                    const a = sp > 0 and isWord(sim.input[sp - 1]);
                    const b = sp < sim.input.len and isWord(sim.input[sp]);
                    break :blk if ((a != b) == want) .{ at + 1, null } else continue;
                },
                .look, .backref, .at_end_of_look => unreachable, // needs_backtracking
            };
            for (follow) |maybe| if (maybe) |t| if (sim.visit(t, sp)) {
                sim.pending[top] = t;
                top += 1;
            };
        }
        return false;
    }

    fn visit(sim: *Simulation, pc: u32, sp: usize) bool {
        if (sim.seen[pc] == sp + 1) return false;
        sim.seen[pc] = sp + 1;
        return true;
    }
};

fn decodeUtf8(allocator: Allocator, s: []const u8) ![]u21 {
    var list: std.ArrayList(u21) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const len = try std.unicode.utf8ByteSequenceLength(s[i]);
        if (i + len > s.len) return error.InvalidUtf8;
        const cp = try std.unicode.utf8Decode(s[i .. i + len]);
        try list.append(allocator, cp);
        i += len;
    }
    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: u32,
    concat: []const Node,
    alt: []const Node,
    group: struct { index: ?u32, body: *const Node },
    repeat: struct { body: *const Node, min: u32, max: ?u32, greedy: bool },
    line_start,
    line_end,
    word_boundary: bool,
    look: struct { body: *const Node, behind: bool, negated: bool },
    backref: u32,
    named_backref: []const u21,
};

const GroupName = struct { name: []const u21, index: u32 };

const Parser = struct {
    allocator: Allocator,
    src: []const u21,
    pos: usize = 0,
    classes: std.ArrayList(Class) = .empty,
    group_count: u32 = 0,
    next_group: u32 = 1,
    group_names: std.ArrayList(GroupName) = .empty,
    max_backref: u32 = 0,
    has_named_backref: bool = false,

    fn peek(p: *Parser) ?u21 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn peekAt(p: *Parser, off: usize) ?u21 {
        return if (p.pos + off < p.src.len) p.src[p.pos + off] else null;
    }

    fn eat(p: *Parser, c: u21) bool {
        if (p.peek() == c) {
            p.pos += 1;
            return true;
        }
        return false;
    }

    /// Pre-scan for the number of capturing groups so `\N` can be told
    /// apart from an octal/identity escape.
    fn countGroups(p: *Parser) void {
        var i: usize = 0;
        var in_class = false;
        while (i < p.src.len) : (i += 1) {
            const c = p.src[i];
            if (c == '\\') {
                i += 1;
            } else if (in_class) {
                if (c == ']') in_class = false;
            } else if (c == '[') {
                in_class = true;
            } else if (c == '(') {
                if (i + 1 < p.src.len and p.src[i + 1] == '?') {
                    if (i + 2 < p.src.len and p.src[i + 2] == '<' and i + 3 < p.src.len and
                        p.src[i + 3] != '=' and p.src[i + 3] != '!')
                    {
                        p.group_count += 1;
                    }
                } else {
                    p.group_count += 1;
                }
            }
        }
    }

    fn checkBackrefs(p: *Parser) Error!void {
        if (p.max_backref > p.group_count) return error.InvalidRegex;
    }

    fn box(p: *Parser, n: Node) Error!*const Node {
        const ptr = try p.allocator.create(Node);
        ptr.* = n;
        return ptr;
    }

    fn parseDisjunction(p: *Parser) Error!Node {
        var alts: std.ArrayList(Node) = .empty;
        try alts.append(p.allocator, try p.parseAlternative());
        while (p.eat('|')) {
            try alts.append(p.allocator, try p.parseAlternative());
        }
        if (alts.items.len == 1) return alts.items[0];
        return .{ .alt = alts.items };
    }

    fn parseAlternative(p: *Parser) Error!Node {
        var terms: std.ArrayList(Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            try terms.append(p.allocator, try p.parseTerm());
        }
        if (terms.items.len == 0) return .empty;
        if (terms.items.len == 1) return terms.items[0];
        return .{ .concat = terms.items };
    }

    fn parseTerm(p: *Parser) Error!Node {
        const c = p.peek().?;
        switch (c) {
            '^' => {
                p.pos += 1;
                return .line_start;
            },
            '$' => {
                p.pos += 1;
                return .line_end;
            },
            '\\' => {
                if (p.peekAt(1) == 'b') {
                    p.pos += 2;
                    return .{ .word_boundary = true };
                }
                if (p.peekAt(1) == 'B') {
                    p.pos += 2;
                    return .{ .word_boundary = false };
                }
            },
            '(' => {
                if (p.peekAt(1) == '?') {
                    const k = p.peekAt(2);
                    const k2 = p.peekAt(3);
                    const look: ?struct { behind: bool, negated: bool, len: usize } =
                        if (k == '=') .{ .behind = false, .negated = false, .len = 3 } else if (k == '!') .{ .behind = false, .negated = true, .len = 3 } else if (k == '<' and k2 == '=') .{ .behind = true, .negated = false, .len = 4 } else if (k == '<' and k2 == '!') .{ .behind = true, .negated = true, .len = 4 } else null;
                    if (look) |l| {
                        p.pos += l.len;
                        const body = try p.parseDisjunction();
                        if (!p.eat(')')) return error.InvalidRegex;
                        const node: Node = .{ .look = .{ .body = try p.box(body), .behind = l.behind, .negated = l.negated } };
                        // Annex B allows quantified lookaheads; accept but
                        // treat them as the assertion itself.
                        if (!l.behind and p.isQuantifierStart()) {
                            return p.parseQuantifier(node);
                        }
                        return node;
                    }
                }
            },
            else => {},
        }
        const atom = try p.parseAtom();
        return p.parseQuantifier(atom);
    }

    fn isQuantifierStart(p: *Parser) bool {
        const c = p.peek() orelse return false;
        if (c == '*' or c == '+' or c == '?') return true;
        if (c == '{') {
            var tmp = p.*;
            return tmp.parseBraceQuantifier() != null;
        }
        return false;
    }

    fn parseBraceQuantifier(p: *Parser) ?struct { min: u32, max: ?u32 } {
        const save = p.pos;
        if (!p.eat('{')) return null;
        const min = p.parseDecimal() orelse {
            p.pos = save;
            return null;
        };
        var max: ?u32 = min;
        if (p.eat(',')) {
            max = p.parseDecimal();
        }
        if (!p.eat('}')) {
            p.pos = save;
            return null;
        }
        return .{ .min = min, .max = max };
    }

    fn parseDecimal(p: *Parser) ?u32 {
        const start = p.pos;
        var v: u64 = 0;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            v = @min(v * 10 + (c - '0'), std.math.maxInt(u32));
            p.pos += 1;
        }
        if (p.pos == start) return null;
        return @intCast(v);
    }

    fn parseQuantifier(p: *Parser, atom: Node) Error!Node {
        const c = p.peek() orelse return atom;
        var min: u32 = undefined;
        var max: ?u32 = undefined;
        switch (c) {
            '*' => {
                p.pos += 1;
                min = 0;
                max = null;
            },
            '+' => {
                p.pos += 1;
                min = 1;
                max = null;
            },
            '?' => {
                p.pos += 1;
                min = 0;
                max = 1;
            },
            '{' => {
                const q = p.parseBraceQuantifier() orelse return error.InvalidRegex;
                min = q.min;
                max = q.max;
                if (max) |m| if (m < min) return error.InvalidRegex;
            },
            else => return atom,
        }
        const greedy = !p.eat('?');
        switch (atom) {
            .line_start, .line_end, .word_boundary => return error.InvalidRegex,
            else => {},
        }
        return .{ .repeat = .{ .body = try p.box(atom), .min = min, .max = max, .greedy = greedy } };
    }

    fn parseAtom(p: *Parser) Error!Node {
        const c = p.peek().?;
        switch (c) {
            '.' => {
                p.pos += 1;
                return .any;
            },
            '(' => {
                p.pos += 1;
                var index: ?u32 = null;
                if (p.eat('?')) {
                    if (p.eat(':')) {
                        index = null;
                    } else if (p.eat('<')) {
                        const name = try p.parseGroupName();
                        for (p.group_names.items) |g| {
                            if (std.mem.eql(u21, g.name, name)) return error.InvalidRegex;
                        }
                        index = p.next_group;
                        p.next_group += 1;
                        try p.group_names.append(p.allocator, .{ .name = name, .index = index.? });
                    } else return error.InvalidRegex;
                } else {
                    index = p.next_group;
                    p.next_group += 1;
                }
                const body = try p.parseDisjunction();
                if (!p.eat(')')) return error.InvalidRegex;
                return .{ .group = .{ .index = index, .body = try p.box(body) } };
            },
            '[' => return p.parseClass(),
            '\\' => return p.parseAtomEscape(),
            '*', '+', '?', ')', '|' => return error.InvalidRegex,
            '{' => {
                // A `{` that does not start a valid quantifier is an error in
                // unicode mode.
                return error.InvalidRegex;
            },
            '}', ']' => return error.InvalidRegex,
            else => {
                p.pos += 1;
                return .{ .char = c };
            },
        }
    }

    fn parseGroupName(p: *Parser) Error![]const u21 {
        const start = p.pos;
        while (p.peek()) |c| {
            if (c == '>') break;
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or
                (p.pos > start and c >= '0' and c <= '9') or c > 0x7F;
            if (!ok) return error.InvalidRegex;
            p.pos += 1;
        }
        if (p.pos == start or !p.eat('>')) return error.InvalidRegex;
        return p.src[start .. p.pos - 1];
    }

    fn parseAtomEscape(p: *Parser) Error!Node {
        p.pos += 1; // '\'
        const c = p.peek() orelse return error.InvalidRegex;
        if (c >= '1' and c <= '9') {
            const n = p.parseDecimal().?;
            if (n > p.max_backref) p.max_backref = n;
            return .{ .backref = n };
        }
        if (c == 'k') {
            p.pos += 1;
            if (!p.eat('<')) return error.InvalidRegex;
            const name = try p.parseGroupName();
            p.has_named_backref = true;
            return .{ .named_backref = name };
        }
        if (try p.parseClassEscape()) |item| {
            return .{ .class = try p.addClass(&.{item}, false) };
        }
        return .{ .char = try p.parseCharacterEscape(false) };
    }

    /// `\d \D \w \W \s \S \p{..} \P{..}` (the leading `\` already consumed).
    fn parseClassEscape(p: *Parser) Error!?ClassItem {
        const c = p.peek() orelse return error.InvalidRegex;
        const set: ?struct { set: Set, negated: bool } = switch (c) {
            'd' => .{ .set = .digit, .negated = false },
            'D' => .{ .set = .digit, .negated = true },
            'w' => .{ .set = .word, .negated = false },
            'W' => .{ .set = .word, .negated = true },
            's' => .{ .set = .space, .negated = false },
            'S' => .{ .set = .space, .negated = true },
            'p', 'P' => {
                p.pos += 1;
                if (!p.eat('{')) return error.InvalidRegex;
                const start = p.pos;
                while (p.peek()) |ch| {
                    if (ch == '}') break;
                    p.pos += 1;
                }
                if (!p.eat('}')) return error.InvalidRegex;
                const ranges = try lookupProperty(p.allocator, p.src[start .. p.pos - 1]);
                return .{ .set = .{ .set = .{ .property = ranges }, .negated = c == 'P' } };
            },
            else => null,
        };
        if (set) |s| {
            p.pos += 1;
            return .{ .set = .{ .set = s.set, .negated = s.negated } };
        }
        return null;
    }

    fn parseCharacterEscape(p: *Parser, in_class: bool) Error!u21 {
        const c = p.peek() orelse return error.InvalidRegex;
        p.pos += 1;
        switch (c) {
            't' => return '\t',
            'n' => return '\n',
            'v' => return 0x0B,
            'f' => return 0x0C,
            'r' => return '\r',
            'c' => {
                const l = p.peek() orelse return error.InvalidRegex;
                if ((l >= 'a' and l <= 'z') or (l >= 'A' and l <= 'Z')) {
                    p.pos += 1;
                    return l % 32;
                }
                return error.InvalidRegex;
            },
            '0' => {
                if (p.peek()) |d| if (d >= '0' and d <= '9') return error.InvalidRegex;
                return 0;
            },
            'x' => return p.parseHex(2) orelse error.InvalidRegex,
            'u' => {
                if (p.eat('{')) {
                    var v: u32 = 0;
                    var n: usize = 0;
                    while (p.peek()) |h| {
                        const d = hexVal(h) orelse break;
                        v = v * 16 + d;
                        if (v > 0x10FFFF) return error.InvalidRegex;
                        n += 1;
                        p.pos += 1;
                    }
                    if (n == 0 or !p.eat('}')) return error.InvalidRegex;
                    return @intCast(v);
                }
                const hi = p.parseHex(4) orelse return error.InvalidRegex;
                if (hi >= 0xD800 and hi <= 0xDBFF and p.peek() == '\\' and p.peekAt(1) == 'u') {
                    const save = p.pos;
                    p.pos += 2;
                    if (p.parseHex(4)) |lo| {
                        if (lo >= 0xDC00 and lo <= 0xDFFF) {
                            return @intCast(0x10000 + ((@as(u32, hi) - 0xD800) << 10) + (lo - 0xDC00));
                        }
                    }
                    p.pos = save;
                }
                return hi;
            },
            '-' => {
                if (in_class) return '-';
                return error.InvalidRegex;
            },
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => return c,
            else => return error.InvalidRegex,
        }
    }

    fn parseHex(p: *Parser, n: usize) ?u21 {
        var v: u21 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const d = hexVal(p.peekAt(i) orelse return null) orelse return null;
            v = v * 16 + @as(u21, @intCast(d));
        }
        p.pos += n;
        return v;
    }

    fn addClass(p: *Parser, items: []const ClassItem, negated: bool) Error!u32 {
        const owned = try p.allocator.dupe(ClassItem, items);
        try p.classes.append(p.allocator, .{ .items = owned, .negated = negated });
        return @intCast(p.classes.items.len - 1);
    }

    fn parseClass(p: *Parser) Error!Node {
        p.pos += 1; // '['
        const negated = p.eat('^');
        var items: std.ArrayList(ClassItem) = .empty;
        while (true) {
            const c = p.peek() orelse return error.InvalidRegex;
            if (c == ']') {
                p.pos += 1;
                break;
            }
            const a = try p.parseClassAtom();
            if (p.peek() == '-' and p.peekAt(1) != null and p.peekAt(1) != ']') {
                p.pos += 1;
                const b = try p.parseClassAtom();
                if (a != .range or b != .range) return error.InvalidRegex;
                if (a.range.lo > b.range.lo) return error.InvalidRegex;
                try items.append(p.allocator, .{ .range = .{ .lo = a.range.lo, .hi = b.range.lo } });
            } else {
                try items.append(p.allocator, a);
            }
        }
        return .{ .class = try p.addClass(items.items, negated) };
    }

    fn parseClassAtom(p: *Parser) Error!ClassItem {
        const c = p.peek().?;
        if (c == '\\') {
            p.pos += 1;
            if (try p.parseClassEscape()) |item| return item;
            if (p.peek() == 'b') {
                p.pos += 1;
                return .{ .range = .{ .lo = 0x08, .hi = 0x08 } };
            }
            const ch = try p.parseCharacterEscape(true);
            return .{ .range = .{ .lo = ch, .hi = ch } };
        }
        p.pos += 1;
        return .{ .range = .{ .lo = c, .hi = c } };
    }
};

fn hexVal(c: u21) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

const category_aliases = [_]struct { long: []const u8, short: []const u8 }{
    .{ .long = "Letter", .short = "L" },
    .{ .long = "Cased_Letter", .short = "LC" },
    .{ .long = "Uppercase_Letter", .short = "Lu" },
    .{ .long = "Lowercase_Letter", .short = "Ll" },
    .{ .long = "Titlecase_Letter", .short = "Lt" },
    .{ .long = "Modifier_Letter", .short = "Lm" },
    .{ .long = "Other_Letter", .short = "Lo" },
    .{ .long = "Mark", .short = "M" },
    .{ .long = "Combining_Mark", .short = "M" },
    .{ .long = "Nonspacing_Mark", .short = "Mn" },
    .{ .long = "Spacing_Mark", .short = "Mc" },
    .{ .long = "Enclosing_Mark", .short = "Me" },
    .{ .long = "Number", .short = "N" },
    .{ .long = "Decimal_Number", .short = "Nd" },
    .{ .long = "digit", .short = "Nd" },
    .{ .long = "Letter_Number", .short = "Nl" },
    .{ .long = "Other_Number", .short = "No" },
    .{ .long = "Punctuation", .short = "P" },
    .{ .long = "punct", .short = "P" },
    .{ .long = "Connector_Punctuation", .short = "Pc" },
    .{ .long = "Dash_Punctuation", .short = "Pd" },
    .{ .long = "Open_Punctuation", .short = "Ps" },
    .{ .long = "Close_Punctuation", .short = "Pe" },
    .{ .long = "Initial_Punctuation", .short = "Pi" },
    .{ .long = "Final_Punctuation", .short = "Pf" },
    .{ .long = "Other_Punctuation", .short = "Po" },
    .{ .long = "Symbol", .short = "S" },
    .{ .long = "Math_Symbol", .short = "Sm" },
    .{ .long = "Currency_Symbol", .short = "Sc" },
    .{ .long = "Modifier_Symbol", .short = "Sk" },
    .{ .long = "Other_Symbol", .short = "So" },
    .{ .long = "Separator", .short = "Z" },
    .{ .long = "Space_Separator", .short = "Zs" },
    .{ .long = "Line_Separator", .short = "Zl" },
    .{ .long = "Paragraph_Separator", .short = "Zp" },
    .{ .long = "Other", .short = "C" },
    .{ .long = "Control", .short = "Cc" },
    .{ .long = "cntrl", .short = "Cc" },
    .{ .long = "Format", .short = "Cf" },
    .{ .long = "Surrogate", .short = "Cs" },
    .{ .long = "Private_Use", .short = "Co" },
    .{ .long = "Unassigned", .short = "Cn" },
};

const any_range = [_]unicode_data.Range{.{ .lo = 0, .hi = 0x10FFFF }};
const ascii_range = [_]unicode_data.Range{.{ .lo = 0, .hi = 0x7F }};

/// Resolves a `\p{...}` property name to the list of range tables it covers.
fn lookupProperty(allocator: Allocator, name_cps: []const u21) Error![]const []const unicode_data.Range {
    var buf: [64]u8 = undefined;
    if (name_cps.len > buf.len) return error.InvalidRegex;
    for (name_cps, 0..) |c, i| {
        if (c > 0x7F) return error.InvalidRegex;
        buf[i] = @intCast(c);
    }
    var name: []const u8 = buf[0..name_cps.len];
    if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
        const key = name[0..eq];
        if (!std.mem.eql(u8, key, "General_Category") and !std.mem.eql(u8, key, "gc")) return error.InvalidRegex;
        name = name[eq + 1 ..];
    } else {
        if (std.mem.eql(u8, name, "Any")) return try allocator.dupe([]const unicode_data.Range, &.{&any_range});
        if (std.mem.eql(u8, name, "ASCII")) return try allocator.dupe([]const unicode_data.Range, &.{&ascii_range});
    }
    for (category_aliases) |a| {
        if (std.mem.eql(u8, a.long, name)) {
            name = a.short;
            break;
        }
    }
    var tables: std.ArrayList([]const unicode_data.Range) = .empty;
    if (std.mem.eql(u8, name, "LC")) {
        for ([_][]const u8{ "Lu", "Ll", "Lt" }) |sub| try tables.append(allocator, findCategory(sub).?);
    } else if (name.len == 1) {
        for (unicode_data.categories) |cat| {
            if (cat.name[0] == name[0]) try tables.append(allocator, cat.ranges);
        }
    } else if (findCategory(name)) |r| {
        try tables.append(allocator, r);
    }
    if (tables.items.len == 0) return error.InvalidRegex;
    return tables.items;
}

fn findCategory(name: []const u8) ?[]const unicode_data.Range {
    for (unicode_data.categories) |cat| {
        if (std.mem.eql(u8, cat.name, name)) return cat.ranges;
    }
    return null;
}

fn inRanges(ranges: []const unicode_data.Range, c: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (c < ranges[mid].lo) {
            hi = mid;
        } else if (c > ranges[mid].hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

fn isWord(c: u21) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isSpace(c: u21) bool {
    return switch (c) {
        0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

fn isLineTerminator(c: u21) bool {
    return c == '\n' or c == '\r' or c == 0x2028 or c == 0x2029;
}

fn setContains(set: Set, c: u21) bool {
    return switch (set) {
        .digit => c >= '0' and c <= '9',
        .word => isWord(c),
        .space => isSpace(c),
        .property => |tables| for (tables) |t| {
            if (inRanges(t, c)) break true;
        } else false,
    };
}

fn classContains(class: Class, c: u21) bool {
    var found = false;
    for (class.items) |item| {
        switch (item) {
            .range => |r| if (c >= r.lo and c <= r.hi) {
                found = true;
            },
            .set => |s| if (setContains(s.set, c) != s.negated) {
                found = true;
            },
        }
        if (found) break;
    }
    return found != class.negated;
}

// ---------------------------------------------------------------------------
// Compiler (AST -> VM instructions)
// ---------------------------------------------------------------------------

const Compiler = struct {
    allocator: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    n_regs: u32 = 0,
    group_names: []const GroupName = &.{},

    fn emit(c: *Compiler, inst: Inst) Error!void {
        try c.insts.append(c.allocator, inst);
    }

    fn pc(c: *Compiler) u32 {
        return @intCast(c.insts.items.len);
    }

    fn compileNode(c: *Compiler, node: Node) Error!void {
        if (c.insts.items.len > 200_000) return error.InvalidRegex;
        switch (node) {
            .empty => {},
            .char => |ch| try c.emit(.{ .char = ch }),
            .any => try c.emit(.any),
            .class => |i| try c.emit(.{ .class = i }),
            .concat => |nodes| for (nodes) |n| try c.compileNode(n),
            .alt => |nodes| {
                var jumps: std.ArrayList(u32) = .empty;
                for (nodes, 0..) |n, i| {
                    if (i + 1 < nodes.len) {
                        const split = c.pc();
                        try c.emit(.{ .split = .{ .x = split + 1, .y = 0 } });
                        try c.compileNode(n);
                        try jumps.append(c.allocator, c.pc());
                        try c.emit(.{ .jmp = 0 });
                        c.insts.items[split].split.y = c.pc();
                    } else {
                        try c.compileNode(n);
                    }
                }
                for (jumps.items) |j| c.insts.items[j] = .{ .jmp = c.pc() };
            },
            .group => |g| {
                if (g.index) |idx| try c.emit(.{ .save = idx * 2 });
                try c.compileNode(g.body.*);
                if (g.index) |idx| try c.emit(.{ .save = idx * 2 + 1 });
            },
            .repeat => |r| try c.compileRepeat(r.body.*, r.min, r.max, r.greedy),
            .line_start => try c.emit(.line_start),
            .line_end => try c.emit(.line_end),
            .word_boundary => |b| try c.emit(.{ .word_boundary = b }),
            .look => |l| {
                const at = c.pc();
                try c.emit(.{ .look = .{ .start = at + 1, .end = 0, .behind = l.behind, .negated = l.negated } });
                try c.compileNode(l.body.*);
                if (l.behind) try c.emit(.at_end_of_look);
                try c.emit(.match);
                c.insts.items[at].look.end = c.pc();
            },
            .backref => |n| try c.emit(.{ .backref = n }),
            .named_backref => |name| {
                for (c.group_names) |g| {
                    if (std.mem.eql(u21, g.name, name)) return c.emit(.{ .backref = g.index });
                }
                return error.InvalidRegex;
            },
        }
    }

    fn compileRepeat(c: *Compiler, body: Node, min: u32, max: ?u32, greedy: bool) Error!void {
        if (min > max_repeat_expansion) return error.InvalidRegex;
        if (max) |m| if (m > max_repeat_expansion) return error.InvalidRegex;

        var i: u32 = 0;
        while (i < min) : (i += 1) try c.compileNode(body);

        if (max) |m| {
            // Optional copies: (body (body (...)?)?)?
            var patches: std.ArrayList(u32) = .empty;
            var k: u32 = min;
            while (k < m) : (k += 1) {
                const split = c.pc();
                try c.emit(.{ .split = .{ .x = 0, .y = 0 } });
                try patches.append(c.allocator, split);
                const reg = c.n_regs;
                c.n_regs += 1;
                try c.emit(.{ .mark = reg });
                try c.compileNode(body);
                try c.emit(.{ .progress = reg });
                if (greedy) {
                    c.insts.items[split].split.x = split + 1;
                } else {
                    c.insts.items[split].split.y = split + 1;
                }
            }
            const end = c.pc();
            for (patches.items) |s| {
                if (greedy) c.insts.items[s].split.y = end else c.insts.items[s].split.x = end;
            }
        } else {
            // L: split body, end; body; jmp L
            const split = c.pc();
            try c.emit(.{ .split = .{ .x = 0, .y = 0 } });
            const reg = c.n_regs;
            c.n_regs += 1;
            try c.emit(.{ .mark = reg });
            try c.compileNode(body);
            try c.emit(.{ .progress = reg });
            try c.emit(.{ .jmp = split });
            const end = c.pc();
            if (greedy) {
                c.insts.items[split].split = .{ .x = split + 1, .y = end };
            } else {
                c.insts.items[split].split = .{ .x = end, .y = split + 1 };
            }
        }
    }
};

// ---------------------------------------------------------------------------
// VM
// ---------------------------------------------------------------------------

/// An entry of the backtracking stack: a branch to resume, or an undo
/// record for a capture / loop register written since the last branch.
const Frame = struct {
    kind: enum(u8) { branch, save, reg },
    /// Branch: program counter. Undo: the register index.
    index: u32,
    /// Branch: input position. Undo: the previous register value.
    value: usize,
};

const Vm = struct {
    re: *const Regex,
    input: []const u21,
    saves: []usize,
    regs: []usize,
    allocator: Allocator,
    stack: std.ArrayList(Frame) = .empty,
    steps: usize = 0,
    step_limit: usize,

    /// Runs from `pc` at `sp` until `.match` (true) or until every branch
    /// failed (false, with every register restored). `look_target` is the
    /// required end position when running a lookbehind body.
    ///
    /// Backtracking uses `stack` rather than recursion, so the native stack
    /// depth is bounded by the pattern's lookaround nesting, not the input.
    fn run(vm: *Vm, start_pc: u32, start_sp: usize, look_target: ?usize) MatchError!bool {
        const base = vm.stack.items.len;
        var pc = start_pc;
        var sp = start_sp;
        while (true) {
            vm.steps += 1;
            if (vm.steps > vm.step_limit) return error.RegexLimitExceeded;
            const ok = switch (vm.re.insts[pc]) {
                .match => {
                    // A sub-run (lookaround) is atomic: its branches are
                    // dropped, but its undo records stay so that an outer
                    // backtrack still restores what it captured.
                    vm.dropBranches(base);
                    return true;
                },
                .char => |ch| blk: {
                    if (sp >= vm.input.len or vm.input[sp] != ch) break :blk false;
                    sp += 1;
                    pc += 1;
                    break :blk true;
                },
                .any => blk: {
                    if (sp >= vm.input.len or isLineTerminator(vm.input[sp])) break :blk false;
                    sp += 1;
                    pc += 1;
                    break :blk true;
                },
                .class => |i| blk: {
                    if (sp >= vm.input.len or !classContains(vm.re.classes[i], vm.input[sp])) break :blk false;
                    sp += 1;
                    pc += 1;
                    break :blk true;
                },
                .jmp => |t| blk: {
                    pc = t;
                    break :blk true;
                },
                .split => |s| blk: {
                    try vm.push(.{ .kind = .branch, .index = s.y, .value = sp });
                    pc = s.x;
                    break :blk true;
                },
                .save => |n| blk: {
                    try vm.push(.{ .kind = .save, .index = n, .value = vm.saves[n] });
                    vm.saves[n] = sp;
                    pc += 1;
                    break :blk true;
                },
                .mark => |r| blk: {
                    try vm.push(.{ .kind = .reg, .index = r, .value = vm.regs[r] });
                    vm.regs[r] = sp;
                    pc += 1;
                    break :blk true;
                },
                .progress => |r| blk: {
                    if (vm.regs[r] == sp) break :blk false;
                    pc += 1;
                    break :blk true;
                },
                .line_start => blk: {
                    if (sp != 0) break :blk false;
                    pc += 1;
                    break :blk true;
                },
                .line_end => blk: {
                    if (sp != vm.input.len) break :blk false;
                    pc += 1;
                    break :blk true;
                },
                .word_boundary => |want| blk: {
                    const a = sp > 0 and isWord(vm.input[sp - 1]);
                    const b = sp < vm.input.len and isWord(vm.input[sp]);
                    if ((a != b) != want) break :blk false;
                    pc += 1;
                    break :blk true;
                },
                .at_end_of_look => blk: {
                    if (look_target == null or sp != look_target.?) break :blk false;
                    pc += 1;
                    break :blk true;
                },
                .look => |l| blk: {
                    // A failed sub-run restores every register itself.
                    var matched = false;
                    if (l.behind) {
                        var k: usize = sp + 1;
                        while (k > 0) {
                            k -= 1;
                            if (try vm.run(l.start, k, sp)) {
                                matched = true;
                                break;
                            }
                        }
                    } else {
                        matched = try vm.run(l.start, sp, null);
                    }
                    // A matched negative lookaround fails here, and the
                    // backtrack below undoes what its body captured.
                    if (matched == l.negated) break :blk false;
                    pc = l.end;
                    break :blk true;
                },
                .backref => |n| blk: {
                    const s = vm.saves[n * 2];
                    const e = vm.saves[n * 2 + 1];
                    if (s != std.math.maxInt(usize) and e != std.math.maxInt(usize) and e >= s) {
                        const len = e - s;
                        if (sp + len > vm.input.len) break :blk false;
                        if (!std.mem.eql(u21, vm.input[s..e], vm.input[sp .. sp + len])) break :blk false;
                        sp += len;
                    }
                    pc += 1;
                    break :blk true;
                },
            };
            if (ok) continue;

            // Backtrack: undo writes until the most recent branch of this run.
            while (true) {
                if (vm.stack.items.len == base) return false;
                const f = vm.stack.pop().?;
                switch (f.kind) {
                    .save => vm.saves[f.index] = f.value,
                    .reg => vm.regs[f.index] = f.value,
                    .branch => {
                        pc = f.index;
                        sp = f.value;
                        break;
                    },
                }
            }
        }
    }

    fn push(vm: *Vm, frame: Frame) MatchError!void {
        if (vm.stack.items.len >= max_backtrack_frames) return error.RegexLimitExceeded;
        try vm.stack.append(vm.allocator, frame);
    }

    fn dropBranches(vm: *Vm, base: usize) void {
        var kept = base;
        for (vm.stack.items[base..]) |f| {
            if (f.kind == .branch) continue;
            vm.stack.items[kept] = f;
            kept += 1;
        }
        vm.stack.shrinkRetainingCapacity(kept);
    }
};

fn testMatch(pattern: []const u8, input: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const re = try Regex.compile(arena.allocator(), pattern);
    return re.isMatch(arena.allocator(), input);
}

test "regex basics" {
    try std.testing.expect(try testMatch("^a*$", "aaa"));
    try std.testing.expect(!try testMatch("^a*$", "aab"));
    try std.testing.expect(try testMatch("f.o", "xfoo"));
    try std.testing.expect(try testMatch("^[0-9]{2,}$", "123"));
    try std.testing.expect(!try testMatch("^[0-9]{2,}$", "1"));
    try std.testing.expect(try testMatch("^(ab|cd)+$", "abcdab"));
    try std.testing.expect(try testMatch("^(a+)b\\1$", "aabaa"));
    try std.testing.expect(!try testMatch("^abc$", "abc\n"));
    try std.testing.expect(try testMatch("^\\p{Letter}+$", "éa"));
    try std.testing.expect(!try testMatch("^\\w$", "é"));
    try std.testing.expect(try testMatch("^\\s$", "\u{feff}"));
    try std.testing.expect(try testMatch("^\\cC$", "\x03"));
    try std.testing.expect(try testMatch("^(?:a*)*$", "aaa"));
    try std.testing.expect(try testMatch("(?<=a)b", "ab"));
    try std.testing.expect(!try testMatch("(?<!a)b", "ab"));
    try std.testing.expect(try testMatch("^🐲*$", "🐲🐲"));
    try std.testing.expect(!try testMatch("^🐲*$", "🐉"));
    try std.testing.expectError(error.InvalidRegex, testMatch("\\a", ""));
    try std.testing.expectError(error.InvalidRegex, testMatch("^(abc]", ""));
}

test "the NFA simulation and the backtracking VM agree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patterns = [_][]const u8{
        "^a*$",                         "a|b",                       "^(ab|cd)+$", "^(?:a*)*$", "^(a|ab)(c|bcd)(d*)$",
        "^[0-9]{2,4}$",                 "x{0,3}y",                   "^.$",        "\\bfoo\\b", "^\\p{L}+\\d*$",
        "(a+)+b",                       "^(a?){3}a{3}$",             "^$",         "[^a-c]+",   "^(?:(a)|b)*?c$",
        "^\\s*[a-z]+(?:-[a-z]+)*\\s*$",
        "é+",
        "\\B.\\B",                      "^[\\u{1F600}-\\u{1F64F}]$",
    };
    const inputs = [_][]const u8{
        "",      "a",      "aaa",  "aab",   "ab",     "abcd", "abcdab", "abcd d", "12",               "12345", "xxxxy", "\n",
        " foo ", "foobar", "ab12", "aaaab", "aaaaaa", "ddd",  "aac",    "bbc",    "  kebab-case-x  ",
        "ééé",
        "abc",
        "😀",
    };
    for (patterns) |pattern| {
        const re = try Regex.compile(a, pattern);
        try std.testing.expect(!re.needs_backtracking);
        for (inputs) |input| {
            const cps = try decodeUtf8(a, input);
            const nfa = try re.simulate(a, cps, default_step_limit);
            const bt = try re.backtrack(a, cps, default_step_limit);
            if (nfa != bt) {
                std.debug.print("/{s}/ on \"{s}\": NFA {}, backtracking {}\n", .{ pattern, input, nfa, bt });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "catastrophic patterns are linear, or stopped by the step limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Exponential for a backtracking engine; linear for the NFA simulation.
    const evil = try a.alloc(u8, 10_000);
    @memset(evil, 'a');
    evil[evil.len - 1] = 'b';
    for ([_][]const u8{ "^(a+)+$", "^(a|a)*$", "^(a|aa)+$", "^(.*a){12}$" }) |pattern| {
        const re = try Regex.compile(a, pattern);
        try std.testing.expect(!try re.isMatch(a, evil));
    }

    // A long input is fine (and does not grow the native stack).
    const long = try a.alloc(u8, 500_000);
    @memset(long, 'x');
    try std.testing.expect(try (try Regex.compile(a, "^(?:x|y)*$")).isMatch(a, long));

    // A backreference forces backtracking: the budget stops it.
    const re = try Regex.compile(a, "^(a+)+\\1$");
    try std.testing.expect(re.needs_backtracking);
    try std.testing.expectError(error.RegexLimitExceeded, re.isMatch(a, evil[evil.len - 40 ..]));
    // Tight budgets apply to the NFA simulation too.
    try std.testing.expectError(error.RegexLimitExceeded, (try Regex.compile(a, "^x*$")).isMatchLimited(a, long, 1000));
}
