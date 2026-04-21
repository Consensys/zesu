/// zkVM I/O Interface
///
/// Conforms to zkvm-standards/standards/io-interface/README.md
///
/// Semantics:
///   read_input  — zero-copy, idempotent; sets pointer to private input buffer.
///                 buf_size == 0 means input is invalid / unavailable.
///   write_output — appends to public output; multiple calls concatenate.
///                  Cannot fail.
///
/// This module is the default I/O implementation (reads from a file / stdin,
/// writes to stdout).  Override at build time for zkVM targets:
///   exe.root_module.addImport("zkvm_io", your_io_module)
/// The replacement module must export the same two functions.

const io_impl = @import("io_impl");

/// Read private input.
/// Sets *buf_ptr to the start of the input buffer and *buf_size to its length.
/// Idempotent — calling multiple times returns the same pointer and size.
/// buf_size == 0 means no valid input is available.
pub inline fn read_input(buf_ptr: *[*]const u8, buf_size: *usize) void {
    io_impl.read_input(buf_ptr, buf_size);
}

/// Append bytes to the public output stream.
/// Multiple calls concatenate; the verifier sees the combined output.
pub inline fn write_output(output: []const u8) void {
    io_impl.write_output(output);
}
