//! Bind an offer directly through App for tests of credentials and transport.
const cc = @import("cc");

pub const Outcome = union(enum) {
    switched,
    not_in_catalog,
    ambiguous,
    failed: []const u8,
};

pub fn useSelector(app: *cc.app_module.App, selector: []const u8) Outcome {
    const host = app.providerHost() catch |err| return .{ .failed = @errorName(err) };
    const catalog = host.kernel.catalogSnapshot();
    const offer = if (cc.provider_ids.OfferId.parse(selector)) |id|
        catalog.find(id)
    else |_| selected: {
        var unique: ?*const cc.provider_registry.ModelOffer = null;
        for (catalog.items()) |*item| {
            if (!cc.provider_registry.matchesSelector(item.*, selector)) continue;
            if (unique != null) return .ambiguous;
            unique = item;
        }
        break :selected unique;
    };
    const chosen = offer orelse return .not_in_catalog;
    const result = app.commitModelSelection(.{
        .offer_id = chosen.offer_id,
        .offer_revision = chosen.offer_revision,
        .scope = .session,
        .controls = .{},
    }) catch |err| return .{ .failed = @errorName(err) };
    return switch (result) {
        .committed => .switched,
        .rejected => |reason| .{ .failed = @tagName(reason) },
        .conflict => .{ .failed = "configuration conflict" },
    };
}
