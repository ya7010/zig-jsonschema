//! Validators for the JSON Schema `format` keyword. Only applied when
//! format assertion is enabled; unknown formats always pass, and non-string
//! instances always pass.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Regex = @import("regex.zig").Regex;
const idna = @import("idna_data.zig");
const unicode_data = @import("unicode_data.zig");

pub fn check(allocator: Allocator, name: []const u8, value: std.json.Value) Allocator.Error!bool {
    if (value != .string) return true;
    const s = value.string;
    const Checker = *const fn ([]const u8) bool;
    const table = [_]struct { []const u8, Checker }{
        .{ "date-time", isDateTime },
        .{ "date", isDate },
        .{ "time", isTime },
        .{ "duration", isDuration },
        .{ "email", isEmail },
        .{ "idn-email", isIdnEmail },
        .{ "hostname", isHostname },
        .{ "idn-hostname", isIdnHostname },
        .{ "ipv4", isIpv4 },
        .{ "ipv6", isIpv6 },
        .{ "uri", isUri },
        .{ "uri-reference", isUriReference },
        .{ "iri", isIri },
        .{ "iri-reference", isIriReference },
        .{ "uri-template", isUriTemplate },
        .{ "uuid", isUuid },
        .{ "json-pointer", isJsonPointer },
        .{ "relative-json-pointer", isRelativeJsonPointer },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1](s);
    }
    if (std.mem.eql(u8, name, "regex")) return Regex.isValid(allocator, s);
    return true;
}

// --- dates and times (RFC 3339) ---------------------------------------------

fn digits(s: []const u8, n: usize) ?u32 {
    if (s.len < n) return null;
    var v: u32 = 0;
    for (s[0..n]) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn isLeapYear(y: u32) bool {
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

fn daysInMonth(y: u32, m: u32) u32 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(y)) 29 else 28,
        else => 0,
    };
}

pub fn isDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    const y = digits(s[0..4], 4) orelse return false;
    const m = digits(s[5..7], 2) orelse return false;
    const d = digits(s[8..10], 2) orelse return false;
    return m >= 1 and m <= 12 and d >= 1 and d <= daysInMonth(y, m);
}

pub fn isTime(s: []const u8) bool {
    if (s.len < 9 or s[2] != ':' or s[5] != ':') return false;
    const h = digits(s[0..2], 2) orelse return false;
    const min = digits(s[3..5], 2) orelse return false;
    const sec = digits(s[6..8], 2) orelse return false;
    var i: usize = 8;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start) return false;
    }
    if (i >= s.len) return false;
    var off_minutes: i32 = 0;
    if (s[i] == 'Z' or s[i] == 'z') {
        if (i + 1 != s.len) return false;
    } else if (s[i] == '+' or s[i] == '-') {
        const off = s[i + 1 ..];
        if (off.len != 5 or off[2] != ':') return false;
        const oh = digits(off[0..2], 2) orelse return false;
        const om = digits(off[3..5], 2) orelse return false;
        if (oh > 23 or om > 59) return false;
        off_minutes = @intCast(oh * 60 + om);
        if (s[i] == '-') off_minutes = -off_minutes;
    } else return false;
    if (h > 23 or min > 59 or sec > 60) return false;
    if (sec == 60) {
        // A leap second must fall on 23:59:60 UTC.
        var utc: i32 = @as(i32, @intCast(h * 60 + min)) - off_minutes;
        utc = @mod(utc, 24 * 60);
        if (utc != 23 * 60 + 59) return false;
    }
    return true;
}

pub fn isDateTime(s: []const u8) bool {
    if (s.len < 11) return false;
    if (s[10] != 'T' and s[10] != 't') return false;
    return isDate(s[0..10]) and isTime(s[11..]);
}

pub fn isDuration(s: []const u8) bool {
    if (s.len < 2 or s[0] != 'P') return false;
    // Weeks stand alone: "P" 1*DIGIT "W".
    if (s[s.len - 1] == 'W') {
        const n = s[1 .. s.len - 1];
        if (n.len == 0) return false;
        for (n) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    const t = std.mem.indexOfScalar(u8, s, 'T') orelse s.len;
    const date_part = s[1..t];
    if (!durationUnits(date_part, "YMD")) return false;
    if (t < s.len) {
        const time_part = s[t + 1 ..];
        if (time_part.len == 0 or !durationUnits(time_part, "HMS")) return false;
    } else if (date_part.len == 0) return false;
    return true;
}

/// `part` is a run of `1*DIGIT unit` elements whose units are consecutive
/// entries of `units` (e.g. "1Y2M" or "2M3D", but not "1Y3D").
fn durationUnits(part: []const u8, units: []const u8) bool {
    var i: usize = 0;
    var prev: ?usize = null;
    while (i < part.len) {
        const start = i;
        while (i < part.len and std.ascii.isDigit(part[i])) i += 1;
        if (i == start or i >= part.len) return false;
        const u = std.mem.indexOfScalar(u8, units, part[i]) orelse return false;
        if (prev) |p| if (u != p + 1) return false;
        prev = u;
        i += 1;
    }
    return true;
}

// --- network ----------------------------------------------------------------

pub fn isIpv4(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |part| {
        n += 1;
        if (part.len == 0 or part.len > 3) return false;
        for (part) |c| if (c < '0' or c > '9') return false;
        if (part.len > 1 and part[0] == '0') return false;
        const v = std.fmt.parseInt(u16, part, 10) catch return false;
        if (v > 255) return false;
    }
    return n == 4;
}

pub fn isIpv6(s: []const u8) bool {
    if (s.len == 0) return false;
    var groups: usize = 0;
    var double_colon = false;
    var i: usize = 0;
    if (std.mem.startsWith(u8, s, "::")) {
        double_colon = true;
        i = 2;
        if (s.len == 2) return true;
    } else if (s[0] == ':') return false;
    while (i < s.len) {
        // Find the end of this group.
        var j = i;
        while (j < s.len and s[j] != ':') j += 1;
        const part = s[i..j];
        if (part.len == 0) return false;
        if (std.mem.indexOfScalar(u8, part, '.') != null) {
            // Embedded IPv4 must be last.
            if (j != s.len or !isIpv4(part)) return false;
            groups += 2;
            break;
        }
        if (part.len > 4) return false;
        for (part) |c| if (!std.ascii.isHex(c)) return false;
        groups += 1;
        if (j == s.len) break;
        // j is at ':'.
        if (j + 1 < s.len and s[j + 1] == ':') {
            if (double_colon) return false;
            double_colon = true;
            i = j + 2;
            if (i == s.len) break;
        } else {
            i = j + 1;
            if (i == s.len) return false;
        }
    }
    if (double_colon) return groups < 8;
    return groups == 8;
}

// --- host names (RFC 1123, IDNA2008: RFC 5890-5893) ---------------------------

fn inTable(table: []const idna.Range, c: u21) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (c < table[mid].lo) {
            hi = mid;
        } else if (c > table[mid].hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

const Bidi = enum { L, R, AL, AN, EN, ES, CS, ET, ON, BN, NSM, other };

fn bidiClass(c: u21) Bidi {
    inline for (.{ "L", "R", "AL", "AN", "EN", "ES", "CS", "ET", "ON", "BN", "NSM" }) |name| {
        if (inTable(&@field(idna, "bidi_" ++ name), c)) return @field(Bidi, name);
    }
    return .other;
}

fn isCombiningMark(c: u21) bool {
    return inTable(&unicode_data.Mn, c) or inTable(&unicode_data.Mc, c) or inTable(&unicode_data.Me, c);
}

fn isGreek(c: u21) bool {
    return (c >= 0x0370 and c <= 0x03FF and c != 0x0375 and c != 0x037E) or (c >= 0x1F00 and c <= 0x1FFF);
}

fn isHebrew(c: u21) bool {
    return (c >= 0x0591 and c <= 0x05F4) or (c >= 0xFB1D and c <= 0xFB4F);
}

fn isHiraganaKatakanaHan(c: u21) bool {
    return (c >= 0x3040 and c <= 0x309F) or // Hiragana
        (c >= 0x30A0 and c <= 0x30FF and c != 0x30FB) or (c >= 0x31F0 and c <= 0x31FF) or // Katakana
        (c >= 0x2E80 and c <= 0x2FDF) or (c == 0x3005) or (c == 0x3007) or (c >= 0x3021 and c <= 0x3029) or
        (c >= 0x3400 and c <= 0x4DBF) or (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0xF900 and c <= 0xFAFF) or
        (c >= 0x20000 and c <= 0x3FFFF); // Han
}

/// Approximate Arabic-script Joining_Type D/L/R (letters that join).
fn isJoiningLetter(c: u21) bool {
    return (c >= 0x0620 and c <= 0x064A) or (c >= 0x066E and c <= 0x06D3) or (c == 0x06D5) or
        (c >= 0x06EE and c <= 0x06EF) or (c >= 0x06FA and c <= 0x06FC) or (c == 0x06FF) or
        (c >= 0x0710 and c <= 0x074F) or (c >= 0x0750 and c <= 0x077F) or (c >= 0x08A0 and c <= 0x08C9) or
        (c >= 0xA840 and c <= 0xA872);
}

fn isTransparent(c: u21) bool {
    return inTable(&unicode_data.Mn, c) or inTable(&unicode_data.Me, c) or inTable(&unicode_data.Cf, c);
}

/// RFC 5891 section 5.4 / RFC 5892 checks for a single U-label.
fn isValidULabel(label: []const u21) bool {
    if (label.len == 0) return false;
    if (label[0] == '-' or label[label.len - 1] == '-') return false;
    if (label.len >= 4 and label[2] == '-' and label[3] == '-') return false;
    if (isCombiningMark(label[0])) return false;
    var arabic_indic = false;
    var ext_arabic_indic = false;
    for (label, 0..) |c, i| {
        switch (c) {
            // CONTEXTJ: ZERO WIDTH NON-JOINER / JOINER (RFC 5892 A.1, A.2).
            0x200C, 0x200D => {
                if (i == 0) return false;
                if (inTable(&idna.virama, label[i - 1])) continue;
                if (c == 0x200D) return false;
                var b = i;
                while (b > 0 and isTransparent(label[b - 1])) b -= 1;
                var f = i + 1;
                while (f < label.len and isTransparent(label[f])) f += 1;
                if (b == 0 or f >= label.len or !isJoiningLetter(label[b - 1]) or !isJoiningLetter(label[f])) return false;
            },
            // CONTEXTO rules (RFC 5892 A.3 - A.9).
            0x00B7 => if (i == 0 or i + 1 >= label.len or label[i - 1] != 'l' or label[i + 1] != 'l') return false,
            0x0375 => if (i + 1 >= label.len or !isGreek(label[i + 1])) return false,
            0x05F3, 0x05F4 => if (i == 0 or !isHebrew(label[i - 1])) return false,
            0x30FB => {
                for (label) |o| {
                    if (isHiraganaKatakanaHan(o)) break;
                } else return false;
            },
            0x0660...0x0669 => arabic_indic = true,
            0x06F0...0x06F9 => ext_arabic_indic = true,
            else => if (!inTable(&idna.pvalid, c)) return false,
        }
    }
    return !(arabic_indic and ext_arabic_indic);
}

fn isRtlLabel(label: []const u21) bool {
    for (label) |c| switch (bidiClass(c)) {
        .R, .AL, .AN => return true,
        else => {},
    };
    return false;
}

/// The Bidi rule (RFC 5893 section 2).
fn satisfiesBidiRule(label: []const u21) bool {
    if (label.len == 0) return false;
    const first = bidiClass(label[0]);
    var end = label.len;
    while (end > 0 and bidiClass(label[end - 1]) == .NSM) end -= 1;
    if (end == 0) return false;
    const last = bidiClass(label[end - 1]);
    switch (first) {
        .R, .AL => {
            var has_en = false;
            var has_an = false;
            for (label) |c| switch (bidiClass(c)) {
                .R, .AL, .ES, .CS, .ET, .ON, .BN, .NSM => {},
                .EN => has_en = true,
                .AN => has_an = true,
                else => return false,
            };
            if (has_en and has_an) return false;
            return last == .R or last == .AL or last == .EN or last == .AN;
        },
        .L => {
            for (label) |c| switch (bidiClass(c)) {
                .L, .EN, .ES, .CS, .ET, .ON, .BN, .NSM => {},
                else => return false,
            };
            return last == .L or last == .EN;
        },
        else => return false,
    }
}

fn punycodeDecode(input: []const u8, out: []u21) ?[]u21 {
    var n: u32 = 128;
    var i: u32 = 0;
    var bias: u32 = 72;
    var len: usize = 0;
    var rest = input;
    if (std.mem.lastIndexOfScalar(u8, input, '-')) |d| {
        for (input[0..d]) |c| {
            if (c >= 0x80 or len >= out.len) return null;
            out[len] = c;
            len += 1;
        }
        rest = input[d + 1 ..];
    }
    var pos: usize = 0;
    while (pos < rest.len) {
        const oldi = i;
        var w: u32 = 1;
        var k: u32 = 36;
        while (true) : (k += 36) {
            if (pos >= rest.len) return null;
            const c = rest[pos];
            pos += 1;
            const digit: u32 = switch (c) {
                'a'...'z' => c - 'a',
                'A'...'Z' => c - 'A',
                '0'...'9' => c - '0' + 26,
                else => return null,
            };
            i = std.math.add(u32, i, std.math.mul(u32, digit, w) catch return null) catch return null;
            const t = if (k <= bias) 1 else if (k >= bias + 26) 26 else k - bias;
            if (digit < t) break;
            w = std.math.mul(u32, w, 36 - t) catch return null;
        }
        const count: u32 = @intCast(len + 1);
        bias = adapt(i - oldi, count, oldi == 0);
        n = std.math.add(u32, n, i / count) catch return null;
        i %= count;
        if (n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF) or len >= out.len) return null;
        std.mem.copyBackwards(u21, out[i + 1 .. len + 1], out[i..len]);
        out[i] = @intCast(n);
        len += 1;
        i += 1;
    }
    return out[0..len];
}

fn punycodeEncode(input: []const u21, out: []u8) ?[]u8 {
    var len: usize = 0;
    for (input) |c| if (c < 0x80) {
        if (len >= out.len) return null;
        out[len] = @intCast(c);
        len += 1;
    };
    const b: u32 = @intCast(len);
    var h: u32 = b;
    if (b > 0) {
        if (len >= out.len) return null;
        out[len] = '-';
        len += 1;
    }
    var n: u32 = 128;
    var delta: u32 = 0;
    var bias: u32 = 72;
    while (h < input.len) {
        var m: u32 = std.math.maxInt(u32);
        for (input) |c| if (c >= n and c < m) {
            m = c;
        };
        delta = std.math.add(u32, delta, std.math.mul(u32, m - n, h + 1) catch return null) catch return null;
        n = m;
        for (input) |c| {
            if (c < n) delta += 1;
            if (c == n) {
                var q = delta;
                var k: u32 = 36;
                while (true) : (k += 36) {
                    const t = if (k <= bias) 1 else if (k >= bias + 26) 26 else k - bias;
                    if (q < t) break;
                    if (len >= out.len) return null;
                    out[len] = encodeDigit(t + (q - t) % (36 - t));
                    len += 1;
                    q = (q - t) / (36 - t);
                }
                if (len >= out.len) return null;
                out[len] = encodeDigit(q);
                len += 1;
                bias = adapt(delta, h + 1, h == b);
                delta = 0;
                h += 1;
            }
        }
        delta += 1;
        n += 1;
    }
    return out[0..len];
}

fn encodeDigit(d: u32) u8 {
    return if (d < 26) @intCast('a' + d) else @intCast('0' + d - 26);
}

fn adapt(delta_in: u32, numpoints: u32, first: bool) u32 {
    var delta = if (first) delta_in / 700 else delta_in / 2;
    delta += delta / numpoints;
    var k: u32 = 0;
    while (delta > ((36 - 1) * 26) / 2) : (k += 36) delta /= 36 - 1;
    return k + (36 * delta) / (delta + 38);
}

fn isLdhLabel(label: []const u21) bool {
    if (label.len == 0 or label.len > 63) return false;
    if (label[0] == '-' or label[label.len - 1] == '-') return false;
    for (label) |c| {
        if (!(c < 0x80 and (std.ascii.isAlphanumeric(@intCast(c)) or c == '-'))) return false;
    }
    return true;
}

const max_label = 64;

/// Validates a host name. With `unicode`, U-labels (and the UTS 46
/// full-width/case mapping) are accepted as for `idn-hostname`; A-labels
/// (`xn--...`) are always decoded and checked as IDNA2008 labels.
fn checkDomain(s: []const u8, unicode: bool) bool {
    if (s.len == 0) return false;
    var cps_buf: [1024]u21 = undefined;
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(s) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| {
        if (n >= cps_buf.len) return false;
        var m = c;
        if (unicode) {
            // UTS 46 mapping for the common cases: full-width ASCII,
            // ideographic full stops, and upper case.
            if (m >= 0xFF01 and m <= 0xFF5E) m = m - 0xFF01 + 0x21;
            if (m == 0x3002 or m == 0xFF61) m = '.';
            // Code points UTS 46 maps to nothing.
            switch (m) {
                0x00AD, 0x034F, 0x180B...0x180D, 0x200B, 0x2060, 0xFE00...0xFE0F, 0xFEFF => continue,
                else => {},
            }
        } else if (m >= 0x80) return false;
        if (m >= 'A' and m <= 'Z') m += 32;
        cps_buf[n] = m;
        n += 1;
    }
    const cps = cps_buf[0..n];

    var labels: [128][]const u21 = undefined;
    var decoded_store: [128][max_label]u21 = undefined;
    var n_labels: usize = 0;
    var ascii_len: usize = 0;
    var rtl = false;

    var start: usize = 0;
    var i: usize = 0;
    while (i <= cps.len) : (i += 1) {
        if (i < cps.len and cps[i] != '.') continue;
        const label = cps[start..i];
        start = i + 1;
        if (label.len == 0 or n_labels >= labels.len) return false;

        var ascii = true;
        for (label) |c| if (c >= 0x80) {
            ascii = false;
        };
        var ulabel: []const u21 = label;
        var alabel_len = label.len;
        if (ascii and label.len >= 4 and label[0] == 'x' and label[1] == 'n' and label[2] == '-' and label[3] == '-') {
            if (label.len > 63) return false;
            var payload: [max_label]u8 = undefined;
            for (label[4..], 0..) |c, j| payload[j] = @intCast(c);
            const p = payload[0 .. label.len - 4];
            const dec = punycodeDecode(p, &decoded_store[n_labels]) orelse return false;
            if (dec.len == 0) return false;
            // An A-label must encode at least one non-ASCII code point.
            for (dec) |c| {
                if (c >= 0x80) break;
            } else return false;
            var re_buf: [max_label * 4]u8 = undefined;
            const re = punycodeEncode(dec, &re_buf) orelse return false;
            if (!std.ascii.eqlIgnoreCase(re, p)) return false;
            for (dec) |*c| if (c.* >= 'A' and c.* <= 'Z') {
                c.* += 32;
            };
            if (!isValidULabel(dec)) return false;
            ulabel = dec;
        } else if (ascii) {
            if (!isLdhLabel(label)) return false;
        } else {
            if (!unicode or label.len > max_label) return false;
            if (!isValidULabel(label)) return false;
            var enc_buf: [max_label * 4]u8 = undefined;
            const enc = punycodeEncode(label, &enc_buf) orelse return false;
            alabel_len = 4 + enc.len;
            if (alabel_len > 63) return false;
        }
        if (isRtlLabel(ulabel)) rtl = true;
        labels[n_labels] = ulabel;
        n_labels += 1;
        ascii_len += alabel_len + 1;
    }
    if (ascii_len - 1 > 253) return false;
    if (rtl) {
        for (labels[0..n_labels]) |label| if (!satisfiesBidiRule(label)) return false;
    }
    return true;
}

pub fn isHostname(s: []const u8) bool {
    return checkDomain(s, false);
}

pub fn isIdnHostname(s: []const u8) bool {
    return checkDomain(s, true);
}

// --- email ------------------------------------------------------------------

fn isAtext(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-/=?^_`{|}~", c) != null;
}

fn isEmailImpl(s: []const u8, allow_utf8: bool) bool {
    const at = std.mem.lastIndexOfScalar(u8, s, '@') orelse return false;
    const local = s[0..at];
    const domain = s[at + 1 ..];
    if (local.len == 0 or local.len > 64 or domain.len == 0) return false;

    if (local[0] == '"') {
        if (local.len < 2 or local[local.len - 1] != '"') return false;
        var i: usize = 1;
        while (i < local.len - 1) : (i += 1) {
            const c = local[i];
            if (c >= 0x80 and !allow_utf8) return false;
            if (c == '\\') {
                i += 1;
                if (i >= local.len - 1) return false;
                if (local[i] >= 0x80 and !allow_utf8) return false;
                continue;
            }
            if (c == '"' or (c < 0x20 and c != '\t')) return false;
        }
    } else {
        if (local[0] == '.' or local[local.len - 1] == '.') return false;
        if (std.mem.indexOf(u8, local, "..") != null) return false;
        for (local) |c| {
            if (c == '.') continue;
            if (c >= 0x80 and allow_utf8) continue;
            if (!isAtext(c)) return false;
        }
    }

    if (domain[0] == '[') {
        if (domain[domain.len - 1] != ']') return false;
        const lit = domain[1 .. domain.len - 1];
        if (lit.len >= 5 and std.ascii.eqlIgnoreCase(lit[0..5], "IPv6:")) return isIpv6(lit[5..]);
        return isIpv4(lit);
    }
    return if (allow_utf8) isIdnHostname(domain) else isHostname(domain);
}

pub fn isEmail(s: []const u8) bool {
    return isEmailImpl(s, false);
}

pub fn isIdnEmail(s: []const u8) bool {
    return isEmailImpl(s, true);
}

// --- URIs -------------------------------------------------------------------

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

fn isSubDelim(c: u8) bool {
    return std.mem.indexOfScalar(u8, "!$&'()*+,;=", c) != null;
}

/// Checks that every byte of `s` is allowed by `allowed` (or a valid
/// percent escape, or non-ASCII when `iri`).
fn checkChars(s: []const u8, extra: []const u8, iri: bool) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%') {
            if (i + 2 >= s.len or !std.ascii.isHex(s[i + 1]) or !std.ascii.isHex(s[i + 2])) return false;
            i += 2;
            continue;
        }
        if (c >= 0x80) {
            if (!iri) return false;
            continue;
        }
        if (isUnreserved(c) or isSubDelim(c) or std.mem.indexOfScalar(u8, extra, c) != null) continue;
        return false;
    }
    return true;
}

fn checkAuthority(auth: []const u8, iri: bool) bool {
    var host_port = auth;
    if (std.mem.lastIndexOfScalar(u8, auth, '@')) |at| {
        if (!checkChars(auth[0..at], ":", iri)) return false;
        host_port = auth[at + 1 ..];
    }
    var host = host_port;
    if (host_port.len > 0 and host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return false;
        const lit = host_port[1..close];
        if (lit.len > 0 and (lit[0] == 'v' or lit[0] == 'V')) {
            if (!checkChars(lit, ":", false)) return false;
        } else if (!isIpv6(lit)) return false;
        const rest = host_port[close + 1 ..];
        if (rest.len > 0) {
            if (rest[0] != ':') return false;
            for (rest[1..]) |c| if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
        for (host_port[colon + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
        host = host_port[0..colon];
    }
    return checkChars(host, "", iri);
}

fn isUriImpl(s: []const u8, require_scheme: bool, iri: bool) bool {
    var rest = s;
    for (s) |c| if (c <= 0x20 or c == '<' or c == '>' or c == '"' or c == '{' or c == '}' or
        c == '|' or c == '\\' or c == '^' or c == '`' or c == 0x7F)
    {
        return false;
    };

    // Scheme.
    var has_scheme = false;
    if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
        const cand = s[0..colon];
        const slash = std.mem.indexOfAny(u8, s, "/?#") orelse s.len;
        if (colon < slash and cand.len > 0 and std.ascii.isAlphabetic(cand[0])) {
            for (cand) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
            has_scheme = true;
            rest = s[colon + 1 ..];
        }
    }
    if (require_scheme and !has_scheme) return false;

    var fragment: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| {
        fragment = rest[h + 1 ..];
        rest = rest[0..h];
    }
    var query: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        query = rest[q + 1 ..];
        rest = rest[0..q];
    }
    if (std.mem.startsWith(u8, rest, "//")) {
        const after = rest[2..];
        const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        if (!checkAuthority(after[0..end], iri)) return false;
        rest = after[end..];
    } else if (!has_scheme) {
        // relative-ref: the first segment of a relative path may not
        // contain ':'.
        const first_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (std.mem.indexOfScalar(u8, rest[0..first_end], ':') != null) return false;
    }
    if (!checkChars(rest, ":@/", iri)) return false;
    if (query) |q| if (!checkChars(q, ":@/?", iri)) return false;
    if (fragment) |f| if (!checkChars(f, ":@/?", iri)) return false;
    return true;
}

pub fn isUri(s: []const u8) bool {
    return isUriImpl(s, true, false);
}

pub fn isUriReference(s: []const u8) bool {
    return isUriImpl(s, false, false);
}

pub fn isIri(s: []const u8) bool {
    return isUriImpl(s, true, true);
}

pub fn isIriReference(s: []const u8) bool {
    return isUriImpl(s, false, true);
}

pub fn isUriTemplate(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '{') {
            const close = std.mem.indexOfScalarPos(u8, s, i, '}') orelse return false;
            if (!isUriTemplateExpression(s[i + 1 .. close])) return false;
            i = close;
            continue;
        }
        // Literals (RFC 6570 section 2.1).
        if (c == '}' or c <= 0x20 or c == 0x7F or c == '"' or c == '<' or c == '>' or
            c == '\\' or c == '^' or c == '`' or c == '|') return false;
        if (c == '%') {
            if (i + 2 >= s.len or !std.ascii.isHex(s[i + 1]) or !std.ascii.isHex(s[i + 2])) return false;
            i += 2;
        }
    }
    return true;
}

fn isUriTemplateExpression(expr_in: []const u8) bool {
    var expr = expr_in;
    if (expr.len > 0 and std.mem.indexOfScalar(u8, "+#./;?&=,!@|", expr[0]) != null) expr = expr[1..];
    if (expr.len == 0) return false;
    var vars = std.mem.splitScalar(u8, expr, ',');
    while (vars.next()) |raw| {
        var name = raw;
        if (std.mem.endsWith(u8, name, "*")) {
            name = name[0 .. name.len - 1];
        } else if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
            const len = name[colon + 1 ..];
            if (len.len == 0 or len.len > 4 or len[0] == '0') return false;
            for (len) |d| if (!std.ascii.isDigit(d)) return false;
            name = name[0..colon];
        }
        // varname = varchar *( ["."] varchar ); varchar = ALPHA / DIGIT / "_" / pct-encoded
        if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '.') return false;
        var j: usize = 0;
        while (j < name.len) : (j += 1) {
            const ch = name[j];
            if (ch == '%') {
                if (j + 2 >= name.len or !std.ascii.isHex(name[j + 1]) or !std.ascii.isHex(name[j + 2])) return false;
                j += 2;
            } else if (ch == '.') {
                if (name[j + 1] == '.') return false;
            } else if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
        }
    }
    return true;
}

// --- misc -------------------------------------------------------------------

pub fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn isJsonPointer(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s[0] != '/') return false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '~') {
            if (i + 1 >= s.len or (s[i + 1] != '0' and s[i + 1] != '1')) return false;
        }
    }
    return true;
}

pub fn isRelativeJsonPointer(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0) return false;
    if (i > 1 and s[0] == '0') return false;
    var rest = s[i..];
    // Optional index manipulation (`+N` / `-N`).
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
        var j: usize = 1;
        while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
        if (j == 1 or (j > 2 and rest[1] == '0')) return false;
        rest = rest[j..];
    }
    if (std.mem.eql(u8, rest, "#")) return true;
    return isJsonPointer(rest);
}

/// Decodes standard base64 (with padding), as used by `contentEncoding`.
pub fn decodeBase64(allocator: Allocator, s: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const len = try decoder.calcSizeForSlice(s);
    const buf = try allocator.alloc(u8, len);
    try decoder.decode(buf, s);
    return buf;
}

test "format checks" {
    try std.testing.expect(isDateTime("1963-06-19T08:30:06.283185Z"));
    try std.testing.expect(!isDateTime("1990-02-31T15:59:59.123-08:00"));
    try std.testing.expect(isTime("23:59:60Z"));
    try std.testing.expect(!isTime("22:59:60Z"));
    try std.testing.expect(isDuration("P4DT12H30M5S"));
    try std.testing.expect(!isDuration("PT"));
    try std.testing.expect(isIpv6("::ffff:192.168.0.1"));
    try std.testing.expect(!isIpv6("12345::"));
    try std.testing.expect(isIpv4("192.168.0.1"));
    try std.testing.expect(!isIpv4("192.168.0.01"));
    try std.testing.expect(isEmail("joe.bloggs@example.com"));
    try std.testing.expect(!isEmail("2962"));
    try std.testing.expect(isUri("http://foo.bar/?baz=qux#quux"));
    try std.testing.expect(!isUri("//foo.bar/?baz=qux#quux"));
    try std.testing.expect(isHostname("xn--4gbwdl.xn--wgbh1c"));
    try std.testing.expect(isRelativeJsonPointer("0#"));
}
