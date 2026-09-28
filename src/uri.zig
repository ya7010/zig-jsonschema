//! Minimal RFC 3986 URI-reference handling: resolving a reference against a
//! base URI, splitting off fragments, and percent-decoding.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Parts = struct {
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

/// Splits a URI reference into its five components (RFC 3986, appendix B).
pub fn parse(s: []const u8) Parts {
    var p: Parts = .{};
    var rest = s;

    if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
        p.fragment = rest[i + 1 ..];
        rest = rest[0..i];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        p.query = rest[i + 1 ..];
        rest = rest[0..i];
    }
    // A scheme is `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"` and must
    // come before any '/'.
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        const cand = rest[0..i];
        if (cand.len > 0 and std.ascii.isAlphabetic(cand[0]) and
            std.mem.indexOfScalar(u8, cand, '/') == null and isSchemeChars(cand))
        {
            p.scheme = cand;
            rest = rest[i + 1 ..];
        }
    }
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        p.authority = rest[0..end];
        rest = rest[end..];
    }
    p.path = rest;
    return p;
}

fn isSchemeChars(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return true;
}

pub fn format(allocator: Allocator, p: Parts) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (p.scheme) |s| {
        try out.appendSlice(allocator, s);
        try out.append(allocator, ':');
    }
    if (p.authority) |a| {
        try out.appendSlice(allocator, "//");
        try out.appendSlice(allocator, a);
    }
    try out.appendSlice(allocator, p.path);
    if (p.query) |q| {
        try out.append(allocator, '?');
        try out.appendSlice(allocator, q);
    }
    if (p.fragment) |f| {
        try out.append(allocator, '#');
        try out.appendSlice(allocator, f);
    }
    return out.toOwnedSlice(allocator);
}

/// Whether `s` is an absolute URI (has a scheme).
pub fn isAbsolute(s: []const u8) bool {
    return parse(s).scheme != null;
}

/// Resolves `ref` against `base` (RFC 3986 section 5.2.2).
pub fn resolve(allocator: Allocator, base: []const u8, ref: []const u8) Allocator.Error![]const u8 {
    const r = parse(ref);
    const b = parse(base);
    var t: Parts = .{};

    if (r.scheme != null) {
        t.scheme = r.scheme;
        t.authority = r.authority;
        t.path = try removeDotSegments(allocator, r.path);
        t.query = r.query;
    } else {
        if (r.authority != null) {
            t.authority = r.authority;
            t.path = try removeDotSegments(allocator, r.path);
            t.query = r.query;
        } else {
            if (r.path.len == 0) {
                t.path = b.path;
                t.query = if (r.query != null) r.query else b.query;
            } else {
                if (r.path[0] == '/') {
                    t.path = try removeDotSegments(allocator, r.path);
                } else {
                    t.path = try removeDotSegments(allocator, try merge(allocator, b, r.path));
                }
                t.query = r.query;
            }
            t.authority = b.authority;
        }
        t.scheme = b.scheme;
    }
    t.fragment = r.fragment;
    return format(allocator, t);
}

fn merge(allocator: Allocator, b: Parts, ref_path: []const u8) Allocator.Error![]const u8 {
    if (b.authority != null and b.path.len == 0) {
        return std.fmt.allocPrint(allocator, "/{s}", .{ref_path});
    }
    const dir = if (std.mem.lastIndexOfScalar(u8, b.path, '/')) |i| b.path[0 .. i + 1] else "";
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ dir, ref_path });
}

fn removeDotSegments(allocator: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, path, ".") == null) return path;
    var out: std.ArrayList(u8) = .empty;
    var input = path;
    while (input.len > 0) {
        if (std.mem.startsWith(u8, input, "../")) {
            input = input[3..];
        } else if (std.mem.startsWith(u8, input, "./")) {
            input = input[2..];
        } else if (std.mem.startsWith(u8, input, "/./")) {
            input = input[2..];
        } else if (std.mem.eql(u8, input, "/.")) {
            input = "/";
        } else if (std.mem.startsWith(u8, input, "/../") or std.mem.eql(u8, input, "/..")) {
            input = if (input.len == 3) "/" else input[3..];
            if (std.mem.lastIndexOfScalar(u8, out.items, '/')) |i| {
                out.shrinkRetainingCapacity(i);
            } else {
                out.clearRetainingCapacity();
            }
        } else if (std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "..")) {
            input = "";
        } else {
            const start: usize = if (input[0] == '/') 1 else 0;
            const end = if (std.mem.indexOfScalarPos(u8, input, start, '/')) |i| i else input.len;
            try out.appendSlice(allocator, input[0..end]);
            input = input[end..];
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Splits `s` into the part before `#` and the fragment (without `#`).
/// The fragment is `""` when there is none.
pub fn splitFragment(s: []const u8) struct { base: []const u8, fragment: []const u8 } {
    if (std.mem.indexOfScalar(u8, s, '#')) |i| return .{ .base = s[0..i], .fragment = s[i + 1 ..] };
    return .{ .base = s, .fragment = "" };
}

/// Decodes `%XX` escapes. Invalid escapes are kept verbatim.
pub fn percentDecode(allocator: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(allocator, s[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(allocator, s[i]);
                continue;
            };
            try out.append(allocator, hi * 16 + lo);
            i += 2;
        } else {
            try out.append(allocator, s[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "resolve follows RFC 3986 examples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "http://a/b/c/d;p?q";
    const cases = [_][2][]const u8{
        .{ "g", "http://a/b/c/g" },
        .{ "./g", "http://a/b/c/g" },
        .{ "g/", "http://a/b/c/g/" },
        .{ "/g", "http://a/g" },
        .{ "//g", "http://g" },
        .{ "?y", "http://a/b/c/d;p?y" },
        .{ "#s", "http://a/b/c/d;p?q#s" },
        .{ "", "http://a/b/c/d;p?q" },
        .{ "..", "http://a/b/" },
        .{ "../g", "http://a/b/g" },
        .{ "../../g", "http://a/g" },
        .{ "../../../g", "http://a/g" },
        .{ "g;x=1/../y", "http://a/b/c/y" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try resolve(a, base, c[0]));
    try std.testing.expectEqualStrings("urn:uuid:x#/a", try resolve(a, "urn:uuid:x", "#/a"));
}
