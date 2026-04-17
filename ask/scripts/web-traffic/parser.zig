// web-traffic-parser — Zig 0.16
// Reads URLs from stdin (one per line), aggregates by domain,
// outputs JSON array sorted by visit count descending.

const std = @import("std");
const posix = std.posix;
const c = @cImport({ @cInclude("unistd.h"); });

const DomainCount = struct {
    domain: []const u8,
    count: u32,
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // ── Read all of stdin ──────────────────────────────────────────────────
    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(allocator);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &chunk);
        if (n == 0) break;
        try raw.appendSlice(allocator, chunk[0..n]);
    }
    const input = raw.items;

    // ── Parse domains ──────────────────────────────────────────────────────
    var domains = std.ArrayList([]const u8).empty;
    defer domains.deinit(allocator);

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const url = std.mem.trim(u8, line, " \t\r");
        if (url.len == 0) continue;
        if (extractDomain(url)) |domain| {
            if (domain.len > 0) try domains.append(allocator, domain);
        }
    }

    // ── Build output ───────────────────────────────────────────────────────
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    if (domains.items.len == 0) {
        try out.appendSlice(allocator, "[]\n");
    } else {
        // Sort lexicographically → adjacent equal domains
        std.mem.sort([]const u8, domains.items, {}, strLessThan);

        // Count consecutive equal domain runs
        var counts = std.ArrayList(DomainCount).empty;
        defer counts.deinit(allocator);

        var i: usize = 0;
        while (i < domains.items.len) {
            const domain = domains.items[i];
            var n: u32 = 0;
            while (i < domains.items.len and std.mem.eql(u8, domains.items[i], domain)) : (i += 1) {
                n += 1;
            }
            try counts.append(allocator, .{ .domain = domain, .count = n });
        }

        // Sort by count desc, domain asc
        std.mem.sort(DomainCount, counts.items, {}, dcLessThan);

        try out.appendSlice(allocator, "[\n");
        for (counts.items, 0..) |dc, idx| {
            if (idx > 0) try out.appendSlice(allocator, ",\n");
            const entry = try std.fmt.allocPrint(
                allocator,
                "  {{\"domain\":\"{s}\",\"count\":{d}}}",
                .{ dc.domain, dc.count },
            );
            defer allocator.free(entry);
            try out.appendSlice(allocator, entry);
        }
        try out.appendSlice(allocator, "\n]\n");
    }

    // Write output
    _ = c.write(1, out.items.ptr, out.items.len);
}

// ── Domain extraction ──────────────────────────────────────────────────────────

fn extractDomain(url: []const u8) ?[]const u8 {
    const rest = if (std.mem.indexOf(u8, url, "://")) |i|
        url[i + 3..]
    else
        return null;

    if (rest.len == 0) return null;

    var end: usize = rest.len;
    for (rest, 0..) |ch, j| {
        if (ch == '/' or ch == '?' or ch == '#') { end = j; break; }
    }

    const host_port = rest[0..end];
    if (host_port.len == 0) return null;

    const host = stripPort(host_port);
    if (host.len == 0) return null;

    if (std.mem.indexOfScalar(u8, host, '.') == null) return null;
    if (isIPv4(host)) return null;

    return if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
}

fn stripPort(hp: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, hp, ':')) |col| {
        const after = hp[col + 1..];
        if (after.len >= 1 and after.len <= 5) {
            var ok = true;
            for (after) |ch| { if (ch < '0' or ch > '9') { ok = false; break; } }
            if (ok) return hp[0..col];
        }
    }
    return hp;
}

fn isIPv4(host: []const u8) bool {
    var dots: u32 = 0;
    for (host) |ch| {
        if (ch == '.') { dots += 1; }
        else if (ch < '0' or ch > '9') return false;
    }
    return dots == 3;
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn dcLessThan(_: void, a: DomainCount, b: DomainCount) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.domain, b.domain) == .lt;
}
