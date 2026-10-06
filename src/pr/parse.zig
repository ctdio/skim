//! PR CI status shared by the store (`pr.ci` column), sync parsing and the
//! sidebar glyphs.

pub const CiStatus = enum {
    none,
    pending,
    success,
    failure,
};
