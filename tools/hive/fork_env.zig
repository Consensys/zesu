/// Hive fork schedule: parse HIVE_* environment variables → SpecId.
const std = @import("std");
const primitives = @import("primitives");

const VERY_HIGH: u64 = std.math.maxInt(u64);

pub const ForkSchedule = struct {
    homestead: u64 = VERY_HIGH,
    dao: u64 = VERY_HIGH,
    tangerine: u64 = VERY_HIGH,
    spurious: u64 = VERY_HIGH,
    byzantium: u64 = VERY_HIGH,
    constantinople: u64 = VERY_HIGH,
    petersburg: u64 = VERY_HIGH,
    istanbul: u64 = VERY_HIGH,
    berlin: u64 = VERY_HIGH,
    london: u64 = VERY_HIGH,
    merge_block: u64 = VERY_HIGH,
    shanghai_ts: u64 = VERY_HIGH,
    cancun_ts: u64 = VERY_HIGH,
    prague_ts: u64 = VERY_HIGH,
    osaka_ts: u64 = VERY_HIGH,
    bpo1_ts: u64 = VERY_HIGH,
    bpo2_ts: u64 = VERY_HIGH,
    amsterdam_ts: u64 = VERY_HIGH,
    chain_id: u64 = 1,

    pub fn specAt(self: ForkSchedule, block: u64, ts: u64) primitives.SpecId {
        // Guard each check with `!= VERY_HIGH` so that an unconfigured fork
        // (sentinel = u64::MAX) is never matched even when ts = u64::MAX.
        if (self.amsterdam_ts != VERY_HIGH and ts >= self.amsterdam_ts) return .amsterdam;
        if (self.bpo2_ts != VERY_HIGH and ts >= self.bpo2_ts) return .bpo2;
        if (self.bpo1_ts != VERY_HIGH and ts >= self.bpo1_ts) return .bpo1;
        if (self.osaka_ts != VERY_HIGH and ts >= self.osaka_ts) return .osaka;
        if (self.prague_ts != VERY_HIGH and ts >= self.prague_ts) return .prague;
        if (self.cancun_ts != VERY_HIGH and ts >= self.cancun_ts) return .cancun;
        if (self.shanghai_ts != VERY_HIGH and ts >= self.shanghai_ts) return .shanghai;
        if (self.merge_block != VERY_HIGH and block >= self.merge_block) return .merge;
        if (self.london != VERY_HIGH and block >= self.london) return .london;
        if (self.berlin != VERY_HIGH and block >= self.berlin) return .berlin;
        if (self.istanbul != VERY_HIGH and block >= self.istanbul) return .istanbul;
        if (self.petersburg != VERY_HIGH and block >= self.petersburg) return .petersburg;
        if (self.constantinople != VERY_HIGH and block >= self.constantinople) return .constantinople;
        if (self.byzantium != VERY_HIGH and block >= self.byzantium) return .byzantium;
        if (self.spurious != VERY_HIGH and block >= self.spurious) return .spurious_dragon;
        if (self.tangerine != VERY_HIGH and block >= self.tangerine) return .tangerine;
        if (self.dao != VERY_HIGH and block >= self.dao) return .dao_fork;
        if (self.homestead != VERY_HIGH and block >= self.homestead) return .homestead;
        return .frontier;
    }
};

pub fn loadFromEnv(environ: *const std.process.Environ.Map) ForkSchedule {
    var s = ForkSchedule{};
    s.homestead = envU64(environ, "HIVE_FORK_HOMESTEAD") orelse VERY_HIGH;
    s.dao = envU64(environ, "HIVE_FORK_DAO_BLOCK") orelse VERY_HIGH;
    s.tangerine = envU64(environ, "HIVE_FORK_TANGERINE") orelse VERY_HIGH;
    s.spurious = envU64(environ, "HIVE_FORK_SPURIOUS") orelse VERY_HIGH;
    s.byzantium = envU64(environ, "HIVE_FORK_BYZANTIUM") orelse VERY_HIGH;
    s.constantinople = envU64(environ, "HIVE_FORK_CONSTANTINOPLE") orelse VERY_HIGH;
    s.petersburg = envU64(environ, "HIVE_FORK_PETERSBURG") orelse VERY_HIGH;
    s.istanbul = envU64(environ, "HIVE_FORK_ISTANBUL") orelse VERY_HIGH;
    s.berlin = envU64(environ, "HIVE_FORK_BERLIN") orelse VERY_HIGH;
    s.london = envU64(environ, "HIVE_FORK_LONDON") orelse VERY_HIGH;
    s.merge_block = envU64(environ, "HIVE_FORK_MERGE") orelse VERY_HIGH;
    s.shanghai_ts = envU64(environ, "HIVE_SHANGHAI_TIMESTAMP") orelse VERY_HIGH;
    s.cancun_ts = envU64(environ, "HIVE_CANCUN_TIMESTAMP") orelse VERY_HIGH;
    s.prague_ts = envU64(environ, "HIVE_PRAGUE_TIMESTAMP") orelse VERY_HIGH;
    s.osaka_ts = envU64(environ, "HIVE_OSAKA_TIMESTAMP") orelse VERY_HIGH;
    s.bpo1_ts = envU64(environ, "HIVE_BPO1_TIMESTAMP") orelse VERY_HIGH;
    s.bpo2_ts = envU64(environ, "HIVE_BPO2_TIMESTAMP") orelse VERY_HIGH;
    s.amsterdam_ts = envU64(environ, "HIVE_AMSTERDAM_TIMESTAMP") orelse VERY_HIGH;
    s.chain_id = envU64(environ, "HIVE_CHAIN_ID") orelse 1;
    return s;
}

fn envU64(environ: *const std.process.Environ.Map, name: []const u8) ?u64 {
    const val = environ.get(name) orelse return null;
    return std.fmt.parseInt(u64, val, 10) catch null;
}
