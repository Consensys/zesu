# Migrating zevm-stateless-zisk to zesu

zesu merges the former `zevm` (EVM) and `zevm-stateless` (stateless executor) repos into one.
This document describes every change needed to migrate a Zisk zkVM guest that previously
depended on both sibling repos.

---

## 1. `build.zig.zon` — two deps → one

```diff
 .dependencies = .{
-    .zevm = .{ .path = "../zevm" },
-    .zevm_stateless = .{ .path = "../zevm-stateless" },
+    .zesu = .{ .path = "../zesu" },
 },
```

---

## 2. `build.zig` changes

### 2a. Dep handles

```diff
-const zevm_dep = b.dependency("zevm", .{ .target = target, .optimize = optimize });
-const zs_dep   = b.dependency("zevm_stateless", .{});
+const zesu_dep  = b.dependency("zesu", .{ .target = target, .optimize = optimize });
```

### 2b. EVM modules — same names, one dep

```diff
-const primitives   = zevm_dep.module("primitives");
-const bytecode     = zevm_dep.module("bytecode");
-const state        = zevm_dep.module("state");
-const database     = zevm_dep.module("database");
-const context      = zevm_dep.module("context");
-const interpreter  = zevm_dep.module("interpreter");
-const precompile   = zevm_dep.module("precompile");
-const handler      = zevm_dep.module("handler");
-const inspector    = zevm_dep.module("inspector");
+const primitives   = zesu_dep.module("primitives");
+const bytecode     = zesu_dep.module("bytecode");
+const state        = zesu_dep.module("state");
+const database     = zesu_dep.module("database");
+const context      = zesu_dep.module("context");
+const interpreter  = zesu_dep.module("interpreter");
+const precompile   = zesu_dep.module("precompile");
+const handler      = zesu_dep.module("handler");
+const inspector    = zesu_dep.module("inspector");
```

`precompile_types` is also exposed as a named module (needed for `precompile_overrides.zig`):

```diff
-const precompile_types = zevm_dep.module("precompile_types");
+const precompile_types = zesu_dep.module("precompile_types");
```

### 2c. Stateless modules — use zesu paths under `src/stateless/`

Old code accessed zevm-stateless source via `zs_dep.path("src/...")`. In zesu the same files
live under `src/stateless/`. You can either use `zesu_dep.module()` for the top-level named
modules, or `zesu_dep.path()` to re-create modules with freestanding-safe wiring. The table
below covers both cases.

| Old `zs_dep.path(...)` | New `zesu_dep.path(...)` | zesu named module |
|---|---|---|
| `src/input.zig` | `src/stateless/input.zig` | `zesu_dep.module("input")` |
| `src/output.zig` | `src/stateless/output.zig` | `zesu_dep.module("output")` |
| `src/hardfork.zig` | `src/stateless/hardfork.zig` | `zesu_dep.module("hardfork")` |
| `src/rlp_decode.zig` | `src/stateless/rlp_decode.zig` | `zesu_dep.module("rlp_decode")` |
| `src/mpt/main.zig` | `src/stateless/mpt/main.zig` | `zesu_dep.module("mpt")` |
| `src/mpt/builder.zig` | `src/stateless/mpt/builder.zig` | *(anonymous, path only)* |
| `src/mpt/nibbles.zig` | `src/stateless/mpt/nibbles.zig` | *(anonymous, path only)* |
| `src/db/main.zig` | `src/stateless/db/main.zig` | `zesu_dep.module("db")` |
| `src/executor/main.zig` | `src/stateless/executor/main.zig` | `zesu_dep.module("executor")` |
| `src/executor/types.zig` | `src/stateless/executor/types.zig` | *(anonymous, path only)* |
| `src/executor/rlp_encode.zig` | `src/stateless/executor/rlp_encode.zig` | *(via executor re-export)* |
| `src/executor/transition.zig` | `src/stateless/executor/transition.zig` | *(via executor re-export)* |
| `src/executor/output.zig` | `src/stateless/executor/output.zig` | *(via executor re-export)* |
| `src/executor/bal.zig` | `src/stateless/executor/bal.zig` | *(via executor re-export)* |
| `src/executor/block_validation.zig` | `src/stateless/executor/block_validation.zig` | *(internal)* |
| `src/executor/tx_decode.zig` | `src/stateless/executor/tx_decode.zig` | *(via executor re-export)* |

**Important**: `transition.zig`, `output.zig`, `bal.zig`, `rlp_encode.zig`, `block_validation.zig`,
`executor_allocator.zig` now use relative `@import("./X.zig")` for intra-executor dependencies.
They no longer need those helper modules wired as named imports — only the external dependencies
below remain.

When re-creating the executor sub-modules from path (needed to inject the Zisk bump allocator),
the minimal named imports for each file are:

| File | Required named imports |
|---|---|
| `executor/types.zig` | *(none — std only)* |
| `executor/transition.zig` | `executor_types`, `primitives`, `state`, `bytecode`, `database`, `context`, `handler`, `precompile`, `accelerators` |
| `executor/output.zig` | `executor_types`, `mpt_builder`, `mpt` |
| `executor/bal.zig` | `primitives`, `mpt` |
| `executor/tx_decode.zig` | `executor_types`, `input`, `rlp_decode` |
| `executor/main.zig` | `executor_types`, `primitives`, `input`, `output`, `mpt`, `mpt_builder`, `rlp_decode`, `hardfork`, `db`, `context` |

Note: `executor_rlp_encode`, `executor_allocator`, `executor_bal`, `executor_block_validation`
are no longer passed as named imports — they are pulled in automatically as relative imports
from within the executor compilation unit.

### 2d. Crypto injection — unified `accel_impl`

**This is the most significant architectural change.**

Previously there were two separate injection points:
- `mpt` had `@import("zkvm_accelerators")` for keccak256
- `executor/transition.zig` had `@import("secp256k1_wrapper")` for ecrecover

In zesu both are replaced by a single `accel_impl` injection into the `accelerators` module:

```diff
-// Old: separate zkvm_accelerators for mpt
-const zkvm_accelerators_mod = b.createModule(.{
-    .root_source_file = zs_dep.path("src/zkvm/zkvm_accelerators.zig"), ...
-});
-mpt_mod.addImport("zkvm_accelerators", zkvm_accelerators_mod);
-
-// Old: secp256k1_wrapper for transition
-executor_transition_mod.addImport("secp256k1_wrapper", secp256k1_mod);

+// New: single accel_impl for everything (keccak, ecrecover, BN254, ...)
+const zisk_accel_impl_mod = b.addModule("zisk_accel_impl", .{
+    .root_source_file = b.path("src/zisk/accel_impl.zig"),
+    .target = target,
+    .optimize = optimize,
+});
+zisk_accel_impl_mod.addImport("zisk", zisk_mod);
+
+const accelerators_mod = zesu_dep.module("accelerators");
+accelerators_mod.addImport("accel_impl", zisk_accel_impl_mod);
```

The `accel_impl` module must implement every `pub fn` in
`src/crypto/accelerators.zig`:

```
keccak256, secp256k1_verify, ecrecover, sha256, ripemd160, modexp,
bn254_g1_add, bn254_g1_mul, bn254_pairing,
blake2f, kzg_point_eval,
bls12_g1_add, bls12_g1_msm, bls12_g2_add, bls12_g2_msm,
bls12_pairing, bls12_map_fp_to_g1, bls12_map_fp2_to_g2,
secp256r1_verify
```

For operations without a Zisk circuit (most BLS12-381, KZG), stub with `OutOfGas` or
return false. For `keccak256` use the Zisk keccak CSR; for `ecrecover` use the secp256k1
CSR (previously in `secp256k1_wrapper`).

The `precompile_implementations` override is unchanged:

```zig
// Still works — precompile module still has this injection point
precompile.addImport("precompile_implementations", zisk_overrides_module);
```

`precompile_overrides.zig` can now use the accelerators module directly for BN254
(it already calls the Zisk CSR circuits) — or keep calling eip196.zig as before.

### 2e. zkvm_accelerators.zig removal

The file `src/zkvm/zkvm_accelerators.zig` from zevm-stateless is no longer needed.
Its keccak256 declaration moves into the `accel_impl` module. Remove the module
definition and its import into mpt:

```diff
-const zkvm_accelerators_mod = b.createModule(.{ ... });
-mpt_mod.addImport("zkvm_accelerators", zkvm_accelerators_mod);
```

### 2f. Simplified executor module wiring (preferred)

If you can use `zesu_dep.module("executor")` directly (injecting overrides rather than
re-creating from source), the entire executor sub-module section collapses to:

```zig
const executor_mod = zesu_dep.module("executor");
// (No individual executor_X modules needed)
```

This works because zesu's executor module already has all internal deps wired. You
only need to override:
- `zevm_allocator` in all EVM modules (Zisk bump allocator)
- `accel_impl` in the accelerators module (Zisk CSR implementations)
- `precompile_implementations` in precompile (Zisk overrides, if still needed)

---

## 3. Source changes in zevm-stateless-zisk

### 3a. `src/deserialize.zig` — path update only

If it imports from zevm-stateless source via relative paths, update to the `src/stateless/`
layout. No logic changes needed.

### 3b. `src/zisk/accel_impl.zig` — new file (replaces two separate injection points)

Consolidate the old `zkvm_accelerators_zisk.zig` (keccak) and `secp256k1.zig` (ecrecover)
into a single `accel_impl.zig` that implements the full `accelerators.zig` interface.

Scaffold (all ops not yet wired should return `OutOfGas` / false):

```zig
// src/zisk/accel_impl.zig
const zisk = @import("zisk");

pub fn keccak256(data: []const u8, output: *[32]u8) void {
    zisk.keccak256(data, output);
}

pub fn ecrecover(msg: *const [32]u8, sig: *const [64]u8, recid: u8, output: *[64]u8) bool {
    return zisk.secp256k1Recover(msg, sig, recid, output);
}

pub fn bn254_g1_add(p1: *const [64]u8, p2: *const [64]u8, result: *[64]u8) bool {
    return zisk.bn254Add(p1, p2, result);
}
// ... etc.
```

### 3c. `src/zisk/precompile_overrides.zig` — import path for precompile_types

```diff
-const precompile_types = @import("precompile_types"); // unchanged — still works
```

No change required; `precompile_types` is still wired as a named import from build.zig.

---

## 4. Named modules exposed by zesu

These are available via `zesu_dep.module("name")`:

| Module name | Source |
|---|---|
| `primitives` | `src/evm/primitives/main.zig` |
| `bytecode` | `src/evm/bytecode/main.zig` |
| `state` | `src/evm/state/main.zig` |
| `database` | `src/evm/database/main.zig` |
| `context` | `src/evm/context/main.zig` |
| `precompile` | `src/evm/precompile/main.zig` |
| `precompile_types` | `src/evm/precompile/types.zig` |
| `interpreter` | `src/evm/interpreter/main.zig` |
| `handler` | `src/evm/handler/main.zig` |
| `inspector` | `src/evm/inspector/main.zig` |
| `zevm_allocator` | `src/evm/allocator.zig` |
| `accelerators` | `src/crypto/accelerators.zig` |
| `input` | `src/stateless/input.zig` |
| `output` | `src/stateless/output.zig` |
| `hardfork` | `src/stateless/hardfork.zig` |
| `rlp_decode` | `src/stateless/rlp_decode.zig` |
| `mpt` | `src/stateless/mpt/main.zig` |
| `db` | `src/stateless/db/main.zig` |
| `executor` | `src/stateless/executor/main.zig` |

Injection points (override by calling `.addImport()` on the returned module):

| Module | Injection point | Purpose |
|---|---|---|
| `accelerators` | `accel_impl` | All crypto ops (keccak, secp256k1, BN254, BLS, …) |
| `precompile` | `precompile_implementations` | Per-precompile function overrides |
| all EVM modules | `zevm_allocator` | Heap allocator (override for bump/arena) |
