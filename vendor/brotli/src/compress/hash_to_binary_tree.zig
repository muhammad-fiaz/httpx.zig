//! Binary-tree hasher implementation (H10).
//!
//! Maintains a binary tree of matches for long history lookups and integrates
//! static dictionary matching for maximal LZ77 match extraction.

const std = @import("std");
const hlmq = @import("hash_longest_match_quickly.zig");
const dictionary = @import("../dictionary/dictionary.zig");
const static_dict_lut = @import("static_dict_lut.zig");

pub const kInvalidMatch: u32 = 0xFFFFFFFF;
pub const BROTLI_MAX_STATIC_DICTIONARY_MATCH_LEN: usize = 37;
pub const BROTLI_WINDOW_GAP: usize = 16;
pub const MAX_NUM_MATCHES_H10: usize = 128;

pub const BackwardMatch = struct {
    distance: usize = 0,
    length_and_code: usize = 0,

    pub inline fn length(self: BackwardMatch) usize {
        return self.length_and_code >> 5;
    }

    pub inline fn lengthCode(self: BackwardMatch) usize {
        const code = self.length_and_code & 31;
        return if (code != 0) code else self.length();
    }

    pub inline fn initMatch(dist: usize, len: usize) BackwardMatch {
        return .{
            .distance = dist,
            .length_and_code = len << 5,
        };
    }

    pub inline fn initDictionaryMatch(dist: usize, len: usize, len_code: usize) BackwardMatch {
        return .{
            .distance = dist,
            .length_and_code = (len << 5) | (len_code & 31),
        };
    }
};

pub inline fn findMatchLengthWithLimit(s1: []const u8, s2: []const u8, limit: usize) usize {
    const lim = @min(limit, @min(s1.len, s2.len));
    var matched: usize = 0;
    while (matched + 8 <= lim) : (matched += 8) {
        const x = std.mem.readInt(u64, s1[matched..][0..8], .little) ^ std.mem.readInt(u64, s2[matched..][0..8], .little);
        if (x != 0) {
            return matched + (@ctz(x) >> 3);
        }
    }
    while (matched < lim and s1[matched] == s2[matched]) : (matched += 1) {}
    return matched;
}

pub inline fn hash15(data: []const u8) u32 {
    const v = std.mem.readInt(u32, data[0..4], .little);
    return (v *% 0x1E35A7BD) >> (32 - 15);
}

fn dictMatchLength(id: usize, len: usize, data: []const u8, maxlen: usize) usize {
    const offset = dictionary.offsets_by_length[len] + len * id;
    const dict_slice = dictionary.data[offset..];
    return findMatchLengthWithLimit(dict_slice[0..@min(len, maxlen)], data[0..@min(len, maxlen)], @min(len, maxlen));
}

fn isMatch(w: static_dict_lut.DictWord, data: []const u8, max_length: usize) bool {
    const w_len: usize = w.len;
    if (w_len > max_length) return false;
    const offset = dictionary.offsets_by_length[w_len] + w_len * @as(usize, w.idx);
    const dict_slice = dictionary.data[offset..];
    if (w.transform == 0) {
        return findMatchLengthWithLimit(dict_slice[0..w_len], data[0..w_len], w_len) == w_len;
    } else if (w.transform == 10) {
        // Uppercase first
        return std.ascii.isLower(dict_slice[0]) and
            std.ascii.toUpper(dict_slice[0]) == data[0] and
            findMatchLengthWithLimit(dict_slice[1..w_len], data[1..w_len], w_len - 1) == w_len - 1;
    } else {
        // Uppercase all
        for (0..w_len) |i| {
            if (std.ascii.toUpper(dict_slice[i]) != data[i]) return false;
        }
        return true;
    }
}

inline fn addDictMatch(distance: usize, len: usize, len_code: usize, matches: []u32) void {
    const match = (@as(u32, @intCast(distance)) << 5) + @as(u32, @intCast(len_code));
    matches[len] = @min(matches[len], match);
}

pub fn findAllStaticDictionaryMatches(
    data: []const u8,
    min_length: usize,
    max_length: usize,
    matches: []u32,
) bool {
    var has_found_match = false;
    const buckets = &static_dict_lut.kStaticDictionaryBuckets;
    const dict_words = &static_dict_lut.kStaticDictionaryWords;
    const kCutoffTransforms: u64 = 0x071B520ADA2D3200;

    if (data.len >= 4) {
        var offset: usize = buckets[hash15(data)];
        var end = (offset == 0);
        while (!end) {
            var w = dict_words[offset];
            offset += 1;
            const l: usize = w.len & 0x1F;
            const n: usize = @as(usize, 1) << @intCast(dictionary.size_bits_by_length[l]);
            const id: usize = w.idx;
            end = (w.len & 0x80) != 0;
            w.len = @intCast(l);

            if (w.transform == 0) {
                const matchlen = dictMatchLength(id, l, data, max_length);
                if (matchlen == l) {
                    addDictMatch(id, l, l, matches);
                    has_found_match = true;
                }
                if (matchlen >= l - 1) {
                    addDictMatch(id + 12 * n, l - 1, l, matches);
                    if (l + 2 < max_length and data.len > l + 2 and
                        data[l - 1] == 'i' and data[l] == 'n' and data[l + 1] == 'g' and data[l + 2] == ' ')
                    {
                        addDictMatch(id + 49 * n, l + 3, l, matches);
                    }
                    has_found_match = true;
                }
                var minlen = min_length;
                if (l > 9) minlen = @max(minlen, l - 9);
                const maxlen = @min(matchlen, l - 2);
                if (minlen <= maxlen) {
                    var len = minlen;
                    while (len <= maxlen) : (len += 1) {
                        const cut = l - len;
                        const transform_id = (cut << 2) + @as(usize, @intCast((kCutoffTransforms >> @intCast(cut * 6)) & 0x3F));
                        addDictMatch(id + transform_id * n, len, l, matches);
                        has_found_match = true;
                    }
                }
                if (matchlen >= l and l + 6 < max_length and data.len > l) {
                    const s = data[l..];
                    if (s[0] == ' ') {
                        addDictMatch(id + n, l + 1, l, matches);
                        if (s.len > 1 and s[1] == 'a') {
                            if (s.len > 2 and s[2] == ' ') {
                                addDictMatch(id + 28 * n, l + 3, l, matches);
                            } else if (s.len > 3 and s[2] == 's' and s[3] == ' ') {
                                addDictMatch(id + 46 * n, l + 4, l, matches);
                            } else if (s.len > 3 and s[2] == 't' and s[3] == ' ') {
                                addDictMatch(id + 60 * n, l + 4, l, matches);
                            } else if (s.len > 4 and s[2] == 'n' and s[3] == 'd' and s[4] == ' ') {
                                addDictMatch(id + 10 * n, l + 5, l, matches);
                            }
                        } else if (s.len > 3 and s[1] == 'b' and s[2] == 'y' and s[3] == ' ') {
                            addDictMatch(id + 38 * n, l + 4, l, matches);
                        } else if (s.len > 2 and s[1] == 'i') {
                            if (s.len > 3 and s[2] == 'n' and s[3] == ' ') {
                                addDictMatch(id + 16 * n, l + 4, l, matches);
                            } else if (s.len > 3 and s[2] == 's' and s[3] == ' ') {
                                addDictMatch(id + 47 * n, l + 4, l, matches);
                            }
                        } else if (s.len > 2 and s[1] == 'f') {
                            if (s.len > 4 and s[2] == 'o' and s[3] == 'r' and s[4] == ' ') {
                                addDictMatch(id + 25 * n, l + 5, l, matches);
                            } else if (s.len > 5 and s[2] == 'r' and s[3] == 'o' and s[4] == 'm' and s[5] == ' ') {
                                addDictMatch(id + 37 * n, l + 6, l, matches);
                            }
                        } else if (s.len > 2 and s[1] == 'o') {
                            if (s.len > 3 and s[2] == 'f' and s[3] == ' ') {
                                addDictMatch(id + 8 * n, l + 4, l, matches);
                            } else if (s.len > 3 and s[2] == 'n' and s[3] == ' ') {
                                addDictMatch(id + 45 * n, l + 4, l, matches);
                            }
                        } else if (s.len > 4 and s[1] == 'n' and s[2] == 'o' and s[3] == 't' and s[4] == ' ') {
                            addDictMatch(id + 80 * n, l + 5, l, matches);
                        } else if (s.len > 2 and s[1] == 't') {
                            if (s.len > 4 and s[2] == 'h' and s[3] == 'e' and s[4] == ' ') {
                                addDictMatch(id + 5 * n, l + 5, l, matches);
                            } else if (s.len > 5 and s[2] == 'a' and s[3] == 't' and s[4] == ' ') {
                                addDictMatch(id + 29 * n, l + 6, l, matches);
                            } else if (s.len > 3 and s[2] == 'o' and s[3] == ' ') {
                                addDictMatch(id + 17 * n, l + 4, l, matches);
                            }
                        } else if (s.len > 5 and s[1] == 'w' and s[2] == 'i' and s[3] == 't' and s[4] == 'h' and s[5] == ' ') {
                            addDictMatch(id + 35 * n, l + 6, l, matches);
                        }
                    } else if (s[0] == '"') {
                        addDictMatch(id + 19 * n, l + 1, l, matches);
                        if (s.len > 1 and s[1] == '>') {
                            addDictMatch(id + 21 * n, l + 2, l, matches);
                        }
                    } else if (s[0] == '.') {
                        addDictMatch(id + 20 * n, l + 1, l, matches);
                        if (s.len > 1 and s[1] == ' ') {
                            addDictMatch(id + 31 * n, l + 2, l, matches);
                            if (s.len > 5 and s[2] == 'T' and s[3] == 'h') {
                                if (s[4] == 'e' and s[5] == ' ') {
                                    addDictMatch(id + 43 * n, l + 6, l, matches);
                                } else if (s.len > 6 and s[4] == 'i' and s[5] == 's' and s[6] == ' ') {
                                    addDictMatch(id + 75 * n, l + 7, l, matches);
                                }
                            }
                        }
                    } else if (s[0] == ',') {
                        addDictMatch(id + 76 * n, l + 1, l, matches);
                        if (s.len > 1 and s[1] == ' ') {
                            addDictMatch(id + 14 * n, l + 2, l, matches);
                        }
                    } else if (s[0] == '\n') {
                        addDictMatch(id + 22 * n, l + 1, l, matches);
                        if (s.len > 1 and s[1] == '\t') {
                            addDictMatch(id + 50 * n, l + 2, l, matches);
                        }
                    } else if (s[0] == ']') {
                        addDictMatch(id + 24 * n, l + 1, l, matches);
                    } else if (s[0] == '\'') {
                        addDictMatch(id + 36 * n, l + 1, l, matches);
                    } else if (s[0] == ':') {
                        addDictMatch(id + 51 * n, l + 1, l, matches);
                    } else if (s[0] == '(') {
                        addDictMatch(id + 57 * n, l + 1, l, matches);
                    } else if (s.len > 1 and s[0] == '=') {
                        if (s[1] == '"') {
                            addDictMatch(id + 70 * n, l + 2, l, matches);
                        } else if (s[1] == '\'') {
                            addDictMatch(id + 86 * n, l + 2, l, matches);
                        }
                    } else if (s.len > 2 and s[0] == 'a' and s[1] == 'l' and s[2] == ' ') {
                        addDictMatch(id + 84 * n, l + 3, l, matches);
                    } else if (s.len > 2 and s[0] == 'e') {
                        if (s[1] == 'd' and s[2] == ' ') {
                            addDictMatch(id + 53 * n, l + 3, l, matches);
                        } else if (s[1] == 'r' and s[2] == ' ') {
                            addDictMatch(id + 82 * n, l + 3, l, matches);
                        } else if (s.len > 3 and s[1] == 's' and s[2] == 't' and s[3] == ' ') {
                            addDictMatch(id + 95 * n, l + 4, l, matches);
                        }
                    } else if (s.len > 3 and s[0] == 'f' and s[1] == 'u' and s[2] == 'l' and s[3] == ' ') {
                        addDictMatch(id + 90 * n, l + 4, l, matches);
                    } else if (s.len > 3 and s[0] == 'i') {
                        if (s[1] == 'v' and s[2] == 'e' and s[3] == ' ') {
                            addDictMatch(id + 92 * n, l + 4, l, matches);
                        } else if (s[1] == 'z' and s[2] == 'e' and s[3] == ' ') {
                            addDictMatch(id + 100 * n, l + 4, l, matches);
                        }
                    } else if (s.len > 2 and s[0] == 'l') {
                        if (s.len > 4 and s[1] == 'e' and s[2] == 's' and s[3] == 's' and s[4] == ' ') {
                            addDictMatch(id + 93 * n, l + 5, l, matches);
                        } else if (s[1] == 'y' and s[2] == ' ') {
                            addDictMatch(id + 61 * n, l + 3, l, matches);
                        }
                    } else if (s.len > 3 and s[0] == 'o' and s[1] == 'u' and s[2] == 's' and s[3] == ' ') {
                        addDictMatch(id + 106 * n, l + 4, l, matches);
                    }
                }
            } else {
                const is_all_caps = (w.transform != 10);
                if (isMatch(w, data, max_length)) {
                    addDictMatch(id + (if (is_all_caps) @as(usize, 44) else 9) * n, l, l, matches);
                    has_found_match = true;
                    if (l + 1 < max_length and data.len > l) {
                        const s = data[l..];
                        if (s[0] == ' ') {
                            addDictMatch(id + (if (is_all_caps) @as(usize, 68) else 4) * n, l + 1, l, matches);
                        } else if (s[0] == '"') {
                            addDictMatch(id + (if (is_all_caps) @as(usize, 87) else 66) * n, l + 1, l, matches);
                            if (s.len > 1 and s[1] == '>') {
                                addDictMatch(id + (if (is_all_caps) @as(usize, 97) else 69) * n, l + 2, l, matches);
                            }
                        } else if (s[0] == '.') {
                            addDictMatch(id + (if (is_all_caps) @as(usize, 101) else 79) * n, l + 1, l, matches);
                            if (s.len > 1 and s[1] == ' ') {
                                addDictMatch(id + (if (is_all_caps) @as(usize, 114) else 88) * n, l + 2, l, matches);
                            }
                        } else if (s[0] == ',') {
                            addDictMatch(id + (if (is_all_caps) @as(usize, 112) else 99) * n, l + 1, l, matches);
                            if (s.len > 1 and s[1] == ' ') {
                                addDictMatch(id + (if (is_all_caps) @as(usize, 107) else 58) * n, l + 2, l, matches);
                            }
                        } else if (s[0] == '\'') {
                            addDictMatch(id + (if (is_all_caps) @as(usize, 94) else 74) * n, l + 1, l, matches);
                        } else if (s[0] == '(') {
                            addDictMatch(id + (if (is_all_caps) @as(usize, 113) else 78) * n, l + 1, l, matches);
                        } else if (s.len > 1 and s[0] == '=') {
                            if (s[1] == '"') {
                                addDictMatch(id + (if (is_all_caps) @as(usize, 105) else 104) * n, l + 2, l, matches);
                            } else if (s[1] == '\'') {
                                addDictMatch(id + (if (is_all_caps) @as(usize, 116) else 108) * n, l + 2, l, matches);
                            }
                        }
                    }
                }
            }
        }
    }

    // Prefixes " " and "."
    if (max_length >= 5 and data.len >= 5 and (data[0] == ' ' or data[0] == '.')) {
        const is_space = (data[0] == ' ');
        var offset: usize = buckets[hash15(data[1..])];
        var end = (offset == 0);
        while (!end) {
            var w = dict_words[offset];
            offset += 1;
            const l: usize = w.len & 0x1F;
            const n: usize = @as(usize, 1) << @intCast(dictionary.size_bits_by_length[l]);
            const id: usize = w.idx;
            end = (w.len & 0x80) != 0;
            w.len = @intCast(l);

            if (w.transform == 0) {
                if (isMatch(w, data[1..], max_length - 1)) {
                    addDictMatch(id + (if (is_space) @as(usize, 6) else 32) * n, l + 1, l, matches);
                    has_found_match = true;
                    if (l + 2 < max_length and data.len > l + 1) {
                        const s = data[l + 1 ..];
                        if (s[0] == ' ') {
                            addDictMatch(id + (if (is_space) @as(usize, 2) else 77) * n, l + 2, l, matches);
                        } else if (s[0] == '(') {
                            addDictMatch(id + (if (is_space) @as(usize, 89) else 67) * n, l + 2, l, matches);
                        } else if (is_space) {
                            if (s[0] == ',') {
                                addDictMatch(id + 103 * n, l + 2, l, matches);
                                if (s.len > 1 and s[1] == ' ') {
                                    addDictMatch(id + 33 * n, l + 3, l, matches);
                                }
                            } else if (s[0] == '.') {
                                addDictMatch(id + 71 * n, l + 2, l, matches);
                                if (s.len > 1 and s[1] == ' ') {
                                    addDictMatch(id + 52 * n, l + 3, l, matches);
                                }
                            } else if (s.len > 1 and s[0] == '=') {
                                if (s[1] == '"') {
                                    addDictMatch(id + 81 * n, l + 3, l, matches);
                                } else if (s[1] == '\'') {
                                    addDictMatch(id + 98 * n, l + 3, l, matches);
                                }
                            }
                        }
                    }
                }
            } else if (is_space) {
                const is_all_caps = (w.transform != 10);
                if (isMatch(w, data[1..], max_length - 1)) {
                    addDictMatch(id + (if (is_all_caps) @as(usize, 85) else 30) * n, l + 1, l, matches);
                    has_found_match = true;
                    if (l + 2 < max_length and data.len > l + 1) {
                        const s = data[l + 1 ..];
                        if (s[0] == ' ') {
                            addDictMatch(id + (if (is_all_caps) @as(usize, 83) else 15) * n, l + 2, l, matches);
                        } else if (s[0] == ',') {
                            if (!is_all_caps) {
                                addDictMatch(id + 109 * n, l + 2, l, matches);
                            }
                            if (s.len > 1 and s[1] == ' ') {
                                addDictMatch(id + (if (is_all_caps) @as(usize, 111) else 65) * n, l + 3, l, matches);
                            }
                        } else if (s[0] == '.') {
                            addDictMatch(id + (if (is_all_caps) @as(usize, 115) else 96) * n, l + 2, l, matches);
                            if (s.len > 1 and s[1] == ' ') {
                                addDictMatch(id + (if (is_all_caps) @as(usize, 117) else 91) * n, l + 3, l, matches);
                            }
                        } else if (s.len > 1 and s[0] == '=') {
                            if (s[1] == '"') {
                                addDictMatch(id + (if (is_all_caps) @as(usize, 110) else 118) * n, l + 3, l, matches);
                            } else if (s[1] == '\'') {
                                addDictMatch(id + (if (is_all_caps) @as(usize, 119) else 120) * n, l + 3, l, matches);
                            }
                        }
                    }
                }
            }
        }
    }

    // Prefixes "e ", "s ", ", " and "\xC2\xA0"
    if (max_length >= 6 and data.len >= 6) {
        if ((data[1] == ' ' and (data[0] == 'e' or data[0] == 's' or data[0] == ',')) or
            (data[0] == 0xC2 and data[1] == 0xA0))
        {
            var offset: usize = buckets[hash15(data[2..])];
            var end = (offset == 0);
            while (!end) {
                var w = dict_words[offset];
                offset += 1;
                const l: usize = w.len & 0x1F;
                const n: usize = @as(usize, 1) << @intCast(dictionary.size_bits_by_length[l]);
                const id: usize = w.idx;
                end = (w.len & 0x80) != 0;
                w.len = @intCast(l);

                if (w.transform == 0 and isMatch(w, data[2..], max_length - 2)) {
                    if (data[0] == 0xC2) {
                        addDictMatch(id + 102 * n, l + 2, l, matches);
                        has_found_match = true;
                    } else if (l + 2 < max_length and data.len > l + 2 and data[l + 2] == ' ') {
                        const t: usize = if (data[0] == 'e') 18 else (if (data[0] == 's') 7 else 13);
                        addDictMatch(id + t * n, l + 3, l, matches);
                        has_found_match = true;
                    }
                }
            }
        }
    }

    // Prefixes " the " and ".com/"
    if (max_length >= 9 and data.len >= 9) {
        if ((data[0] == ' ' and data[1] == 't' and data[2] == 'h' and data[3] == 'e' and data[4] == ' ') or
            (data[0] == '.' and data[1] == 'c' and data[2] == 'o' and data[3] == 'm' and data[4] == '/'))
        {
            var offset: usize = buckets[hash15(data[5..])];
            var end = (offset == 0);
            while (!end) {
                var w = dict_words[offset];
                offset += 1;
                const l: usize = w.len & 0x1F;
                const n: usize = @as(usize, 1) << @intCast(dictionary.size_bits_by_length[l]);
                const id: usize = w.idx;
                end = (w.len & 0x80) != 0;
                w.len = @intCast(l);

                if (w.transform == 0 and isMatch(w, data[5..], max_length - 5)) {
                    addDictMatch(id + (if (data[0] == ' ') @as(usize, 41) else 72) * n, l + 5, l, matches);
                    has_found_match = true;
                    if (l + 5 < max_length and data.len > l + 5) {
                        const s = data[l + 5 ..];
                        if (data[0] == ' ') {
                            if (l + 8 < max_length and s.len >= 4 and s[0] == ' ' and s[1] == 'o' and s[2] == 'f' and s[3] == ' ') {
                                addDictMatch(id + 62 * n, l + 9, l, matches);
                                if (l + 12 < max_length and s.len >= 8 and s[4] == 't' and s[5] == 'h' and s[6] == 'e' and s[7] == ' ') {
                                    addDictMatch(id + 73 * n, l + 13, l, matches);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return has_found_match;
}

pub fn HashToBinaryTree(
    comptime BUCKET_BITS: usize,
    comptime MAX_TREE_SEARCH_DEPTH: usize,
    comptime MAX_TREE_COMP_LENGTH: usize,
) type {
    return struct {
        const Self = @This();
        pub const BUCKET_SIZE: usize = 1 << BUCKET_BITS;

        buckets: []u32,
        forest: []u32,
        window_mask: usize,
        invalid_pos: u32,

        pub fn init(allocator: std.mem.Allocator, lgwin: u5, one_shot: bool, input_size: usize) !Self {
            var num_nodes: usize = @as(usize, 1) << lgwin;
            if (one_shot and input_size < num_nodes) {
                num_nodes = input_size;
            }
            const buckets = try allocator.alloc(u32, BUCKET_SIZE);
            errdefer allocator.free(buckets);
            const forest = try allocator.alloc(u32, 2 * num_nodes);
            errdefer allocator.free(forest);

            const window_mask = (@as(usize, 1) << lgwin) - 1;
            const invalid_pos = @as(u32, @truncate(0 -% window_mask));

            return .{
                .buckets = buckets,
                .forest = forest,
                .window_mask = window_mask,
                .invalid_pos = invalid_pos,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buckets);
            allocator.free(self.forest);
        }

        pub inline fn hashTypeLength(_: *const Self) usize {
            return 4;
        }

        pub inline fn storeLookahead(_: *const Self) usize {
            return MAX_TREE_COMP_LENGTH;
        }

        pub inline fn hashBytes(data: []const u8) u32 {
            const v = std.mem.readInt(u32, data[0..4], .little);
            return (v *% hlmq.kHashMul32) >> @intCast(32 - BUCKET_BITS);
        }

        pub fn prepare(self: *Self) void {
            @memset(self.buckets, self.invalid_pos);
        }

        inline fn leftChildIndex(self: *const Self, pos: usize) usize {
            return 2 * (pos & self.window_mask);
        }

        inline fn rightChildIndex(self: *const Self, pos: usize) usize {
            return 2 * (pos & self.window_mask) + 1;
        }

        pub fn storeAndFindMatches(
            self: *Self,
            data: []const u8,
            cur_ix: usize,
            ring_buffer_mask: usize,
            max_length: usize,
            max_backward: usize,
            best_len: ?*usize,
            matches: ?[]BackwardMatch,
            matches_count: *usize,
        ) void {
            const cur_ix_masked = cur_ix & ring_buffer_mask;
            const max_comp_len = @min(max_length, MAX_TREE_COMP_LENGTH);
            const should_reroot_tree = (max_length >= MAX_TREE_COMP_LENGTH);
            const key = hashBytes(data[cur_ix_masked..]);
            var prev_ix = self.buckets[key];
            var node_left = self.leftChildIndex(cur_ix);
            var node_right = self.rightChildIndex(cur_ix);
            var best_len_left: usize = 0;
            var best_len_right: usize = 0;

            if (should_reroot_tree) {
                self.buckets[key] = @intCast(cur_ix);
            }

            var depth_remaining: usize = MAX_TREE_SEARCH_DEPTH;
            while (true) : (depth_remaining -= 1) {
                const backward = cur_ix -% prev_ix;
                const prev_ix_masked = prev_ix & ring_buffer_mask;
                if (backward == 0 or backward > max_backward or depth_remaining == 0) {
                    if (should_reroot_tree) {
                        self.forest[node_left] = self.invalid_pos;
                        self.forest[node_right] = self.invalid_pos;
                    }
                    break;
                }
                const cur_len = @min(best_len_left, best_len_right);
                const len = cur_len + findMatchLengthWithLimit(
                    data[cur_ix_masked + cur_len ..],
                    data[prev_ix_masked + cur_len ..],
                    max_length - cur_len,
                );
                if (matches != null and best_len != null and len > best_len.?.*) {
                    best_len.?.* = len;
                    matches.?[matches_count.*] = BackwardMatch.initMatch(backward, len);
                    matches_count.* += 1;
                }
                if (len >= max_comp_len) {
                    if (should_reroot_tree) {
                        self.forest[node_left] = self.forest[self.leftChildIndex(prev_ix)];
                        self.forest[node_right] = self.forest[self.rightChildIndex(prev_ix)];
                    }
                    break;
                }
                if (data[cur_ix_masked + len] > data[prev_ix_masked + len]) {
                    best_len_left = len;
                    if (should_reroot_tree) {
                        self.forest[node_left] = @intCast(prev_ix);
                    }
                    node_left = self.rightChildIndex(prev_ix);
                    prev_ix = self.forest[node_left];
                } else {
                    best_len_right = len;
                    if (should_reroot_tree) {
                        self.forest[node_right] = @intCast(prev_ix);
                    }
                    node_right = self.leftChildIndex(prev_ix);
                    prev_ix = self.forest[node_right];
                }
            }
        }

        pub fn findAllMatches(
            self: *Self,
            data: []const u8,
            ring_buffer_mask: usize,
            cur_ix: usize,
            max_length: usize,
            max_backward: usize,
            dictionary_distance: usize,
            max_distance: usize,
            quality: u32,
            matches: []BackwardMatch,
        ) usize {
            var matches_count: usize = 0;
            const cur_ix_masked = cur_ix & ring_buffer_mask;
            var best_len: usize = 1;
            const short_match_max_backward: usize = if (quality != 11) 16 else 64;
            const stop = if (cur_ix >= short_match_max_backward) cur_ix - short_match_max_backward else 0;

            if (cur_ix > 0) {
                var i = cur_ix - 1;
                while (i > stop and best_len <= 2) : (i -= 1) {
                    const prev_ix = i;
                    const backward = cur_ix - prev_ix;
                    if (backward > max_backward) break;
                    const prev_ix_masked = prev_ix & ring_buffer_mask;
                    if (data[cur_ix_masked] != data[prev_ix_masked] or
                        data[cur_ix_masked + 1] != data[prev_ix_masked + 1])
                    {
                        continue;
                    }
                    const len = findMatchLengthWithLimit(
                        data[prev_ix_masked..],
                        data[cur_ix_masked..],
                        max_length,
                    );
                    if (len > best_len) {
                        best_len = len;
                        matches[matches_count] = BackwardMatch.initMatch(backward, len);
                        matches_count += 1;
                    }
                }
            }

            if (best_len < max_length) {
                self.storeAndFindMatches(
                    data,
                    cur_ix,
                    ring_buffer_mask,
                    max_length,
                    max_backward,
                    &best_len,
                    matches,
                    &matches_count,
                );
            }

            var dict_matches: [BROTLI_MAX_STATIC_DICTIONARY_MATCH_LEN + 1]u32 = @splat(kInvalidMatch);
            const minlen = @max(4, best_len + 1);
            if (findAllStaticDictionaryMatches(data[cur_ix_masked..], minlen, max_length, &dict_matches)) {
                const maxlen = @min(BROTLI_MAX_STATIC_DICTIONARY_MATCH_LEN, max_length);
                var l = minlen;
                while (l <= maxlen) : (l += 1) {
                    const dict_id = dict_matches[l];
                    if (dict_id < kInvalidMatch) {
                        const distance = dictionary_distance + (dict_id >> 5) + 1;
                        if (distance <= max_distance) {
                            matches[matches_count] = BackwardMatch.initDictionaryMatch(distance, l, dict_id & 31);
                            matches_count += 1;
                        }
                    }
                }
            }

            return matches_count;
        }

        pub inline fn store(self: *Self, data: []const u8, mask: usize, ix: usize) void {
            const max_backward = self.window_mask - BROTLI_WINDOW_GAP + 1;
            var dummy: usize = 0;
            self.storeAndFindMatches(data, ix, mask, MAX_TREE_COMP_LENGTH, max_backward, null, null, &dummy);
        }

        pub fn storeRange(self: *Self, data: []const u8, mask: usize, ix_start: usize, ix_end: usize) void {
            var i = ix_start;
            var j = ix_start;
            if (ix_start + 63 <= ix_end) {
                i = ix_end - 63;
            }
            if (ix_start + 512 <= i) {
                while (j < i) : (j += 8) {
                    self.store(data, mask, j);
                }
            }
            while (i < ix_end) : (i += 1) {
                self.store(data, mask, i);
            }
        }

        pub fn stitchToPreviousBlock(
            self: *Self,
            num_bytes: usize,
            position: usize,
            ringbuffer: []const u8,
            ringbuffer_mask: usize,
        ) void {
            if (num_bytes >= self.hashTypeLength() - 1 and position >= MAX_TREE_COMP_LENGTH) {
                const i_start = position - MAX_TREE_COMP_LENGTH + 1;
                const i_end = @min(position, i_start + num_bytes);
                var i = i_start;
                while (i < i_end) : (i += 1) {
                    const max_backward = self.window_mask - @max(BROTLI_WINDOW_GAP - 1, position - i);
                    var dummy: usize = 0;
                    self.storeAndFindMatches(
                        ringbuffer,
                        i,
                        ringbuffer_mask,
                        MAX_TREE_COMP_LENGTH,
                        max_backward,
                        null,
                        null,
                        &dummy,
                    );
                }
            }
        }
    };
}
