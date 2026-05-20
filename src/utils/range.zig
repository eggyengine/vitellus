/// Describes a continuous span of items between the first and the final.
pub const Range = struct {
    first: u32,
    count: u32,

    /// Creates a half-open range: `[first, end)` or `first <= x < end`
    ///
    /// Example: `Range.exclusive(2, 5)` creates a range that includes `2`, `3`, and `4`, but not `5`.
    pub fn exclusive(first: anytype, end: anytype) Range {
        return .{
            .first = @intCast(first),
            .count = @intCast(end - first),
        };
    }

    /// Creates a closed range: `[first, end]` or `first <= x <= end`
    ///
    /// Example: `Range.inclusive(2, 5)` creates a range that includes `2`, `3`, `4`, and `5`.
    pub fn inclusive(first: anytype, end: anytype) Range {
        return .{
            .first = @intCast(first),
            .count = @intCast(end - first + 1),
        };
    }
};
