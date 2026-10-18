//! Reference Brotli streams for compliance testing.

/// length of the generated payload the stream was built from; 0 means the
/// whole payload.
pub const ReferenceStream = struct {
    name: []const u8,
    quality: u32,
    head: usize,
    original_len: usize,
    compressed: []const u8,
    sha256: []const u8,
};

const raw_streams = @embedFile("reference_streams.bin");

pub const reference_streams = [_]ReferenceStream{
    .{
        .name = "empty",
        .quality = 11,
        .head = 0,
        .original_len = 0,
        .compressed = raw_streams[0..2],
        .sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    },
    .{
        .name = "one_byte",
        .quality = 9,
        .head = 0,
        .original_len = 1,
        .compressed = raw_streams[2..8],
        .sha256 = "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
    },
    .{
        .name = "tiny",
        .quality = 5,
        .head = 0,
        .original_len = 12,
        .compressed = raw_streams[8..25],
        .sha256 = "46c0941f01bc4aba512b213ac665132ebc108b566ed6203a145d9016df7d1cc6",
    },
    .{
        .name = "text_en",
        .quality = 9,
        .head = 8000,
        .original_len = 8000,
        .compressed = raw_streams[25..1983],
        .sha256 = "9fd0a6a12c6d4a6834140cdf88493569c8fedca573b0cd9ec0102adccd2ff11e",
    },
    .{
        .name = "text_en",
        .quality = 1,
        .head = 8000,
        .original_len = 8000,
        .compressed = raw_streams[1983..4241],
        .sha256 = "9fd0a6a12c6d4a6834140cdf88493569c8fedca573b0cd9ec0102adccd2ff11e",
    },
    .{
        .name = "text_utf8",
        .quality = 11,
        .head = 8000,
        .original_len = 8000,
        .compressed = raw_streams[4241..4279],
        .sha256 = "f9cb3e4e7e165accd8c291a042569458f6c13968297ccf604c9e2e64368352d3",
    },
    .{
        .name = "rep_periodic",
        .quality = 5,
        .head = 40000,
        .original_len = 40000,
        .compressed = raw_streams[4279..4295],
        .sha256 = "0c78e5c9d34b7e2fba080cd1e507aa60d009f677e4a202a93bd901e1d76de6f1",
    },
    .{
        .name = "rle",
        .quality = 11,
        .head = 8000,
        .original_len = 8000,
        .compressed = raw_streams[4295..4308],
        .sha256 = "40bd4474a301f59ef58c4e7d5c128e09154251d9f65a3816b728a9fe8987a0f7",
    },
    .{
        .name = "random",
        .quality = 6,
        .head = 4096,
        .original_len = 4096,
        .compressed = raw_streams[4308..7818],
        .sha256 = "d9b7ff65e13cb6f8a5cad1ecd973fbeb15f5f112c9845b7c996e0e6cdf606854",
    },
    .{
        .name = "nested_json",
        .quality = 4,
        .head = 8000,
        .original_len = 8000,
        .compressed = raw_streams[7818..9001],
        .sha256 = "1147aeef1ff1cfac003d9c55203c43093284da93d813ba688c1a407754873964",
    },
    .{
        .name = "dict_friendly",
        .quality = 11,
        .head = 16000,
        .original_len = 16000,
        .compressed = raw_streams[9001..9056],
        .sha256 = "da8966801bd46b1db39f5df8e9c09c88a1490d892e538fcb07cfac87b1139cb7",
    },
    .{
        .name = "blocky",
        .quality = 2,
        .head = 40000,
        .original_len = 40000,
        .compressed = raw_streams[9056..9121],
        .sha256 = "c81478bd5de64995cbf67afac5be3256b28df1e7523a32d08e02f0aba24e9940",
    },
    .{
        .name = "records",
        .quality = 10,
        .head = 6000,
        .original_len = 6000,
        .compressed = raw_streams[9121..11649],
        .sha256 = "215a56a4bf24746f87ba7c5aee9df0faf683186217bf2c1848a1fbf52fb3847f",
    },
    .{
        .name = "zeros_ukkonooa",
        .quality = 11,
        .head = 0,
        .original_len = 262152,
        .compressed = raw_streams[11649..11676],
        .sha256 = "c9307551120126e3367a070a57b42c48019cf4cc0d52fb8710c2a1394591fe25",
    },
};

// Aliases for individual stream access by index or name
pub const ref_0_compressed: []const u8 = reference_streams[0].compressed;
pub const ref_0_sha256: []const u8 = reference_streams[0].sha256;
pub const ref_1_compressed: []const u8 = reference_streams[1].compressed;
pub const ref_1_sha256: []const u8 = reference_streams[1].sha256;
pub const ref_2_compressed: []const u8 = reference_streams[2].compressed;
pub const ref_2_sha256: []const u8 = reference_streams[2].sha256;
pub const ref_3_compressed: []const u8 = reference_streams[3].compressed;
pub const ref_3_sha256: []const u8 = reference_streams[3].sha256;
pub const ref_4_compressed: []const u8 = reference_streams[4].compressed;
pub const ref_4_sha256: []const u8 = reference_streams[4].sha256;
pub const ref_5_compressed: []const u8 = reference_streams[5].compressed;
pub const ref_5_sha256: []const u8 = reference_streams[5].sha256;
pub const ref_6_compressed: []const u8 = reference_streams[6].compressed;
pub const ref_6_sha256: []const u8 = reference_streams[6].sha256;
pub const ref_7_compressed: []const u8 = reference_streams[7].compressed;
pub const ref_7_sha256: []const u8 = reference_streams[7].sha256;
pub const ref_8_compressed: []const u8 = reference_streams[8].compressed;
pub const ref_8_sha256: []const u8 = reference_streams[8].sha256;
pub const ref_9_compressed: []const u8 = reference_streams[9].compressed;
pub const ref_9_sha256: []const u8 = reference_streams[9].sha256;
pub const ref_10_compressed: []const u8 = reference_streams[10].compressed;
pub const ref_10_sha256: []const u8 = reference_streams[10].sha256;
pub const ref_11_compressed: []const u8 = reference_streams[11].compressed;
pub const ref_11_sha256: []const u8 = reference_streams[11].sha256;
pub const ref_12_compressed: []const u8 = reference_streams[12].compressed;
pub const ref_12_sha256: []const u8 = reference_streams[12].sha256;
pub const ref_13_compressed: []const u8 = reference_streams[13].compressed;
pub const ref_13_sha256: []const u8 = reference_streams[13].sha256;
