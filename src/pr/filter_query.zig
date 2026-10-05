//! The sidebar's query language (AD-10): tokenize → parse into a flat AND of
//! terms → evaluate at stack granularity. Qualifier terms are evaluated on a
//! stack's review target; text terms hold when any member matches. Pure: no
//! I/O, and no allocation during evaluation.

const std = @import("std");
const types = @import("db/types.zig");
const stack = @import("stack.zig");
const filter = @import("filter.zig");
const parse_mod = @import("parse.zig");

pub const PrRecord = types.PrRecord;

pub const IsValue = enum { draft, ready, stacked, seen, changed };

pub const Author = union(enum) {
    me,
    login: []const u8,
};

pub const ReviewValue = enum { requested, requested_me, requested_team, approved, changes, none, mine_approved };

pub const StackValue = enum { any, top, bottom };

/// Inclusive bounds on additions+deletions.
pub const SizeRange = struct {
    min: u64 = 0,
    max: u64 = std.math.maxInt(u64),
};

pub const Ci = struct {
    value: parse_mod.CiStatus,
    /// `ci:!value`: the value itself is negated, independent of a leading `-`.
    negated: bool,
};

pub const Qualifier = union(enum) {
    is: IsValue,
    author: Author,
    review: ReviewValue,
    ci: Ci,
    label: []const u8,
    base: []const u8,
    size: SizeRange,
    stack: StackValue,
    text: []const u8,

    /// Terms that read fields only the hydrate pass writes. A record that was
    /// never hydrated satisfies them, negated or not.
    pub fn needsHydrate(self: Qualifier) bool {
        return switch (self) {
            .review, .ci, .size => true,
            else => false,
        };
    }
};

pub const Span = struct {
    start: usize,
    len: usize,
};

pub const Term = struct {
    negated: bool,
    qualifier: Qualifier,
    /// Byte span of the whole term in `Query.source`, for error/echo display.
    span: Span,
};

pub const Query = struct {
    /// Owned copy of the input. Term string payloads slice into it.
    source: []const u8,
    terms: []const Term,

    pub fn deinit(self: *Query, allocator: std.mem.Allocator) void {
        allocator.free(self.terms);
        allocator.free(self.source);
    }

    pub fn isEmpty(self: Query) bool {
        return self.terms.len == 0;
    }
};

pub const ParseErrorReason = enum {
    unterminated_quote,
    unknown_qualifier,
    missing_value,
    invalid_value,
    /// `!` on anything but `ci:`.
    negation_not_allowed,
    invalid_size,
};

pub const ParseError = struct {
    /// Slice of the caller's input text (not owned).
    term: []const u8,
    /// Byte offset into the caller's input where the problem is.
    offset: usize,
    reason: ParseErrorReason,

    /// e.g. `unknown qualifier "reviw" in "reviw:requested"`.
    pub fn format(self: ParseError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.reason) {
            .unterminated_quote => try writer.writeAll("unterminated quote"),
            .unknown_qualifier => try writer.print("unknown qualifier \"{s}\"", .{keyOfTerm(self.term)}),
            .missing_value => try writer.writeAll("missing value"),
            .invalid_value => try writer.writeAll("invalid value"),
            .negation_not_allowed => try writer.writeAll("\"!\" is only allowed with ci:"),
            .invalid_size => try writer.writeAll("invalid size"),
        }
        try writer.print(" in \"{s}\"", .{self.term});
    }
};

pub const ParseResult = union(enum) {
    ok: Query,
    err: ParseError,
};

/// Viewer identity for `@me` and review-request terms. Seen state is not
/// here: it is on each `PrRecord` (`seen_head_oid`), joined in by the store.
pub const EvalContext = struct {
    viewer_login: []const u8 = "",
    /// '\n'-joined lowercase org/slug, exactly `RepoRow.viewer_teams`.
    viewer_teams: []const u8 = "",
};

/// Where the evaluated record sits in its stack. Only `is:stacked` and
/// `stack:` read it.
pub const Placement = struct {
    height: usize,
    target_mark: stack.Mark,
    target_depth: usize,
};

pub const StackView = struct {
    stack_id: usize,
    /// Indices into the records slice, tip-first.
    members: []const usize,
    /// Index into the records slice of the review target.
    target: usize,
};

pub const VisibleStacks = struct {
    views: []StackView,
    /// Backing storage for every `StackView.members`.
    member_storage: []usize,

    pub fn deinit(self: *VisibleStacks, allocator: std.mem.Allocator) void {
        allocator.free(self.views);
        allocator.free(self.member_storage);
    }
};

/// Parse `text` into a `Query`. User mistakes come back as `.err`; allocation
/// failure is the only Zig error. The returned query owns a copy of `text`.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!ParseResult {
    const source = try allocator.dupe(u8, text);
    errdefer allocator.free(source);
    var terms: std.ArrayList(Term) = .empty;
    defer terms.deinit(allocator);

    var scanner = Scanner{ .text = source };
    while (scanner.next()) |scanned| {
        const raw = switch (scanned) {
            .term => |raw| raw,
            .err => |bad| {
                allocator.free(source);
                return .{ .err = errorFor(text, bad) };
            },
        };
        switch (termFromRaw(raw)) {
            .ok => |term| try terms.append(allocator, term),
            .err => |bad| {
                allocator.free(source);
                return .{ .err = errorFor(text, bad) };
            },
        }
    }
    return .{ .ok = .{ .source = source, .terms = try terms.toOwnedSlice(allocator) } };
}

/// Qualifier terms against one record (the review target). Text terms are
/// skipped here; `matchesStack` evaluates them across members.
pub fn matchesPr(params: struct {
    query: Query,
    rec: *const PrRecord,
    ctx: EvalContext,
    placement: Placement,
}) bool {
    for (params.query.terms) |term| {
        if (term.qualifier == .text) continue;
        if (term.qualifier.needsHydrate() and params.rec.hydrated_at_update == null) continue;
        const hit = termMatches(.{
            .qualifier = term.qualifier,
            .rec = params.rec,
            .ctx = params.ctx,
            .placement = params.placement,
        });
        if (hit == term.negated) return false;
    }
    return true;
}

/// The full stack-level rule: qualifiers on `records[target]`, text terms
/// over every member.
pub fn matchesStack(params: struct {
    query: Query,
    records: []const PrRecord,
    members: []const usize,
    target: usize,
    ctx: EvalContext,
    placement: Placement,
}) bool {
    const target_matches = matchesPr(.{
        .query = params.query,
        .rec = &params.records[params.target],
        .ctx = params.ctx,
        .placement = params.placement,
    });
    if (!target_matches) return false;
    for (params.query.terms) |term| {
        const needle = switch (term.qualifier) {
            .text => |text| text,
            else => continue,
        };
        if (anyMemberHasText(params.records, params.members, needle) == term.negated) return false;
    }
    return true;
}

/// The PR the viewer should review next: the lowest member (minimum depth)
/// not approved by the viewer at its current head, else the tip. On a depth
/// tie the member later in tip-first order wins.
pub fn reviewTarget(params: struct {
    records: []const PrRecord,
    /// Tip-first member indices of one stack. Never empty.
    members: []const usize,
    analysis: *const stack.Analysis,
}) usize {
    std.debug.assert(params.members.len > 0);
    var best: ?usize = null;
    for (params.members) |i| {
        if (isMineApproved(&params.records[i])) continue;
        if (best == null or params.analysis.depth_of[i] <= params.analysis.depth_of[best.?]) best = i;
    }
    return best orelse params.members[0];
}

/// Edges for `stack.analyzeEdges`, one per record, from head_ref/base_ref.
/// Caller owns the slice; the strings borrow from `records`.
pub fn edgesOf(allocator: std.mem.Allocator, records: []const PrRecord) ![]stack.Edge {
    const edges = try allocator.alloc(stack.Edge, records.len);
    for (records, edges) |record, *edge| {
        edge.* = .{ .head_ref = record.head_ref, .base_ref = record.base_ref };
    }
    return edges;
}

/// The stacks the sidebar shows for `query`, in display order (each stack at
/// its earliest member in `records` order), each listing all of its members
/// tip-first. `analysis` must come from `edgesOf(records)`.
pub fn visibleStacks(allocator: std.mem.Allocator, params: struct {
    records: []const PrRecord,
    analysis: *const stack.Analysis,
    query: Query,
    ctx: EvalContext,
}) !VisibleStacks {
    const analysis = params.analysis;
    std.debug.assert(params.records.len == analysis.stack_of.len);

    // Display order is already every stack's members, contiguous and tip-first,
    // so it doubles as the backing storage the views slice into.
    const member_storage = try stack.displayOrderOf(allocator, analysis.*);
    errdefer allocator.free(member_storage);
    var views: std.ArrayList(StackView) = .empty;
    errdefer views.deinit(allocator);

    var start: usize = 0;
    while (start < member_storage.len) {
        const stack_id = analysis.stack_of[member_storage[start]];
        var end = start + 1;
        while (end < member_storage.len and analysis.stack_of[member_storage[end]] == stack_id) end += 1;
        const members = member_storage[start..end];
        start = end;

        const target = reviewTarget(.{
            .records = params.records,
            .members = members,
            .analysis = analysis,
        });
        const visible = matchesStack(.{
            .query = params.query,
            .records = params.records,
            .members = members,
            .target = target,
            .ctx = params.ctx,
            .placement = .{
                .height = analysis.heights[stack_id],
                .target_mark = analysis.markOf(target),
                .target_depth = analysis.depth_of[target],
            },
        });
        if (visible) try views.append(allocator, .{ .stack_id = stack_id, .members = members, .target = target });
    }
    return .{ .views = try views.toOwnedSlice(allocator), .member_storage = member_storage };
}

pub fn isRequestedMe(r: *const PrRecord, ctx: EvalContext) bool {
    return listContainsIgnoreCase(r.requested_users, ctx.viewer_login);
}

pub fn isRequestedTeam(r: *const PrRecord, ctx: EvalContext) bool {
    return anyListIntersects(r.requested_teams, ctx.viewer_teams);
}

/// Approved by the viewer at the PR's current head.
pub fn isMineApproved(r: *const PrRecord) bool {
    return std.mem.eql(u8, r.my_review_state, "APPROVED") and
        r.my_review_oid.len > 0 and
        std.mem.eql(u8, r.my_review_oid, r.head_oid);
}

// =============================================================================
// Helpers
// =============================================================================

/// One scanned term before key/value validation. Offsets index the text.
const RawTerm = struct {
    start: usize,
    len: usize,
    negated: bool,
    /// Null for a text term.
    key: ?[]const u8,
    key_start: usize,
    /// Empty when the term has a key but no value; `termFromRaw` reports it
    /// after the key is validated.
    value: []const u8,
    /// Where the value token begins: after any `!`, at an opening quote.
    value_start: usize,
    value_bang: bool,
};

const BadTerm = struct {
    start: usize,
    len: usize,
    offset: usize,
    reason: ParseErrorReason,
};

const Scanned = union(enum) {
    term: RawTerm,
    err: BadTerm,
};

const TermResult = union(enum) {
    ok: Term,
    err: BadTerm,
};

/// Single forward pass over the query text, one term per `next`.
const Scanner = struct {
    text: []const u8,
    pos: usize = 0,

    const Quoted = union(enum) {
        value: []const u8,
        err: BadTerm,
    };

    fn next(self: *Scanner) ?Scanned {
        const text = self.text;
        while (self.pos < text.len and isSpace(text[self.pos])) self.pos += 1;
        if (self.pos >= text.len) return null;

        const start = self.pos;
        var negated = false;
        if (text[self.pos] == '-') {
            negated = true;
            self.pos += 1;
            if (self.pos >= text.len or isSpace(text[self.pos])) {
                return .{ .term = .{ .start = start, .len = 1, .negated = false, .key = null, .key_start = start, .value = "-", .value_start = start, .value_bang = false } };
            }
        }

        var key: ?[]const u8 = null;
        const key_start = self.pos;
        var bang = false;
        if (text[self.pos] != '"') {
            const word_start = self.pos;
            while (self.pos < text.len and !isSpace(text[self.pos]) and text[self.pos] != ':' and text[self.pos] != '"') self.pos += 1;
            if (self.pos >= text.len or text[self.pos] != ':') {
                // No key: a bare word. A quote inside it is a literal character.
                self.skipWord();
                return .{ .term = .{ .start = start, .len = self.pos - start, .negated = negated, .key = null, .key_start = key_start, .value = text[word_start..self.pos], .value_start = word_start, .value_bang = false } };
            }
            key = text[word_start..self.pos];
            self.pos += 1;
            if (self.pos < text.len and text[self.pos] == '!') {
                bang = true;
                self.pos += 1;
            }
        }

        const value_start = self.pos;
        const value = if (self.pos < text.len and text[self.pos] == '"') switch (self.quoted(start)) {
            .value => |value| value,
            .err => |bad| return .{ .err = bad },
        } else blk: {
            self.skipWord();
            break :blk text[value_start..self.pos];
        };
        return .{ .term = .{
            .start = start,
            .len = self.pos - start,
            .negated = negated,
            .key = key,
            .key_start = key_start,
            .value = value,
            .value_start = value_start,
            .value_bang = bang,
        } };
    }

    /// Reads the `"..."` at `pos`. The closing quote must end the term.
    fn quoted(self: *Scanner, term_start: usize) Quoted {
        const open = self.pos;
        const close = std.mem.indexOfScalarPos(u8, self.text, open + 1, '"') orelse {
            self.pos = self.text.len;
            return .{ .err = .{ .start = term_start, .len = self.pos - term_start, .offset = open, .reason = .unterminated_quote } };
        };
        self.pos = close + 1;
        if (self.pos < self.text.len and !isSpace(self.text[self.pos])) {
            const glued = self.pos;
            self.skipWord();
            return .{ .err = .{ .start = term_start, .len = self.pos - term_start, .offset = glued, .reason = .invalid_value } };
        }
        return .{ .value = self.text[open + 1 .. close] };
    }

    fn skipWord(self: *Scanner) void {
        while (self.pos < self.text.len and !isSpace(self.text[self.pos])) self.pos += 1;
    }
};

const Key = enum { is, author, review, ci, label, base, size, stack };

fn termFromRaw(raw: RawTerm) TermResult {
    const span = Span{ .start = raw.start, .len = raw.len };
    const bad = BadTerm{ .start = raw.start, .len = raw.len, .offset = raw.value_start, .reason = .invalid_value };
    const key_text = raw.key orelse {
        if (raw.value.len == 0) return .{ .err = withReason(bad, .missing_value) };
        return .{ .ok = .{ .negated = raw.negated, .qualifier = .{ .text = raw.value }, .span = span } };
    };

    const key = parseEnum(Key, key_text) orelse return .{ .err = .{
        .start = raw.start,
        .len = raw.len,
        .offset = raw.key_start,
        .reason = .unknown_qualifier,
    } };
    if (raw.value.len == 0) return .{ .err = withReason(bad, .missing_value) };
    // Offset of the `!` itself, right after the colon.
    if (raw.value_bang and key != .ci) return .{ .err = .{
        .start = raw.start,
        .len = raw.len,
        .offset = raw.key_start + key_text.len + 1,
        .reason = .negation_not_allowed,
    } };

    const qualifier: Qualifier = switch (key) {
        .is => .{ .is = parseEnum(IsValue, raw.value) orelse return .{ .err = bad } },
        .author => .{ .author = if (std.ascii.eqlIgnoreCase(raw.value, "@me")) .me else .{ .login = raw.value } },
        .review => .{ .review = parseEnum(ReviewValue, raw.value) orelse return .{ .err = bad } },
        .ci => .{ .ci = .{
            .value = parseEnum(parse_mod.CiStatus, raw.value) orelse return .{ .err = bad },
            .negated = raw.value_bang,
        } },
        .label => .{ .label = raw.value },
        .base => .{ .base = raw.value },
        .size => .{ .size = parseSize(raw.value) orelse return .{ .err = withReason(bad, .invalid_size) } },
        .stack => .{ .stack = parseEnum(StackValue, raw.value) orelse return .{ .err = bad } },
    };
    return .{ .ok = .{ .negated = raw.negated, .qualifier = qualifier, .span = span } };
}

fn withReason(bad: BadTerm, reason: ParseErrorReason) BadTerm {
    var out = bad;
    out.reason = reason;
    return out;
}

/// Case-insensitive match of `text` against `E`'s field names, with `-` in
/// the text standing for `_` in the name (`requested-me` → `requested_me`).
/// The `_` spelling itself is not accepted: it is not the documented syntax.
fn parseEnum(comptime E: type, text: []const u8) ?E {
    if (std.mem.indexOfScalar(u8, text, '_') != null) return null;
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (field.name.len == text.len and nameMatches(field.name, text)) return @field(E, field.name);
    }
    return null;
}

fn nameMatches(name: []const u8, text: []const u8) bool {
    for (name, text) |n, t| {
        const folded = if (t == '-') '_' else std.ascii.toLower(t);
        if (n != folded) return false;
    }
    return true;
}

/// `<N`, `>N`, `<=N`, `>=N`, `N..M` (inclusive) or `N` (exactly N).
fn parseSize(text: []const u8) ?SizeRange {
    if (std.mem.startsWith(u8, text, "<=")) return .{ .max = parseCount(text[2..]) orelse return null };
    if (std.mem.startsWith(u8, text, ">=")) return .{ .min = parseCount(text[2..]) orelse return null };
    if (std.mem.startsWith(u8, text, "<")) {
        const n = parseCount(text[1..]) orelse return null;
        if (n == 0) return null;
        return .{ .max = n - 1 };
    }
    if (std.mem.startsWith(u8, text, ">")) {
        const n = parseCount(text[1..]) orelse return null;
        if (n == std.math.maxInt(u64)) return null;
        return .{ .min = n + 1 };
    }
    if (std.mem.indexOf(u8, text, "..")) |dots| {
        const min = parseCount(text[0..dots]) orelse return null;
        const max = parseCount(text[dots + 2 ..]) orelse return null;
        if (max < min) return null;
        return .{ .min = min, .max = max };
    }
    const n = parseCount(text) orelse return null;
    return .{ .min = n, .max = n };
}

/// Plain decimal digits only: `std.fmt.parseInt` would also accept `+5` and
/// `1_000`.
fn parseCount(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// Re-slices the caller's text, so the error outlives the parser's own copy.
fn errorFor(text: []const u8, bad: BadTerm) ParseError {
    return .{ .term = text[bad.start..][0..bad.len], .offset = bad.offset, .reason = bad.reason };
}

/// The key of an `unknown_qualifier` term: what precedes the `:`, minus a
/// leading `-`.
fn keyOfTerm(term: []const u8) []const u8 {
    const body = if (std.mem.startsWith(u8, term, "-")) term[1..] else term;
    const colon = std.mem.indexOfScalar(u8, body, ':') orelse body.len;
    return body[0..colon];
}

fn isSpace(c: u8) bool {
    return std.ascii.isWhitespace(c);
}

fn termMatches(params: struct {
    qualifier: Qualifier,
    rec: *const PrRecord,
    ctx: EvalContext,
    placement: Placement,
}) bool {
    const r = params.rec;
    const ctx = params.ctx;
    const placement = params.placement;
    return switch (params.qualifier) {
        .is => |value| switch (value) {
            .draft => r.is_draft,
            .ready => !r.is_draft,
            .stacked => placement.height > 1,
            .seen => if (r.seen_head_oid) |seen| std.mem.eql(u8, seen, r.head_oid) else false,
            .changed => if (r.seen_head_oid) |seen| !std.mem.eql(u8, seen, r.head_oid) else false,
        },
        .author => |author| switch (author) {
            .me => ctx.viewer_login.len > 0 and std.ascii.eqlIgnoreCase(r.author, ctx.viewer_login),
            .login => |login| std.ascii.eqlIgnoreCase(r.author, login),
        },
        .review => |value| switch (value) {
            .requested => isRequestedMe(r, ctx) or isRequestedTeam(r, ctx),
            .requested_me => isRequestedMe(r, ctx),
            .requested_team => isRequestedTeam(r, ctx),
            .approved => std.mem.eql(u8, r.review_decision, "APPROVED"),
            .changes => std.mem.eql(u8, r.review_decision, "CHANGES_REQUESTED"),
            .none => r.review_decision.len == 0 or std.mem.eql(u8, r.review_decision, "REVIEW_REQUIRED"),
            .mine_approved => isMineApproved(r),
        },
        .ci => |ci| (r.ci == ci.value) != ci.negated,
        .label => |label| listContainsIgnoreCase(r.labels, label),
        .base => |base| std.mem.eql(u8, r.base_ref, base),
        .size => |range| blk: {
            const total = @as(u64, r.additions) + r.deletions;
            break :blk total >= range.min and total <= range.max;
        },
        .stack => |value| placement.height > 1 and switch (value) {
            .any => true,
            .top => placement.target_mark == .top,
            .bottom => placement.target_depth == 0,
        },
        .text => |needle| recordHasText(r, needle),
    };
}

fn anyMemberHasText(records: []const PrRecord, members: []const usize, needle: []const u8) bool {
    for (members) |i| {
        if (recordHasText(&records[i], needle)) return true;
    }
    return false;
}

fn recordHasText(r: *const PrRecord, needle: []const u8) bool {
    return filter.containsIgnoreCase(r.title, needle) or
        filter.containsIgnoreCase(r.author, needle) or
        filter.containsIgnoreCase(r.head_ref, needle) or
        filter.containsIgnoreCase(r.base_ref, needle);
}

/// Is `needle` one of the '\n'-joined items? Empty items and an empty needle
/// never match.
fn listContainsIgnoreCase(joined: []const u8, needle: []const u8) bool {
    if (joined.len == 0 or needle.len == 0) return false;
    var items = types.listItems(joined);
    while (items.next()) |item| {
        if (item.len > 0 and std.ascii.eqlIgnoreCase(item, needle)) return true;
    }
    return false;
}

fn anyListIntersects(joined_a: []const u8, joined_b: []const u8) bool {
    if (joined_a.len == 0) return false;
    var items = types.listItems(joined_a);
    while (items.next()) |item| {
        if (listContainsIgnoreCase(joined_b, item)) return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const default_updated_at = "2026-01-02T00:00:00Z";

const standalone = Placement{ .height = 1, .target_mark = .none, .target_depth = 0 };

const RecParams = struct {
    number: u32 = 1,
    title: []const u8 = "Some change",
    author: []const u8 = "alice",
    head: []const u8 = "feature",
    base: []const u8 = "main",
    head_oid: []const u8 = "oid-head",
    is_draft: bool = false,
    updated_at: []const u8 = default_updated_at,
    hydrated_at_update: ?[]const u8 = default_updated_at,
    additions: u32 = 0,
    deletions: u32 = 0,
    review_decision: []const u8 = "",
    ci: parse_mod.CiStatus = .none,
    labels: []const u8 = "",
    requested_users: []const u8 = "",
    requested_teams: []const u8 = "",
    my_review_state: []const u8 = "",
    my_review_oid: []const u8 = "",
    seen_head_oid: ?[]const u8 = null,
};

/// A hydrated `PrRecord` with defaults for every field.
fn rec(params: RecParams) PrRecord {
    return .{
        .number = params.number,
        .node_id = "",
        .state = .open,
        .title = params.title,
        .author = params.author,
        .url = "",
        .is_draft = params.is_draft,
        .head_ref = params.head,
        .base_ref = params.base,
        .head_oid = params.head_oid,
        .base_oid = "",
        .updated_at = params.updated_at,
        .hydrated_at_update = params.hydrated_at_update,
        .additions = params.additions,
        .deletions = params.deletions,
        .changed_files = 0,
        .review_decision = params.review_decision,
        .ci = params.ci,
        .labels = params.labels,
        .requested_users = params.requested_users,
        .requested_teams = params.requested_teams,
        .my_review_state = params.my_review_state,
        .my_review_oid = params.my_review_oid,
        .seen_head_oid = params.seen_head_oid,
        .seen_merge_base_oid = null,
    };
}

fn expectParseOk(text: []const u8) !Query {
    return switch (try parse(testing.allocator, text)) {
        .ok => |query| query,
        .err => error.TestUnexpectedResult,
    };
}

fn expectParseErr(params: struct {
    text: []const u8,
    reason: ParseErrorReason,
    term: []const u8,
    offset: ?usize = null,
}) !ParseError {
    const bad = switch (try parse(testing.allocator, params.text)) {
        .ok => |query| {
            var owned = query;
            owned.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        },
        .err => |bad| bad,
    };
    try testing.expectEqual(params.reason, bad.reason);
    try testing.expectEqualStrings(params.term, bad.term);
    if (params.offset) |offset| try testing.expectEqual(offset, bad.offset);
    return bad;
}

fn expectSingleQualifier(text: []const u8, expected: Qualifier) !void {
    var query = try expectParseOk(text);
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), query.terms.len);
    try testing.expectEqual(false, query.terms[0].negated);
    try testing.expectEqualDeep(expected, query.terms[0].qualifier);
}

/// Parse `query_text` and run the stack rule on a one-member stack. For a
/// single PR this is exactly per-PR matching.
fn matchOne(params: struct {
    query_text: []const u8,
    rec: PrRecord,
    ctx: EvalContext = .{},
    placement: Placement = standalone,
}) !bool {
    var query = try expectParseOk(params.query_text);
    defer query.deinit(testing.allocator);
    const records = [_]PrRecord{params.rec};
    return matchesStack(.{
        .query = query,
        .records = &records,
        .members = &.{0},
        .target = 0,
        .ctx = params.ctx,
        .placement = params.placement,
    });
}

const MatchRow = struct {
    query: []const u8,
    rec: PrRecord,
    ctx: EvalContext = .{},
    expected: bool,
};

fn expectMatchRows(rows: []const MatchRow) !void {
    for (rows) |row| {
        const got = try matchOne(.{ .query_text = row.query, .rec = row.rec, .ctx = row.ctx });
        testing.expectEqual(row.expected, got) catch |err| {
            std.debug.print("query: {s}\n", .{row.query});
            return err;
        };
    }
}

fn analyzeRecords(records: []const PrRecord) !stack.Analysis {
    const edges = try edgesOf(testing.allocator, records);
    defer testing.allocator.free(edges);
    return stack.analyzeEdges(testing.allocator, edges);
}

fn targetOf(records: []const PrRecord, members: []const usize) !usize {
    var analysis = try analyzeRecords(records);
    defer analysis.deinit(testing.allocator);
    return reviewTarget(.{ .records = records, .members = members, .analysis = &analysis });
}

/// Visible stacks for `query_text`, flattened to `[stack members...]` lists of
/// PR numbers so a test can compare the whole sidebar at once.
fn visibleNumbers(params: struct {
    records: []const PrRecord,
    query_text: []const u8,
    ctx: EvalContext = .{},
}) ![]const []const u32 {
    var analysis = try analyzeRecords(params.records);
    defer analysis.deinit(testing.allocator);
    var query = try expectParseOk(params.query_text);
    defer query.deinit(testing.allocator);
    var visible = try visibleStacks(testing.allocator, .{
        .records = params.records,
        .analysis = &analysis,
        .query = query,
        .ctx = params.ctx,
    });
    defer visible.deinit(testing.allocator);

    const out = try testing.allocator.alloc([]const u32, visible.views.len);
    errdefer testing.allocator.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |list| testing.allocator.free(list);
    for (visible.views, out) |view, *numbers| {
        const list = try testing.allocator.alloc(u32, view.members.len);
        for (view.members, list) |member, *number| number.* = params.records[member].number;
        numbers.* = list;
        filled += 1;
    }
    return out;
}

fn freeNumbers(lists: []const []const u32) void {
    for (lists) |list| testing.allocator.free(list);
    testing.allocator.free(lists);
}

fn expectVisible(expected: []const []const u32, actual: []const []const u32) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expectEqualSlices(u32, want, got);
}

/// bottom (#1, head feat/base) <- tip (#2, head feat/login-ui).
fn twoStack(params: struct { bottom: RecParams = .{}, tip: RecParams = .{} }) [2]PrRecord {
    var bottom = params.bottom;
    bottom.number = 1;
    bottom.head = "feat/base";
    bottom.base = "main";
    var tip = params.tip;
    tip.number = 2;
    tip.head = "feat/login-ui";
    tip.base = "feat/base";
    return .{ rec(bottom), rec(tip) };
}

// --- A2: tokenizer and parser -------------------------------------------------

test "empty and whitespace-only queries parse to zero terms" {
    for ([_][]const u8{ "", "   ", "\t\n " }) |text| {
        var query = try expectParseOk(text);
        defer query.deinit(testing.allocator);
        try testing.expect(query.isEmpty());
    }
}

test "terms split on any whitespace run" {
    var query = try expectParseOk("a\t b\n c");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), query.terms.len);
    try testing.expectEqualStrings("a", query.terms[0].qualifier.text);
    try testing.expectEqualStrings("b", query.terms[1].qualifier.text);
    try testing.expectEqualStrings("c", query.terms[2].qualifier.text);
}

test "leading dash negates qualified and text terms" {
    var query = try expectParseOk("-is:draft -wip");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), query.terms.len);
    try testing.expect(query.terms[0].negated);
    try testing.expectEqual(IsValue.draft, query.terms[0].qualifier.is);
    try testing.expect(query.terms[1].negated);
    try testing.expectEqualStrings("wip", query.terms[1].qualifier.text);
}

test "lone dash is a text term" {
    var query = try expectParseOk("a - b");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), query.terms.len);
    try testing.expect(!query.terms[1].negated);
    try testing.expectEqualStrings("-", query.terms[1].qualifier.text);
}

test "quoted text is one term without quotes" {
    var query = try expectParseOk("\"fix login\"");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), query.terms.len);
    try testing.expectEqualStrings("fix login", query.terms[0].qualifier.text);
}

test "negated quoted text is one negated term" {
    var query = try expectParseOk("-\"fix login\"");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), query.terms.len);
    try testing.expect(query.terms[0].negated);
    try testing.expectEqualStrings("fix login", query.terms[0].qualifier.text);
}

test "quoted qualifier value keeps spaces" {
    var query = try expectParseOk("label:\"needs review\"");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), query.terms.len);
    try testing.expectEqualStrings("needs review", query.terms[0].qualifier.label);
}

test "keys and enum values are case-insensitive" {
    try expectSingleQualifier("IS:Draft", .{ .is = .draft });
    try expectSingleQualifier("Review:Requested-Me", .{ .review = .requested_me });
    try expectSingleQualifier("CI:!FAILURE", .{ .ci = .{ .value = .failure, .negated = true } });
}

test "author/label/base values preserve case in the AST" {
    try expectSingleQualifier("author:OctoCat", .{ .author = .{ .login = "OctoCat" } });
    try expectSingleQualifier("LABEL:Needs-Review", .{ .label = "Needs-Review" });
    try expectSingleQualifier("base:Release/V2", .{ .base = "Release/V2" });
}

test "author:@me parses to Author.me" {
    try expectSingleQualifier("author:@me", .{ .author = .me });
    try expectSingleQualifier("author:@ME", .{ .author = .me });
}

test "every AD-10 value parses to the expected Qualifier" {
    const Row = struct { text: []const u8, expected: Qualifier };
    const rows = [_]Row{
        .{ .text = "is:draft", .expected = .{ .is = .draft } },
        .{ .text = "is:ready", .expected = .{ .is = .ready } },
        .{ .text = "is:stacked", .expected = .{ .is = .stacked } },
        .{ .text = "is:seen", .expected = .{ .is = .seen } },
        .{ .text = "is:changed", .expected = .{ .is = .changed } },
        .{ .text = "review:requested", .expected = .{ .review = .requested } },
        .{ .text = "review:requested-me", .expected = .{ .review = .requested_me } },
        .{ .text = "review:requested-team", .expected = .{ .review = .requested_team } },
        .{ .text = "review:approved", .expected = .{ .review = .approved } },
        .{ .text = "review:changes", .expected = .{ .review = .changes } },
        .{ .text = "review:none", .expected = .{ .review = .none } },
        .{ .text = "review:mine-approved", .expected = .{ .review = .mine_approved } },
        .{ .text = "ci:success", .expected = .{ .ci = .{ .value = .success, .negated = false } } },
        .{ .text = "ci:failure", .expected = .{ .ci = .{ .value = .failure, .negated = false } } },
        .{ .text = "ci:pending", .expected = .{ .ci = .{ .value = .pending, .negated = false } } },
        .{ .text = "ci:none", .expected = .{ .ci = .{ .value = .none, .negated = false } } },
        .{ .text = "ci:!success", .expected = .{ .ci = .{ .value = .success, .negated = true } } },
        .{ .text = "ci:!failure", .expected = .{ .ci = .{ .value = .failure, .negated = true } } },
        .{ .text = "ci:!pending", .expected = .{ .ci = .{ .value = .pending, .negated = true } } },
        .{ .text = "ci:!none", .expected = .{ .ci = .{ .value = .none, .negated = true } } },
        .{ .text = "stack:any", .expected = .{ .stack = .any } },
        .{ .text = "stack:top", .expected = .{ .stack = .top } },
        .{ .text = "stack:bottom", .expected = .{ .stack = .bottom } },
    };
    for (rows) |row| {
        expectSingleQualifier(row.text, row.expected) catch |err| {
            std.debug.print("text: {s}\n", .{row.text});
            return err;
        };
    }
}

test "size forms" {
    const max = std.math.maxInt(u64);
    const Row = struct { text: []const u8, min: u64, max: u64 };
    const rows = [_]Row{
        .{ .text = "size:<10", .min = 0, .max = 9 },
        .{ .text = "size:>10", .min = 11, .max = max },
        .{ .text = "size:<=10", .min = 0, .max = 10 },
        .{ .text = "size:>=10", .min = 10, .max = max },
        .{ .text = "size:5..20", .min = 5, .max = 20 },
        .{ .text = "size:7", .min = 7, .max = 7 },
        .{ .text = "size:0", .min = 0, .max = 0 },
        .{ .text = "size:3..3", .min = 3, .max = 3 },
    };
    for (rows) |row| {
        expectSingleQualifier(row.text, .{ .size = .{ .min = row.min, .max = row.max } }) catch |err| {
            std.debug.print("text: {s}\n", .{row.text});
            return err;
        };
    }
}

test "parse returns a span for each term pointing into source" {
    var query = try expectParseOk("  -is:draft  login \"a b\"");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), query.terms.len);
    const expected = [_][]const u8{ "-is:draft", "login", "\"a b\"" };
    for (query.terms, expected) |term, want| {
        try testing.expectEqualStrings(want, query.source[term.span.start..][0..term.span.len]);
    }
}

test "colon inside quotes is text" {
    var query = try expectParseOk("\"foo:bar\"");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), query.terms.len);
    try testing.expectEqualStrings("foo:bar", query.terms[0].qualifier.text);
}

test "a quote inside a bare word is a literal character" {
    var query = try expectParseOk("ab\"c label:x\"y");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), query.terms.len);
    try testing.expectEqualStrings("ab\"c", query.terms[0].qualifier.text);
    try testing.expectEqualStrings("x\"y", query.terms[1].qualifier.label);
}

test "a qualifier value may itself contain a colon" {
    try expectSingleQualifier("base:release:v2", .{ .base = "release:v2" });
    _ = try expectParseErr(.{ .text = "is:draft:x", .reason = .invalid_value, .term = "is:draft:x", .offset = 3 });
}

test "negated unterminated quote reports the quote's offset" {
    const bad = try expectParseErr(.{ .text = "a -\"", .reason = .unterminated_quote, .term = "-\"" });
    try testing.expectEqual(@as(usize, 3), bad.offset);
}

test "empty quoted text is a missing value" {
    _ = try expectParseErr(.{ .text = "\"\"", .reason = .missing_value, .term = "\"\"" });
    _ = try expectParseErr(.{ .text = "-\"\"", .reason = .missing_value, .term = "-\"\"" });
}

test "unterminated quote" {
    const bad = try expectParseErr(.{ .text = "is:draft label:\"oops", .reason = .unterminated_quote, .term = "label:\"oops" });
    try testing.expectEqual(@as(usize, 15), bad.offset);
    const text_bad = try expectParseErr(.{ .text = "\"open", .reason = .unterminated_quote, .term = "\"open" });
    try testing.expectEqual(@as(usize, 0), text_bad.offset);
}

test "unknown qualifier" {
    const bad = try expectParseErr(.{ .text = "is:draft reviw:requested", .reason = .unknown_qualifier, .term = "reviw:requested" });
    try testing.expectEqual(@as(usize, 9), bad.offset);
    _ = try expectParseErr(.{ .text = "-foo:bar", .reason = .unknown_qualifier, .term = "-foo:bar", .offset = 1 });
    _ = try expectParseErr(.{ .text = ":bar", .reason = .unknown_qualifier, .term = ":bar", .offset = 0 });
}

test "unknown qualifier with an empty value is reported as unknown, not missing" {
    _ = try expectParseErr(.{ .text = "reviw:", .reason = .unknown_qualifier, .term = "reviw:", .offset = 0 });
    _ = try expectParseErr(.{ .text = "is:draft -reviw: x", .reason = .unknown_qualifier, .term = "-reviw:", .offset = 10 });
    _ = try expectParseErr(.{ .text = "reviw:\"\"", .reason = .unknown_qualifier, .term = "reviw:\"\"", .offset = 0 });
    _ = try expectParseErr(.{ .text = "reviw:!", .reason = .unknown_qualifier, .term = "reviw:!", .offset = 0 });
}

test "missing value" {
    _ = try expectParseErr(.{ .text = "author:", .reason = .missing_value, .term = "author:", .offset = 7 });
    _ = try expectParseErr(.{ .text = "author: x", .reason = .missing_value, .term = "author:", .offset = 7 });
    _ = try expectParseErr(.{ .text = "label:\"\"", .reason = .missing_value, .term = "label:\"\"", .offset = 6 });
    _ = try expectParseErr(.{ .text = "ci:!", .reason = .missing_value, .term = "ci:!", .offset = 4 });
    _ = try expectParseErr(.{ .text = "label:!", .reason = .missing_value, .term = "label:!", .offset = 7 });
}

test "invalid enum value" {
    _ = try expectParseErr(.{ .text = "is:open", .reason = .invalid_value, .term = "is:open", .offset = 3 });
    _ = try expectParseErr(.{ .text = "ci:green", .reason = .invalid_value, .term = "ci:green", .offset = 3 });
    _ = try expectParseErr(.{ .text = "ci:!green", .reason = .invalid_value, .term = "ci:!green", .offset = 4 });
    _ = try expectParseErr(.{ .text = "a -stack:middle", .reason = .invalid_value, .term = "-stack:middle", .offset = 9 });
    _ = try expectParseErr(.{ .text = "is:\"open\"", .reason = .invalid_value, .term = "is:\"open\"", .offset = 3 });
    _ = try expectParseErr(.{ .text = "review:requested_me", .reason = .invalid_value, .term = "review:requested_me", .offset = 7 });
}

test "text glued to a closing quote is an invalid value" {
    _ = try expectParseErr(.{ .text = "\"fix\"login", .reason = .invalid_value, .term = "\"fix\"login" });
    _ = try expectParseErr(.{ .text = "label:\"a b\"c d", .reason = .invalid_value, .term = "label:\"a b\"c" });
}

test "bang on a non-ci key" {
    _ = try expectParseErr(.{ .text = "review:!approved", .reason = .negation_not_allowed, .term = "review:!approved", .offset = 7 });
    _ = try expectParseErr(.{ .text = "a -label:!bug", .reason = .negation_not_allowed, .term = "-label:!bug", .offset = 9 });
}

test "invalid size" {
    const texts = [_][]const u8{
        "size:abc",
        "size:<",
        "size:20..5",
        "size:99999999999999999999999",
        "size:<0",
        "size:>18446744073709551615",
        "size:1_000",
        "size:+5",
        "size:5..",
        "size:..5",
    };
    for (texts) |text| {
        _ = expectParseErr(.{ .text = text, .reason = .invalid_size, .term = text, .offset = 5 }) catch |err| {
            std.debug.print("text: {s}\n", .{text});
            return err;
        };
    }
}

test "error term slices the caller's text, valid after parse returns" {
    const text = "is:draft reviw:x";
    const bad = try expectParseErr(.{ .text = text, .reason = .unknown_qualifier, .term = "reviw:x" });
    try testing.expectEqual(@intFromPtr(text.ptr) + 9, @intFromPtr(bad.term.ptr));
}

test "ParseError.format names the reason and the term" {
    const Row = struct { text: []const u8, message: []const u8 };
    const rows = [_]Row{
        .{ .text = "reviw:requested", .message = "unknown qualifier \"reviw\" in \"reviw:requested\"" },
        .{ .text = "-reviw:requested", .message = "unknown qualifier \"reviw\" in \"-reviw:requested\"" },
        .{ .text = "label:\"oops", .message = "unterminated quote in \"label:\"oops\"" },
        .{ .text = "author:", .message = "missing value in \"author:\"" },
        .{ .text = "is:open", .message = "invalid value in \"is:open\"" },
        .{ .text = "review:!approved", .message = "\"!\" is only allowed with ci: in \"review:!approved\"" },
        .{ .text = "size:abc", .message = "invalid size in \"size:abc\"" },
    };
    for (rows) |row| {
        const bad = (try parse(testing.allocator, row.text)).err;
        const message = try std.fmt.allocPrint(testing.allocator, "{f}", .{bad});
        defer testing.allocator.free(message);
        try testing.expectEqualStrings(row.message, message);
    }
}

test "failed parse leaks nothing" {
    const texts = [_][]const u8{
        "a b label:\"oops",
        "a b reviw:requested",
        "a b author:",
        "a b is:open",
        "a b review:!approved",
        "a b size:20..5",
        "a b \"x\"y",
    };
    for (texts) |text| {
        const result = try parse(testing.allocator, text);
        try testing.expect(result == .err);
    }
}

test "parse survives allocation failure at every point" {
    try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{"-is:draft author:@me \"fix login\" size:5..20"});
}

fn parseAndFree(allocator: std.mem.Allocator, text: []const u8) !void {
    var query = (try parse(allocator, text)).ok;
    query.deinit(allocator);
}

// --- A3: evaluator -----------------------------------------------------------

test "empty query matches any record" {
    try testing.expect(try matchOne(.{ .query_text = "", .rec = rec(.{}) }));
    try testing.expect(try matchOne(.{ .query_text = "", .rec = rec(.{ .is_draft = true, .hydrated_at_update = null }) }));
}

test "is:draft and is:ready" {
    try expectMatchRows(&.{
        .{ .query = "is:draft", .rec = rec(.{ .is_draft = true }), .expected = true },
        .{ .query = "is:draft", .rec = rec(.{ .is_draft = false }), .expected = false },
        .{ .query = "is:ready", .rec = rec(.{ .is_draft = false }), .expected = true },
        .{ .query = "is:ready", .rec = rec(.{ .is_draft = true }), .expected = false },
        .{ .query = "-is:draft", .rec = rec(.{ .is_draft = true }), .expected = false },
    });
}

test "is:seen is true only when seen_head_oid equals head_oid" {
    try expectMatchRows(&.{
        .{ .query = "is:seen", .rec = rec(.{ .head_oid = "aaa", .seen_head_oid = "aaa" }), .expected = true },
        .{ .query = "is:seen", .rec = rec(.{ .head_oid = "bbb", .seen_head_oid = "aaa" }), .expected = false },
        .{ .query = "is:seen", .rec = rec(.{ .head_oid = "aaa", .seen_head_oid = null }), .expected = false },
    });
}

test "is:changed is true only when seen and moved" {
    try expectMatchRows(&.{
        .{ .query = "is:changed", .rec = rec(.{ .head_oid = "bbb", .seen_head_oid = "aaa" }), .expected = true },
        .{ .query = "is:changed", .rec = rec(.{ .head_oid = "aaa", .seen_head_oid = "aaa" }), .expected = false },
        .{ .query = "is:changed", .rec = rec(.{ .head_oid = "aaa", .seen_head_oid = null }), .expected = false },
    });
}

test "-is:seen matches never-seen records" {
    try expectMatchRows(&.{
        .{ .query = "-is:seen", .rec = rec(.{ .seen_head_oid = null }), .expected = true },
        .{ .query = "-is:seen", .rec = rec(.{ .head_oid = "bbb", .seen_head_oid = "aaa" }), .expected = true },
        .{ .query = "-is:seen", .rec = rec(.{ .head_oid = "aaa", .seen_head_oid = "aaa" }), .expected = false },
    });
}

test "author: matches case-insensitively" {
    try expectMatchRows(&.{
        .{ .query = "author:octocat", .rec = rec(.{ .author = "OctoCat" }), .expected = true },
        .{ .query = "author:OCTOCAT", .rec = rec(.{ .author = "octocat" }), .expected = true },
        .{ .query = "author:octo", .rec = rec(.{ .author = "octocat" }), .expected = false },
        .{ .query = "-author:octocat", .rec = rec(.{ .author = "octocat" }), .expected = false },
    });
}

test "author:@me uses viewer_login" {
    try expectMatchRows(&.{
        .{ .query = "author:@me", .rec = rec(.{ .author = "Alice" }), .ctx = .{ .viewer_login = "alice" }, .expected = true },
        .{ .query = "author:@me", .rec = rec(.{ .author = "bob" }), .ctx = .{ .viewer_login = "alice" }, .expected = false },
    });
}

test "author:@me with empty viewer_login matches nothing" {
    try expectMatchRows(&.{
        .{ .query = "author:@me", .rec = rec(.{ .author = "alice" }), .expected = false },
        .{ .query = "author:@me", .rec = rec(.{ .author = "" }), .expected = false },
    });
}

test "review:requested-me finds the viewer among newline-joined users, ignoring case" {
    const ctx = EvalContext{ .viewer_login = "alice" };
    try expectMatchRows(&.{
        .{ .query = "review:requested-me", .rec = rec(.{ .requested_users = "bob\nAlice\ncarol" }), .ctx = ctx, .expected = true },
        .{ .query = "review:requested-me", .rec = rec(.{ .requested_users = "Alice" }), .ctx = ctx, .expected = true },
        .{ .query = "review:requested-me", .rec = rec(.{ .requested_users = "bob\nalicia" }), .ctx = ctx, .expected = false },
        .{ .query = "review:requested-me", .rec = rec(.{ .requested_users = "", .requested_teams = "org/core" }), .ctx = .{ .viewer_login = "alice", .viewer_teams = "org/core" }, .expected = false },
    });
}

test "review:requested-team matches when any viewer team is requested" {
    const ctx = EvalContext{ .viewer_login = "alice", .viewer_teams = "org/web\norg/core" };
    try expectMatchRows(&.{
        .{ .query = "review:requested-team", .rec = rec(.{ .requested_teams = "org/infra\norg/core" }), .ctx = ctx, .expected = true },
        .{ .query = "review:requested-team", .rec = rec(.{ .requested_teams = "Org/Web" }), .ctx = ctx, .expected = true },
        .{ .query = "review:requested-team", .rec = rec(.{ .requested_teams = "org/infra" }), .ctx = ctx, .expected = false },
        .{ .query = "review:requested-team", .rec = rec(.{ .requested_teams = "", .requested_users = "alice" }), .ctx = ctx, .expected = false },
        .{ .query = "review:requested-team", .rec = rec(.{ .requested_teams = "org/core" }), .ctx = .{ .viewer_login = "alice" }, .expected = false },
    });
}

test "review:requested is true for a user request or a team request" {
    const ctx = EvalContext{ .viewer_login = "alice", .viewer_teams = "org/core" };
    try expectMatchRows(&.{
        .{ .query = "review:requested", .rec = rec(.{ .requested_users = "alice" }), .ctx = ctx, .expected = true },
        .{ .query = "review:requested", .rec = rec(.{ .requested_teams = "org/core" }), .ctx = ctx, .expected = true },
        .{ .query = "review:requested", .rec = rec(.{ .requested_users = "bob", .requested_teams = "org/web" }), .ctx = ctx, .expected = false },
    });
}

test "review:approved / changes / none against review_decision" {
    try expectMatchRows(&.{
        .{ .query = "review:approved", .rec = rec(.{ .review_decision = "APPROVED" }), .expected = true },
        .{ .query = "review:approved", .rec = rec(.{ .review_decision = "CHANGES_REQUESTED" }), .expected = false },
        .{ .query = "review:changes", .rec = rec(.{ .review_decision = "CHANGES_REQUESTED" }), .expected = true },
        .{ .query = "review:changes", .rec = rec(.{ .review_decision = "APPROVED" }), .expected = false },
        .{ .query = "review:none", .rec = rec(.{ .review_decision = "" }), .expected = true },
        .{ .query = "review:none", .rec = rec(.{ .review_decision = "REVIEW_REQUIRED" }), .expected = true },
        .{ .query = "review:none", .rec = rec(.{ .review_decision = "APPROVED" }), .expected = false },
    });
}

test "review:mine-approved requires APPROVED at the current head" {
    try expectMatchRows(&.{
        .{ .query = "review:mine-approved", .rec = rec(.{ .head_oid = "h2", .my_review_state = "APPROVED", .my_review_oid = "h2" }), .expected = true },
        .{ .query = "review:mine-approved", .rec = rec(.{ .head_oid = "h2", .my_review_state = "APPROVED", .my_review_oid = "h1" }), .expected = false },
        .{ .query = "review:mine-approved", .rec = rec(.{ .head_oid = "h2", .my_review_state = "CHANGES_REQUESTED", .my_review_oid = "h2" }), .expected = false },
        .{ .query = "review:mine-approved", .rec = rec(.{ .head_oid = "", .my_review_state = "APPROVED", .my_review_oid = "" }), .expected = false },
    });
}

test "ci:<value> and ci:!<value>" {
    const statuses = [_]parse_mod.CiStatus{ .none, .pending, .success, .failure };
    for (statuses) |query_status| {
        for (statuses) |record_status| {
            const positive = try std.fmt.allocPrint(testing.allocator, "ci:{s}", .{@tagName(query_status)});
            defer testing.allocator.free(positive);
            const negative = try std.fmt.allocPrint(testing.allocator, "ci:!{s}", .{@tagName(query_status)});
            defer testing.allocator.free(negative);
            const same = query_status == record_status;
            try testing.expectEqual(same, try matchOne(.{ .query_text = positive, .rec = rec(.{ .ci = record_status }) }));
            try testing.expectEqual(!same, try matchOne(.{ .query_text = negative, .rec = rec(.{ .ci = record_status }) }));
        }
    }
}

test "-ci:!failure is the same as ci:failure" {
    try expectMatchRows(&.{
        .{ .query = "-ci:!failure", .rec = rec(.{ .ci = .failure }), .expected = true },
        .{ .query = "-ci:!failure", .rec = rec(.{ .ci = .success }), .expected = false },
    });
}

test "label: matches any label, ignoring case, and not by substring" {
    try expectMatchRows(&.{
        .{ .query = "label:bug", .rec = rec(.{ .labels = "enhancement\nBug" }), .expected = true },
        .{ .query = "label:\"needs review\"", .rec = rec(.{ .labels = "Needs Review" }), .expected = true },
        .{ .query = "label:bug", .rec = rec(.{ .labels = "bugfix" }), .expected = false },
        .{ .query = "label:bug", .rec = rec(.{ .labels = "" }), .expected = false },
        .{ .query = "-label:bug", .rec = rec(.{ .labels = "bug" }), .expected = false },
    });
}

test "base: matches exactly and is case-sensitive" {
    try expectMatchRows(&.{
        .{ .query = "base:main", .rec = rec(.{ .base = "main" }), .expected = true },
        .{ .query = "base:Main", .rec = rec(.{ .base = "main" }), .expected = false },
        .{ .query = "base:mai", .rec = rec(.{ .base = "main" }), .expected = false },
    });
}

test "size: compares additions+deletions with inclusive bounds" {
    const r = rec(.{ .additions = 6, .deletions = 4 });
    try expectMatchRows(&.{
        .{ .query = "size:10", .rec = r, .expected = true },
        .{ .query = "size:9", .rec = r, .expected = false },
        .{ .query = "size:<10", .rec = r, .expected = false },
        .{ .query = "size:<11", .rec = r, .expected = true },
        .{ .query = "size:<=10", .rec = r, .expected = true },
        .{ .query = "size:>10", .rec = r, .expected = false },
        .{ .query = "size:>9", .rec = r, .expected = true },
        .{ .query = "size:>=10", .rec = r, .expected = true },
        .{ .query = "size:10..20", .rec = r, .expected = true },
        .{ .query = "size:1..10", .rec = r, .expected = true },
        .{ .query = "size:11..20", .rec = r, .expected = false },
        .{ .query = "size:>4000000000", .rec = rec(.{ .additions = std.math.maxInt(u32), .deletions = std.math.maxInt(u32) }), .expected = true },
    });
}

test "text matches title, author, head_ref or base_ref, ignoring case" {
    try expectMatchRows(&.{
        .{ .query = "LOGIN", .rec = rec(.{ .title = "Fix login bug" }), .expected = true },
        .{ .query = "octo", .rec = rec(.{ .author = "OctoCat" }), .expected = true },
        .{ .query = "feat/x", .rec = rec(.{ .head = "feat/xyz" }), .expected = true },
        .{ .query = "release", .rec = rec(.{ .base = "release/1.0" }), .expected = true },
        .{ .query = "\"fix login\"", .rec = rec(.{ .title = "Fix Login bug" }), .expected = true },
        .{ .query = "zzz", .rec = rec(.{}), .expected = false },
    });
}

test "-text excludes matching records" {
    try expectMatchRows(&.{
        .{ .query = "-wip", .rec = rec(.{ .title = "WIP: login" }), .expected = false },
        .{ .query = "-wip", .rec = rec(.{ .title = "login" }), .expected = true },
    });
}

test "terms AND together" {
    try expectMatchRows(&.{
        .{ .query = "is:ready author:alice", .rec = rec(.{ .author = "alice", .is_draft = false }), .expected = true },
        .{ .query = "is:ready author:alice", .rec = rec(.{ .author = "alice", .is_draft = true }), .expected = false },
        .{ .query = "is:ready author:alice", .rec = rec(.{ .author = "bob", .is_draft = false }), .expected = false },
        .{ .query = "login fix", .rec = rec(.{ .title = "login page" }), .expected = false },
    });
}

test "never-hydrated record satisfies review/ci/size terms, negated or not" {
    const fresh = rec(.{ .hydrated_at_update = null, .ci = .failure, .review_decision = "", .additions = 999 });
    const queries = [_][]const u8{
        "review:requested",     "-review:requested",
        "review:approved",      "-review:approved",
        "review:mine-approved", "-review:mine-approved",
        "ci:success",           "-ci:failure",
        "ci:!failure",          "size:<10",
        "-size:>100",
    };
    for (queries) |query_text| {
        testing.expect(try matchOne(.{ .query_text = query_text, .rec = fresh })) catch |err| {
            std.debug.print("query: {s}\n", .{query_text});
            return err;
        };
    }
}

test "never-hydrated record is still filtered by is:/author:/label:/base:/text" {
    const fresh = RecParams{ .hydrated_at_update = null };
    var draft = fresh;
    draft.is_draft = true;
    var bob = fresh;
    bob.author = "bob";
    try expectMatchRows(&.{
        .{ .query = "is:ready", .rec = rec(draft), .expected = false },
        .{ .query = "author:alice", .rec = rec(bob), .expected = false },
        .{ .query = "label:bug", .rec = rec(fresh), .expected = false },
        .{ .query = "base:develop", .rec = rec(fresh), .expected = false },
        .{ .query = "zzz", .rec = rec(fresh), .expected = false },
    });
}

test "stale-hydrated record uses its stale values" {
    const stale = rec(.{ .updated_at = "2026-02-01T00:00:00Z", .hydrated_at_update = "2026-01-01T00:00:00Z", .ci = .failure });
    try testing.expect(!try matchOne(.{ .query_text = "ci:!failure", .rec = stale }));
    try testing.expect(try matchOne(.{ .query_text = "ci:failure", .rec = stale }));
}

test "is:stacked and stack:any read placement height" {
    var query = try expectParseOk("is:stacked stack:any");
    defer query.deinit(testing.allocator);
    const r = rec(.{});
    try testing.expect(!matchesPr(.{ .query = query, .rec = &r, .ctx = .{}, .placement = standalone }));
    try testing.expect(matchesPr(.{ .query = query, .rec = &r, .ctx = .{}, .placement = .{ .height = 2, .target_mark = .bottom, .target_depth = 0 } }));
}

test "stack:top / stack:bottom read target_mark / target_depth and require height > 1" {
    const r = rec(.{});
    const Row = struct { text: []const u8, placement: Placement, expected: bool };
    const rows = [_]Row{
        .{ .text = "stack:top", .placement = .{ .height = 3, .target_mark = .top, .target_depth = 2 }, .expected = true },
        .{ .text = "stack:top", .placement = .{ .height = 3, .target_mark = .middle, .target_depth = 1 }, .expected = false },
        .{ .text = "stack:top", .placement = standalone, .expected = false },
        .{ .text = "stack:bottom", .placement = .{ .height = 3, .target_mark = .bottom, .target_depth = 0 }, .expected = true },
        .{ .text = "stack:bottom", .placement = .{ .height = 3, .target_mark = .top, .target_depth = 2 }, .expected = false },
        .{ .text = "stack:bottom", .placement = standalone, .expected = false },
        .{ .text = "-stack:any", .placement = standalone, .expected = true },
    };
    for (rows) |row| {
        var query = try expectParseOk(row.text);
        defer query.deinit(testing.allocator);
        try testing.expectEqual(row.expected, matchesPr(.{ .query = query, .rec = &r, .ctx = .{}, .placement = row.placement }));
    }
}

test "empty requested_users does not match an empty viewer_login" {
    try expectMatchRows(&.{
        .{ .query = "review:requested-me", .rec = rec(.{ .requested_users = "" }), .expected = false },
        .{ .query = "review:requested-team", .rec = rec(.{ .requested_teams = "" }), .expected = false },
        .{ .query = "review:requested", .rec = rec(.{ .requested_users = "", .requested_teams = "" }), .expected = false },
    });
}

test "matchesPr ignores text terms" {
    var query = try expectParseOk("zzz -alice");
    defer query.deinit(testing.allocator);
    const r = rec(.{ .author = "alice" });
    try testing.expect(matchesPr(.{ .query = query, .rec = &r, .ctx = .{}, .placement = standalone }));
}

// --- A4: stack-level rule, review target, visibleStacks ----------------------

test "text matches a non-target member's branch, so the stack is visible" {
    const records = twoStack(.{});
    const visible = try visibleNumbers(.{ .records = &records, .query_text = "login-ui" });
    defer freeNumbers(visible);
    try expectVisible(&.{&.{ 2, 1 }}, visible);
}

test "negated text matching any member hides the stack" {
    const records = twoStack(.{});
    const hidden = try visibleNumbers(.{ .records = &records, .query_text = "-login-ui" });
    defer freeNumbers(hidden);
    try expectVisible(&.{}, hidden);
    const kept = try visibleNumbers(.{ .records = &records, .query_text = "-nomatch" });
    defer freeNumbers(kept);
    try expectVisible(&.{&.{ 2, 1 }}, kept);
}

test "qualifier on a non-target member does not count" {
    const records = twoStack(.{ .bottom = .{ .is_draft = false }, .tip = .{ .is_draft = true } });
    const draft = try visibleNumbers(.{ .records = &records, .query_text = "is:draft" });
    defer freeNumbers(draft);
    try expectVisible(&.{}, draft);
    const not_draft = try visibleNumbers(.{ .records = &records, .query_text = "-is:draft" });
    defer freeNumbers(not_draft);
    try expectVisible(&.{&.{ 2, 1 }}, not_draft);
}

test "text and qualifiers combine" {
    const records = twoStack(.{ .bottom = .{ .author = "bob" }, .tip = .{ .author = "alice" } });
    const bob = try visibleNumbers(.{ .records = &records, .query_text = "login-ui author:bob" });
    defer freeNumbers(bob);
    try expectVisible(&.{&.{ 2, 1 }}, bob);
    const alice = try visibleNumbers(.{ .records = &records, .query_text = "login-ui author:alice" });
    defer freeNumbers(alice);
    try expectVisible(&.{}, alice);
}

test "single-PR stack targets that PR" {
    const records = [_]PrRecord{rec(.{ .my_review_state = "APPROVED", .my_review_oid = "oid-head" })};
    try testing.expectEqual(@as(usize, 0), try targetOf(&records, &.{0}));
}

test "target is the bottom PR when nothing is approved" {
    // Input bottom, middle, tip; members are tip-first.
    const records = [_]PrRecord{
        rec(.{ .number = 1, .head = "a", .base = "main" }),
        rec(.{ .number = 2, .head = "b", .base = "a" }),
        rec(.{ .number = 3, .head = "c", .base = "b" }),
    };
    try testing.expectEqual(@as(usize, 0), try targetOf(&records, &.{ 2, 1, 0 }));
}

test "target skips PRs the viewer approved at the current head" {
    const records = [_]PrRecord{
        rec(.{ .number = 1, .head = "a", .base = "main", .head_oid = "h1", .my_review_state = "APPROVED", .my_review_oid = "h1" }),
        rec(.{ .number = 2, .head = "b", .base = "a" }),
        rec(.{ .number = 3, .head = "c", .base = "b" }),
    };
    try testing.expectEqual(@as(usize, 1), try targetOf(&records, &.{ 2, 1, 0 }));
}

test "approval at an old head does not skip the PR" {
    const records = [_]PrRecord{
        rec(.{ .number = 1, .head = "a", .base = "main", .head_oid = "h2", .my_review_state = "APPROVED", .my_review_oid = "h1" }),
        rec(.{ .number = 2, .head = "b", .base = "a" }),
    };
    try testing.expectEqual(@as(usize, 0), try targetOf(&records, &.{ 1, 0 }));
}

test "all approved targets the tip" {
    const records = [_]PrRecord{
        rec(.{ .number = 1, .head = "a", .base = "main", .head_oid = "h1", .my_review_state = "APPROVED", .my_review_oid = "h1" }),
        rec(.{ .number = 2, .head = "b", .base = "a", .head_oid = "h2", .my_review_state = "APPROVED", .my_review_oid = "h2" }),
    };
    try testing.expectEqual(@as(usize, 1), try targetOf(&records, &.{ 1, 0 }));
}

test "never-hydrated members are never skipped" {
    const records = [_]PrRecord{
        rec(.{ .number = 1, .head = "a", .base = "main", .hydrated_at_update = null }),
        rec(.{ .number = 2, .head = "b", .base = "a" }),
    };
    try testing.expectEqual(@as(usize, 0), try targetOf(&records, &.{ 1, 0 }));
}

test "forked stack: tie on depth picks the member later in tip-first order" {
    // root (0) is approved; left (1) and right (2) both sit on it at depth 1.
    const records = [_]PrRecord{
        rec(.{ .number = 1, .head = "root", .base = "main", .head_oid = "h1", .my_review_state = "APPROVED", .my_review_oid = "h1" }),
        rec(.{ .number = 2, .head = "left", .base = "root" }),
        rec(.{ .number = 3, .head = "right", .base = "root" }),
    };
    var analysis = try analyzeRecords(&records);
    defer analysis.deinit(testing.allocator);
    const order = try stack.displayOrderOf(testing.allocator, analysis);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, order);
    try testing.expectEqual(@as(usize, 2), reviewTarget(.{ .records = &records, .members = order, .analysis = &analysis }));
}

test "visibleStacks with empty query returns every stack in display order with tip-first members" {
    const records = [_]PrRecord{
        rec(.{ .number = 9, .head = "solo", .base = "main" }),
        rec(.{ .number = 10, .head = "feat", .base = "main" }),
        rec(.{ .number = 11, .head = "feat2", .base = "feat" }),
        rec(.{ .number = 8, .head = "solo2", .base = "main" }),
    };
    const visible = try visibleNumbers(.{ .records = &records, .query_text = "" });
    defer freeNumbers(visible);
    try expectVisible(&.{ &.{9}, &.{ 11, 10 }, &.{8} }, visible);
}

test "visibleStacks lists all members of a visible stack even when non-targets fail the query" {
    const unapproved = twoStack(.{ .bottom = .{ .is_draft = true }, .tip = .{ .is_draft = false } });
    const hidden = try visibleNumbers(.{ .records = &unapproved, .query_text = "-is:draft" });
    defer freeNumbers(hidden);
    try expectVisible(&.{}, hidden);

    const approved = twoStack(.{
        .bottom = .{ .is_draft = true, .head_oid = "h1", .my_review_state = "APPROVED", .my_review_oid = "h1" },
        .tip = .{ .is_draft = false },
    });
    const shown = try visibleNumbers(.{ .records = &approved, .query_text = "-is:draft" });
    defer freeNumbers(shown);
    try expectVisible(&.{&.{ 2, 1 }}, shown);
}

test "visibleStacks hides a stack when a qualifier matches only a non-target member" {
    const records = twoStack(.{ .bottom = .{ .author = "bob" }, .tip = .{ .author = "alice" } });
    const visible = try visibleNumbers(.{ .records = &records, .query_text = "author:alice" });
    defer freeNumbers(visible);
    try expectVisible(&.{}, visible);
}

test "visibleStacks order follows records order of each stack's earliest member" {
    // The stack's tip is listed first, so the stack leads; the solo PR follows.
    const records = [_]PrRecord{
        rec(.{ .number = 2, .head = "b", .base = "a" }),
        rec(.{ .number = 5, .head = "solo", .base = "main" }),
        rec(.{ .number = 1, .head = "a", .base = "main" }),
    };
    const visible = try visibleNumbers(.{ .records = &records, .query_text = "" });
    defer freeNumbers(visible);
    try expectVisible(&.{ &.{ 2, 1 }, &.{5} }, visible);
}

test "stack:top shows only stacks whose target is the tip" {
    const records = [_]PrRecord{
        // Stack A: bottom approved, so the target is the tip.
        rec(.{ .number = 1, .head = "a1", .base = "main", .head_oid = "h1", .my_review_state = "APPROVED", .my_review_oid = "h1" }),
        rec(.{ .number = 2, .head = "a2", .base = "a1" }),
        // Stack B: nothing approved, so the target is the bottom.
        rec(.{ .number = 3, .head = "b1", .base = "main" }),
        rec(.{ .number = 4, .head = "b2", .base = "b1" }),
        // Standalone.
        rec(.{ .number = 5, .head = "solo", .base = "main" }),
    };
    const top = try visibleNumbers(.{ .records = &records, .query_text = "stack:top" });
    defer freeNumbers(top);
    try expectVisible(&.{&.{ 2, 1 }}, top);
    const bottom = try visibleNumbers(.{ .records = &records, .query_text = "stack:bottom" });
    defer freeNumbers(bottom);
    try expectVisible(&.{&.{ 4, 3 }}, bottom);
}

test "review:requested at stack granularity" {
    const ctx = EvalContext{ .viewer_login = "alice" };
    const unapproved = twoStack(.{ .tip = .{ .requested_users = "alice" } });
    const hidden = try visibleNumbers(.{ .records = &unapproved, .query_text = "review:requested", .ctx = ctx });
    defer freeNumbers(hidden);
    try expectVisible(&.{}, hidden);

    const approved = twoStack(.{
        .bottom = .{ .head_oid = "h1", .my_review_state = "APPROVED", .my_review_oid = "h1" },
        .tip = .{ .requested_users = "alice" },
    });
    const shown = try visibleNumbers(.{ .records = &approved, .query_text = "review:requested", .ctx = ctx });
    defer freeNumbers(shown);
    try expectVisible(&.{&.{ 2, 1 }}, shown);
}

test "StackView members slice into member_storage and deinit frees everything" {
    const records = [_]PrRecord{
        rec(.{ .number = 1, .head = "a", .base = "main" }),
        rec(.{ .number = 2, .head = "b", .base = "a" }),
        rec(.{ .number = 3, .head = "solo", .base = "main" }),
    };
    var analysis = try analyzeRecords(&records);
    defer analysis.deinit(testing.allocator);
    var query = try expectParseOk("");
    defer query.deinit(testing.allocator);
    var visible = try visibleStacks(testing.allocator, .{ .records = &records, .analysis = &analysis, .query = query, .ctx = .{} });
    defer visible.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), visible.views.len);
    const storage_start = @intFromPtr(visible.member_storage.ptr);
    const storage_end = storage_start + visible.member_storage.len * @sizeOf(usize);
    for (visible.views) |view| {
        try testing.expect(@intFromPtr(view.members.ptr) >= storage_start);
        try testing.expect(@intFromPtr(view.members.ptr) + view.members.len * @sizeOf(usize) <= storage_end);
        try testing.expectEqual(analysis.stack_of[view.target], view.stack_id);
    }
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, visible.views[0].members);
    try testing.expectEqual(@as(usize, 0), visible.views[0].target);
    try testing.expectEqualSlices(usize, &.{2}, visible.views[1].members);
}

test "visibleStacks survives allocation failure at every point" {
    const records = [_]PrRecord{
        rec(.{ .number = 1, .head = "a", .base = "main" }),
        rec(.{ .number = 2, .head = "b", .base = "a" }),
        rec(.{ .number = 3, .head = "solo", .base = "main" }),
    };
    var analysis = try analyzeRecords(&records);
    defer analysis.deinit(testing.allocator);
    var query = try expectParseOk("solo");
    defer query.deinit(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, visibleAndFree, .{ &records, &analysis, query });
}

fn visibleAndFree(allocator: std.mem.Allocator, records: []const PrRecord, analysis: *const stack.Analysis, query: Query) !void {
    var visible = try visibleStacks(allocator, .{ .records = records, .analysis = analysis, .query = query, .ctx = .{} });
    visible.deinit(allocator);
}

test "edgesOf mirrors head_ref and base_ref of each record" {
    const records = [_]PrRecord{
        rec(.{ .head = "a", .base = "main" }),
        rec(.{ .head = "b", .base = "a" }),
    };
    const edges = try edgesOf(testing.allocator, &records);
    defer testing.allocator.free(edges);
    try testing.expectEqual(@as(usize, 2), edges.len);
    try testing.expectEqualStrings("a", edges[0].head_ref);
    try testing.expectEqualStrings("main", edges[0].base_ref);
    try testing.expectEqualStrings("b", edges[1].head_ref);
    try testing.expectEqualStrings("a", edges[1].base_ref);
}

test "visibleStacks on zero records returns zero views" {
    const visible = try visibleNumbers(.{ .records = &.{}, .query_text = "is:draft" });
    defer freeNumbers(visible);
    try expectVisible(&.{}, visible);
}
