const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Platform detection ────────────────────────────────────────────────────
    const is_linux = b.graph.host.result.os.tag == .linux;
    const crypto_prefix: []const u8 = if (is_linux) "/usr/local" else "/opt/homebrew";
    const crypto_include = b.fmt("{s}/include", .{crypto_prefix});
    const libblst_path = b.fmt("{s}/lib/libblst.a", .{crypto_prefix});
    const libmcl_path = b.fmt("{s}/lib/libmcl.a", .{crypto_prefix});

    // ── Crypto library options ────────────────────────────────────────────────
    const enable_secp256k1 = b.option(bool, "secp256k1", "Enable libsecp256k1 (ECRECOVER)") orelse true;
    const enable_openssl = b.option(bool, "openssl", "Enable OpenSSL (P256Verify)") orelse true;
    const enable_blst = b.option(bool, "blst", "Enable blst (BLS12-381 and KZG)") orelse true;
    const enable_mcl = b.option(bool, "mcl", "Enable mcl (BN254)") orelse true;

    const lib_options = b.addOptions();
    lib_options.addOption(bool, "enable_secp256k1", enable_secp256k1);
    lib_options.addOption(bool, "enable_openssl", enable_openssl);
    lib_options.addOption(bool, "enable_blst", enable_blst);
    lib_options.addOption(bool, "enable_mcl", enable_mcl);
    const build_options_module = lib_options.createModule();

    // ── Crypto linking helper ─────────────────────────────────────────────────
    //
    // mcl: on Linux, the .a archive embeds libstdc++ references that Zig/LLD
    // cannot resolve reliably against the system libstdc++. Use the .so instead
    // (runtime resolution by the OS dynamic linker). On macOS, Homebrew mcl is
    // compiled with clang/libc++ so static linking with linkLibCpp() works.
    const addCryptoLibraries = struct {
        fn add(
            step: *std.Build.Step.Compile,
            inc: []const u8,
            blst: []const u8,
            mcl: []const u8,
            linux: bool,
        ) void {
            step.addIncludePath(.{ .cwd_relative = inc });
            step.linkSystemLibrary("secp256k1");
            step.linkSystemLibrary("ssl");
            step.linkSystemLibrary("crypto");
            step.linkSystemLibrary("c");
            step.linkSystemLibrary("m");
            step.addObjectFile(.{ .cwd_relative = blst });
            if (linux) {
                step.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
                step.linkSystemLibrary("mcl");
            } else {
                step.addObjectFile(.{ .cwd_relative = mcl });
                step.linkLibCpp();
            }
        }
    }.add;

    // ── Run step helper ───────────────────────────────────────────────────────
    const addRunStep = struct {
        fn add(
            bb: *std.Build,
            name: []const u8,
            desc: []const u8,
            exe: *std.Build.Step.Compile,
            fixed_args: []const []const u8,
        ) void {
            const step = bb.step(name, desc);
            const cmd = bb.addRunArtifact(exe);
            cmd.step.dependOn(bb.getInstallStep());
            cmd.addArgs(fixed_args);
            if (bb.args) |args| cmd.addArgs(args);
            step.dependOn(&cmd.step);
        }
    }.add;

    // ── Foundation modules ────────────────────────────────────────────────────

    // Default EVM allocator (std.heap.c_allocator). Override for zkVM targets.
    const zevm_allocator_module = b.addModule("zevm_allocator", .{
        .root_source_file = b.path("src/evm/allocator.zig"),
        .target = target,
        .optimize = optimize,
    });

    const primitives_module = b.addModule("primitives", .{
        .root_source_file = b.path("src/evm/primitives/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Crypto accelerator ────────────────────────────────────────────────────
    //
    // Single injection point for all crypto operations. Override accel_impl in
    // the accelerators module to swap the backend for a zkVM target:
    //   accelerators_module.addImport("accel_impl", your_zisk_module)
    //
    // Default: src/crypto/default.zig (libsecp256k1 / OpenSSL / blst / mcl).
    const accel_impl_module = b.createModule(.{
        .root_source_file = b.path("src/crypto/default.zig"),
        .target = target,
        .optimize = optimize,
    });
    accel_impl_module.addImport("build_options", build_options_module);
    accel_impl_module.addImport("zevm_allocator", zevm_allocator_module);

    const accelerators_module = b.addModule("accelerators", .{
        .root_source_file = b.path("src/crypto/accelerators.zig"),
        .target = target,
        .optimize = optimize,
    });
    accelerators_module.addImport("accel_impl", accel_impl_module);

    // Core precompile types — standalone (no external deps). Shared by precompile
    // and precompile_implementations; a separate module avoids the file-in-two-modules
    // constraint since both are roots of different compilation units.
    // Exposed as a named module so zkVM consumers can import it for custom
    // precompile_implementations (e.g. dep.module("precompile_types")).
    const precompile_types_module = b.addModule("precompile_types", .{
        .root_source_file = b.path("src/evm/precompile/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Default C-backed precompile implementations. Override for zkVM targets:
    //   precompile_module.addImport("precompile_implementations", your_module)
    const precompile_implementations_module = b.createModule(.{
        .root_source_file = b.path("src/evm/precompile/default_impls.zig"),
        .target = target,
        .optimize = optimize,
    });
    precompile_implementations_module.addImport("precompile_types", precompile_types_module);
    precompile_implementations_module.addImport("accelerators", accelerators_module);
    precompile_implementations_module.addImport("zevm_allocator", zevm_allocator_module);

    // ── EVM modules ──────────────────────────────────────────────────────────

    const bytecode_module = b.addModule("bytecode", .{
        .root_source_file = b.path("src/evm/bytecode/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bytecode_module.addImport("primitives", primitives_module);
    bytecode_module.addImport("zevm_allocator", zevm_allocator_module);

    const state_module = b.addModule("state", .{
        .root_source_file = b.path("src/evm/state/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    state_module.addImport("primitives", primitives_module);
    state_module.addImport("bytecode", bytecode_module);
    state_module.addImport("zevm_allocator", zevm_allocator_module);

    const database_module = b.addModule("database", .{
        .root_source_file = b.path("src/evm/database/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    database_module.addImport("primitives", primitives_module);
    database_module.addImport("state", state_module);
    database_module.addImport("bytecode", bytecode_module);

    const context_module = b.addModule("context", .{
        .root_source_file = b.path("src/evm/context/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    context_module.addImport("primitives", primitives_module);
    context_module.addImport("bytecode", bytecode_module);
    context_module.addImport("state", state_module);
    context_module.addImport("database", database_module);
    context_module.addImport("zevm_allocator", zevm_allocator_module);

    const precompile_module = b.addModule("precompile", .{
        .root_source_file = b.path("src/evm/precompile/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    precompile_module.addImport("primitives", primitives_module);
    precompile_module.addImport("zevm_allocator", zevm_allocator_module);
    precompile_module.addImport("precompile_types", precompile_types_module);
    precompile_module.addImport("precompile_implementations", precompile_implementations_module);
    precompile_module.addImport("accelerators", accelerators_module);

    const interpreter_module = b.addModule("interpreter", .{
        .root_source_file = b.path("src/evm/interpreter/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    interpreter_module.addImport("primitives", primitives_module);
    interpreter_module.addImport("bytecode", bytecode_module);
    interpreter_module.addImport("context", context_module);
    interpreter_module.addImport("database", database_module);
    interpreter_module.addImport("state", state_module);
    interpreter_module.addImport("precompile", precompile_module);
    interpreter_module.addImport("zevm_allocator", zevm_allocator_module);
    interpreter_module.addImport("accelerators", accelerators_module);

    const handler_module = b.addModule("handler", .{
        .root_source_file = b.path("src/evm/handler/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    handler_module.addImport("primitives", primitives_module);
    handler_module.addImport("bytecode", bytecode_module);
    handler_module.addImport("state", state_module);
    handler_module.addImport("database", database_module);
    handler_module.addImport("interpreter", interpreter_module);
    handler_module.addImport("context", context_module);
    handler_module.addImport("precompile", precompile_module);
    handler_module.addImport("zevm_allocator", zevm_allocator_module);

    const inspector_module = b.addModule("inspector", .{
        .root_source_file = b.path("src/evm/inspector/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    inspector_module.addImport("primitives", primitives_module);
    inspector_module.addImport("context", context_module);
    inspector_module.addImport("interpreter", interpreter_module);
    inspector_module.addImport("database", database_module);

    // ── Stateless base modules ────────────────────────────────────────────────

    const input_module = b.addModule("input", .{
        .root_source_file = b.path("src/stateless/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_module.addImport("primitives", primitives_module);

    const output_module = b.addModule("output", .{
        .root_source_file = b.path("src/stateless/output.zig"),
        .target = target,
        .optimize = optimize,
    });
    output_module.addImport("primitives", primitives_module);

    const hardfork_module = b.addModule("hardfork", .{
        .root_source_file = b.path("src/stateless/hardfork.zig"),
        .target = target,
        .optimize = optimize,
    });
    hardfork_module.addImport("primitives", primitives_module);

    // rlp_decode needs mpt (created below) — wire "mpt" after mpt_module is created.
    const rlp_decode_module = b.addModule("rlp_decode", .{
        .root_source_file = b.path("src/stateless/rlp_decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    rlp_decode_module.addImport("primitives", primitives_module);
    rlp_decode_module.addImport("input", input_module);

    // ── MPT modules ──────────────────────────────────────────────────────────
    // mpt_nibbles: nibble/path encoding — shared by mpt and mpt_builder.
    // Must be a separate module (both are roots of different modules; a file
    // can only belong to one module, so nibbles.zig can't be a relative import
    // in both mpt and mpt_builder simultaneously).
    const mpt_nibbles_module = b.createModule(.{
        .root_source_file = b.path("src/stateless/mpt/nibbles.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mpt_module = b.addModule("mpt", .{
        .root_source_file = b.path("src/stateless/mpt/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mpt_module.addImport("primitives", primitives_module);
    mpt_module.addImport("input", input_module);
    mpt_module.addImport("accelerators", accelerators_module);
    mpt_module.addImport("mpt_nibbles", mpt_nibbles_module);

    // Wire deferred mpt dependency into rlp_decode.
    rlp_decode_module.addImport("mpt", mpt_module);

    // mpt_builder: standalone trie builder (shares nibble encoding with mpt).
    const mpt_builder_module = b.createModule(.{
        .root_source_file = b.path("src/stateless/mpt/builder.zig"),
        .target = target,
        .optimize = optimize,
    });
    mpt_builder_module.addImport("mpt_nibbles", mpt_nibbles_module);

    // executor_types: canonical EVM/block type definitions — standalone (no external deps).
    // Shared between executor and db to avoid a circular executor↔db dependency.
    const executor_types_module = b.createModule(.{
        .root_source_file = b.path("src/stateless/executor/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── WitnessDatabase ───────────────────────────────────────────────────────

    const db_module = b.addModule("db", .{
        .root_source_file = b.path("src/stateless/db/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    db_module.addImport("primitives", primitives_module);
    db_module.addImport("state", state_module);
    db_module.addImport("bytecode", bytecode_module);
    db_module.addImport("mpt", mpt_module);
    db_module.addImport("executor_types", executor_types_module);

    // ── Executor ─────────────────────────────────────────────────────────────
    //
    // executor/ files use relative @import("./X.zig") for intra-package deps.
    // External deps are all wired here. Sub-modules are re-exported as pub
    // constants so tools can reach them via @import("executor").executor_types etc.

    const executor_module = b.addModule("executor", .{
        .root_source_file = b.path("src/stateless/executor/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    executor_module.addImport("executor_types", executor_types_module);
    executor_module.addImport("primitives", primitives_module);
    executor_module.addImport("input", input_module);
    executor_module.addImport("output", output_module);
    executor_module.addImport("mpt", mpt_module);
    executor_module.addImport("mpt_builder", mpt_builder_module);
    executor_module.addImport("rlp_decode", rlp_decode_module);
    executor_module.addImport("hardfork", hardfork_module);
    executor_module.addImport("db", db_module);
    executor_module.addImport("context", context_module);
    executor_module.addImport("state", state_module);
    executor_module.addImport("bytecode", bytecode_module);
    executor_module.addImport("database", database_module);
    executor_module.addImport("handler", handler_module);
    executor_module.addImport("precompile", precompile_module);
    executor_module.addImport("accelerators", accelerators_module);

    // ── I/O and zkVM modules ──────────────────────────────────────────────────
    //
    // Default I/O: reads stdin, writes stdout (native builds).
    // Override for zkVM: module.addImport("zkvm_io", your_io_module)

    const io_impl_module = b.createModule(.{
        .root_source_file = b.path("src/io/default.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zkvm_io_module = b.createModule(.{
        .root_source_file = b.path("src/io/interface.zig"),
        .target = target,
        .optimize = optimize,
    });
    zkvm_io_module.addImport("io_impl", io_impl_module);

    // Default main allocator for the stateless binary (std.heap.c_allocator).
    // Override for zkVM builds via addImport("main_allocator", your_module).
    const main_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/stateless/zkvm/allocator.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // ── SSZ helper modules ────────────────────────────────────────────────────

    const ssz_decode_module = b.createModule(.{
        .root_source_file = b.path("src/stateless/stateless/ssz.zig"),
        .target = target,
        .optimize = optimize,
    });
    ssz_decode_module.addImport("input", input_module);
    ssz_decode_module.addImport("rlp_decode", rlp_decode_module);

    const ssz_output_module = b.createModule(.{
        .root_source_file = b.path("src/stateless/stateless/ssz_output.zig"),
        .target = target,
        .optimize = optimize,
    });
    ssz_output_module.addImport("input", input_module);

    // ── zevm_stateless binary ─────────────────────────────────────────────────

    const stateless_exe = b.addExecutable(.{
        .name = "zevm_stateless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stateless/stateless/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    stateless_exe.root_module.addImport("rlp_decode", rlp_decode_module);
    stateless_exe.root_module.addImport("input", input_module);
    stateless_exe.root_module.addImport("mpt", mpt_module);
    stateless_exe.root_module.addImport("executor", executor_module);
    stateless_exe.root_module.addImport("main_allocator", main_allocator_module);
    stateless_exe.root_module.addImport("zkvm_io", zkvm_io_module);
    addCryptoLibraries(stateless_exe, crypto_include, libblst_path, libmcl_path, is_linux);
    b.installArtifact(stateless_exe);
    addRunStep(b, "run", "Run the zevm_stateless app", stateless_exe, &.{});

    // ── t8n: Ethereum State Transition Tool ───────────────────────────────────

    // t8n_input: JSON input parser — also used by spec-test-runner.
    // tools/t8n/input.zig uses @import("executor").executor_types.
    const t8n_input_module = b.createModule(.{
        .root_source_file = b.path("tools/t8n/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    t8n_input_module.addImport("executor", executor_module);

    const t8n_exe = b.addExecutable(.{
        .name = "t8n",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/t8n/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    t8n_exe.root_module.addImport("executor", executor_module);
    t8n_exe.root_module.addImport("hardfork", hardfork_module);
    addCryptoLibraries(t8n_exe, crypto_include, libblst_path, libmcl_path, is_linux);
    b.installArtifact(t8n_exe);
    addRunStep(b, "t8n", "Run the t8n state transition tool", t8n_exe, &.{});

    // ── spec-test-runner ──────────────────────────────────────────────────────

    const spec_test_exe = b.addExecutable(.{
        .name = "spec-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/spec_test/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    spec_test_exe.root_module.addImport("t8n_input", t8n_input_module);
    spec_test_exe.root_module.addImport("executor", executor_module);
    spec_test_exe.root_module.addImport("hardfork", hardfork_module);
    addCryptoLibraries(spec_test_exe, crypto_include, libblst_path, libmcl_path, is_linux);
    b.installArtifact(spec_test_exe);
    addRunStep(b, "state-tests", "Run execution-spec-tests state fixtures", spec_test_exe, &.{});

    // ── blockchain-test-runner ────────────────────────────────────────────────

    // blockchain_runner: separate module so tools/blockchain_test/runner.zig
    // gets its own named-import scope (json.zig and output.zig are relative within it).
    const blockchain_runner_module = b.createModule(.{
        .root_source_file = b.path("tools/blockchain_test/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    blockchain_runner_module.addImport("primitives", primitives_module);
    blockchain_runner_module.addImport("executor", executor_module);
    blockchain_runner_module.addImport("mpt", mpt_module);
    blockchain_runner_module.addImport("hardfork", hardfork_module);

    const bc_test_exe = b.addExecutable(.{
        .name = "blockchain-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/blockchain_test/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bc_test_exe.root_module.addImport("runner", blockchain_runner_module);
    addCryptoLibraries(bc_test_exe, crypto_include, libblst_path, libmcl_path, is_linux);
    b.installArtifact(bc_test_exe);
    addRunStep(b, "blockchain-tests", "Run Ethereum blockchain test fixtures", bc_test_exe, &.{});

    // ── zkevm-blockchain-test-runner ──────────────────────────────────────────

    const zkevm_test_exe = b.addExecutable(.{
        .name = "zkevm-blockchain-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zkevm_test/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zkevm_test_exe.root_module.addImport("ssz_decode", ssz_decode_module);
    zkevm_test_exe.root_module.addImport("ssz_output", ssz_output_module);
    zkevm_test_exe.root_module.addImport("executor", executor_module);
    addCryptoLibraries(zkevm_test_exe, crypto_include, libblst_path, libmcl_path, is_linux);
    b.installArtifact(zkevm_test_exe);
    addRunStep(b, "zkevm-tests", "Run zkevm blockchain test fixtures", zkevm_test_exe,
        &.{ "--fixtures", "spec-tests/fixtures/zkevm/blockchain_tests" });

    // ── hive-rlp: Hive consume-rlp execution client ───────────────────────────
    //
    // Reads /genesis.json and /blocks/*.rlp at startup, executes the chain,
    // and serves eth_getBlockByNumber on :8545 for Hive validation.

    const hive_exe = b.addExecutable(.{
        .name = "hive-rlp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/hive/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hive_exe.root_module.addImport("primitives", primitives_module);
    hive_exe.root_module.addImport("executor", executor_module);
    hive_exe.root_module.addImport("hardfork", hardfork_module);
    hive_exe.root_module.addImport("mpt", mpt_module);
    hive_exe.root_module.addImport("mpt_builder", mpt_builder_module);
    addCryptoLibraries(hive_exe, crypto_include, libblst_path, libmcl_path, is_linux);
    b.installArtifact(hive_exe);
    b.step("hive-rlp", "Build and install the Hive consume-rlp client").dependOn(b.getInstallStep());

    // ── Tests ─────────────────────────────────────────────────────────────────

    const test_step = b.step("test", "Run all unit tests");

    // Reuse existing modules — no need to re-declare imports.
    for ([_]struct { m: *std.Build.Module, name: []const u8 }{
        .{ .m = precompile_module, .name = "precompile" },
        .{ .m = interpreter_module, .name = "interpreter" },
        .{ .m = handler_module, .name = "handler" },
    }) |t| {
        const tst = b.addTest(.{ .root_module = t.m });
        _ = t.name;
        addCryptoLibraries(tst, crypto_include, libblst_path, libmcl_path, is_linux);
        test_step.dependOn(&b.addRunArtifact(tst).step);
    }

    // MPT integration tests
    {
        const m = b.createModule(.{
            .root_source_file = b.path("src/stateless/mpt/test.zig"),
            .target = target,
            .optimize = optimize,
        });
        m.addImport("primitives", primitives_module);
        m.addImport("mpt", mpt_module);
        m.addImport("input", input_module);
        const tst = b.addTest(.{ .root_module = m });
        addCryptoLibraries(tst, crypto_include, libblst_path, libmcl_path, is_linux);
        test_step.dependOn(&b.addRunArtifact(tst).step);
    }

    // WitnessDatabase integration tests
    {
        const m = b.createModule(.{
            .root_source_file = b.path("src/stateless/db/test.zig"),
            .target = target,
            .optimize = optimize,
        });
        m.addImport("primitives", primitives_module);
        m.addImport("state", state_module);
        m.addImport("bytecode", bytecode_module);
        m.addImport("mpt", mpt_module);
        m.addImport("input", input_module);
        m.addImport("db", db_module);
        const tst = b.addTest(.{ .root_module = m });
        addCryptoLibraries(tst, crypto_include, libblst_path, libmcl_path, is_linux);
        test_step.dependOn(&b.addRunArtifact(tst).step);
    }

    // ── Fixture fetch steps ───────────────────────────────────────────────────

    const fetch_fixtures_step = b.step("fetch-fixtures", "Download execution-spec-tests bal@v5.5.1 fixtures");
    fetch_fixtures_step.dependOn(&b.addSystemCommand(&.{
        "sh", "-c",
        "rm -rf spec-tests/fixtures && " ++
            "mkdir -p spec-tests/fixtures && " ++
            "echo 'Downloading execution-spec-tests bal@v5.5.1 fixtures...' && " ++
            "curl -fL " ++
            "https://github.com/ethereum/execution-spec-tests/releases/download/bal%40v5.5.1/fixtures_bal.tar.gz " ++
            "| tar xz --strip-components=1 -C spec-tests/fixtures/ && " ++
            "echo 'Done. Fixtures extracted to spec-tests/fixtures/'",
    }).step);

    const fetch_zkevm_step = b.step("fetch-zkevm-fixtures", "Download zkevm@v0.3.3 execution-spec-tests fixtures");
    fetch_zkevm_step.dependOn(&b.addSystemCommand(&.{
        "sh", "-c",
        "rm -rf spec-tests/fixtures/zkevm && " ++
            "mkdir -p spec-tests/fixtures/zkevm && " ++
            "echo 'Downloading zkevm@v0.3.3 fixtures...' && " ++
            "curl -fL " ++
            "https://github.com/ethereum/execution-spec-tests/releases/download/zkevm%40v0.3.3/fixtures_zkevm.tar.gz " ++
            "| tar xz --strip-components=1 -C spec-tests/fixtures/zkevm/ && " ++
            "echo 'Done. Fixtures extracted to spec-tests/fixtures/zkevm/'",
    }).step);
}
