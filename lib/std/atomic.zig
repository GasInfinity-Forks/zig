/// This is a thin wrapper around a primitive value to prevent accidental data races.
pub fn Value(comptime T: type) type {
    return extern struct {
        /// Care must be taken to avoid data races when interacting with this field directly.
        raw: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .raw = value };
        }

        pub inline fn load(self: *const Self, comptime order: AtomicOrder) T {
            return @atomicLoad(T, &self.raw, order);
        }

        pub inline fn store(self: *Self, value: T, comptime order: AtomicOrder) void {
            @atomicStore(T, &self.raw, value, order);
        }

        pub inline fn swap(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, .Xchg, operand, order);
        }

        pub inline fn cmpxchgWeak(
            self: *Self,
            expected_value: T,
            new_value: T,
            comptime success_order: AtomicOrder,
            comptime fail_order: AtomicOrder,
        ) ?T {
            return @cmpxchgWeak(T, &self.raw, expected_value, new_value, success_order, fail_order);
        }

        pub inline fn cmpxchgStrong(
            self: *Self,
            expected_value: T,
            new_value: T,
            comptime success_order: AtomicOrder,
            comptime fail_order: AtomicOrder,
        ) ?T {
            return @cmpxchgStrong(T, &self.raw, expected_value, new_value, success_order, fail_order);
        }

        pub inline fn fetchAdd(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, .Add, operand, order);
        }

        pub inline fn fetchSub(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, .Sub, operand, order);
        }

        pub inline fn fetchMin(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, .Min, operand, order);
        }

        pub inline fn fetchMax(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, .Max, operand, order);
        }

        pub inline fn fetchAnd(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, .And, operand, order);
        }

        pub inline fn fetchNand(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, .Nand, operand, order);
        }

        pub inline fn fetchXor(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, .Xor, operand, order);
        }

        pub inline fn fetchOr(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, .Or, operand, order);
        }

        pub inline fn rmw(
            self: *Self,
            comptime op: std.builtin.AtomicRmwOp,
            operand: T,
            comptime order: AtomicOrder,
        ) T {
            return @atomicRmw(T, &self.raw, op, operand, order);
        }

        const Bit = std.math.Log2Int(T);

        /// Marked `inline` so that if `bit` is comptime-known, the instruction
        /// can be lowered to a more efficient machine code instruction if
        /// possible.
        pub inline fn bitSet(self: *Self, bit: Bit, comptime order: AtomicOrder) u1 {
            const mask = @as(T, 1) << bit;
            const value = self.fetchOr(mask, order);
            return @intFromBool(value & mask != 0);
        }

        /// Marked `inline` so that if `bit` is comptime-known, the instruction
        /// can be lowered to a more efficient machine code instruction if
        /// possible.
        pub inline fn bitReset(self: *Self, bit: Bit, comptime order: AtomicOrder) u1 {
            const mask = @as(T, 1) << bit;
            const value = self.fetchAnd(~mask, order);
            return @intFromBool(value & mask != 0);
        }

        /// Marked `inline` so that if `bit` is comptime-known, the instruction
        /// can be lowered to a more efficient machine code instruction if
        /// possible.
        pub inline fn bitToggle(self: *Self, bit: Bit, comptime order: AtomicOrder) u1 {
            const mask = @as(T, 1) << bit;
            const value = self.fetchXor(mask, order);
            return @intFromBool(value & mask != 0);
        }
    };
}

test Value {
    const RefCount = struct {
        count: Value(usize),
        dropFn: *const fn (*RefCount) void,

        const RefCount = @This();

        fn ref(rc: *RefCount) void {
            // no synchronization necessary; just updating a counter.
            _ = rc.count.fetchAdd(1, .monotonic);
        }

        fn unref(rc: *RefCount) void {
            // release ensures code before unref() happens-before the
            // count is decremented as dropFn could be called by then.
            if (rc.count.fetchSub(1, .release) == 1) {
                // seeing 1 in the counter means that other unref()s have happened,
                // but it doesn't mean that uses before each unref() are visible.
                // The load acquires the release-sequence created by previous unref()s
                // in order to ensure visibility of uses before dropping.
                _ = rc.count.load(.acquire);
                (rc.dropFn)(rc);
            }
        }

        fn noop(rc: *RefCount) void {
            _ = rc;
        }
    };

    var ref_count: RefCount = .{
        .count = Value(usize).init(0),
        .dropFn = RefCount.noop,
    };
    ref_count.ref();
    ref_count.unref();
}

test "Value.swap" {
    var x = Value(usize).init(5);
    try testing.expectEqual(@as(usize, 5), x.swap(10, .seq_cst));
    try testing.expectEqual(@as(usize, 10), x.load(.seq_cst));

    const E = enum(usize) { a, b, c };
    var y = Value(E).init(.c);
    try testing.expectEqual(E.c, y.swap(.a, .seq_cst));
    try testing.expectEqual(E.a, y.load(.seq_cst));

    var z = Value(f32).init(5.0);
    try testing.expectEqual(@as(f32, 5.0), z.swap(10.0, .seq_cst));
    try testing.expectEqual(@as(f32, 10.0), z.load(.seq_cst));

    var a = Value(bool).init(false);
    try testing.expectEqual(false, a.swap(true, .seq_cst));
    try testing.expectEqual(true, a.load(.seq_cst));

    var b = Value(?*u8).init(null);
    try testing.expectEqual(@as(?*u8, null), b.swap(@as(?*u8, @ptrFromInt(@alignOf(u8))), .seq_cst));
    try testing.expectEqual(@as(?*u8, @ptrFromInt(@alignOf(u8))), b.load(.seq_cst));
}

test "Value.store" {
    var x = Value(usize).init(5);
    x.store(10, .seq_cst);
    try testing.expectEqual(@as(usize, 10), x.load(.seq_cst));
}

test "Value.cmpxchgWeak" {
    var x = Value(usize).init(0);

    try testing.expectEqual(@as(?usize, 0), x.cmpxchgWeak(1, 0, .seq_cst, .seq_cst));
    try testing.expectEqual(@as(usize, 0), x.load(.seq_cst));

    while (x.cmpxchgWeak(0, 1, .seq_cst, .seq_cst)) |_| {}
    try testing.expectEqual(@as(usize, 1), x.load(.seq_cst));

    while (x.cmpxchgWeak(1, 0, .seq_cst, .seq_cst)) |_| {}
    try testing.expectEqual(@as(usize, 0), x.load(.seq_cst));
}

test "Value.cmpxchgStrong" {
    var x = Value(usize).init(0);
    try testing.expectEqual(@as(?usize, 0), x.cmpxchgStrong(1, 0, .seq_cst, .seq_cst));
    try testing.expectEqual(@as(usize, 0), x.load(.seq_cst));
    try testing.expectEqual(@as(?usize, null), x.cmpxchgStrong(0, 1, .seq_cst, .seq_cst));
    try testing.expectEqual(@as(usize, 1), x.load(.seq_cst));
    try testing.expectEqual(@as(?usize, null), x.cmpxchgStrong(1, 0, .seq_cst, .seq_cst));
    try testing.expectEqual(@as(usize, 0), x.load(.seq_cst));
}

test "Value.fetchAdd" {
    var x = Value(usize).init(5);
    try testing.expectEqual(@as(usize, 5), x.fetchAdd(5, .seq_cst));
    try testing.expectEqual(@as(usize, 10), x.load(.seq_cst));
    try testing.expectEqual(@as(usize, 10), x.fetchAdd(std.math.maxInt(usize), .seq_cst));
    try testing.expectEqual(@as(usize, 9), x.load(.seq_cst));
}

test "Value.fetchSub" {
    var x = Value(usize).init(5);
    try testing.expectEqual(@as(usize, 5), x.fetchSub(5, .seq_cst));
    try testing.expectEqual(@as(usize, 0), x.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), x.fetchSub(1, .seq_cst));
    try testing.expectEqual(@as(usize, std.math.maxInt(usize)), x.load(.seq_cst));
}

test "Value.fetchMin" {
    var x = Value(usize).init(5);
    try testing.expectEqual(@as(usize, 5), x.fetchMin(0, .seq_cst));
    try testing.expectEqual(@as(usize, 0), x.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), x.fetchMin(10, .seq_cst));
    try testing.expectEqual(@as(usize, 0), x.load(.seq_cst));
}

test "Value.fetchMax" {
    var x = Value(usize).init(5);
    try testing.expectEqual(@as(usize, 5), x.fetchMax(10, .seq_cst));
    try testing.expectEqual(@as(usize, 10), x.load(.seq_cst));
    try testing.expectEqual(@as(usize, 10), x.fetchMax(5, .seq_cst));
    try testing.expectEqual(@as(usize, 10), x.load(.seq_cst));
}

test "Value.fetchAnd" {
    var x = Value(usize).init(0b11);
    try testing.expectEqual(@as(usize, 0b11), x.fetchAnd(0b10, .seq_cst));
    try testing.expectEqual(@as(usize, 0b10), x.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0b10), x.fetchAnd(0b00, .seq_cst));
    try testing.expectEqual(@as(usize, 0b00), x.load(.seq_cst));
}

test "Value.fetchNand" {
    var x = Value(usize).init(0b11);
    try testing.expectEqual(@as(usize, 0b11), x.fetchNand(0b10, .seq_cst));
    try testing.expectEqual(~@as(usize, 0b10), x.load(.seq_cst));
    try testing.expectEqual(~@as(usize, 0b10), x.fetchNand(0b00, .seq_cst));
    try testing.expectEqual(~@as(usize, 0b00), x.load(.seq_cst));
}

test "Value.fetchOr" {
    var x = Value(usize).init(0b11);
    try testing.expectEqual(@as(usize, 0b11), x.fetchOr(0b100, .seq_cst));
    try testing.expectEqual(@as(usize, 0b111), x.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0b111), x.fetchOr(0b010, .seq_cst));
    try testing.expectEqual(@as(usize, 0b111), x.load(.seq_cst));
}

test "Value.fetchXor" {
    var x = Value(usize).init(0b11);
    try testing.expectEqual(@as(usize, 0b11), x.fetchXor(0b10, .seq_cst));
    try testing.expectEqual(@as(usize, 0b01), x.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0b01), x.fetchXor(0b01, .seq_cst));
    try testing.expectEqual(@as(usize, 0b00), x.load(.seq_cst));
}

test "Value.bitSet" {
    var x = Value(usize).init(0);

    for (0..@bitSizeOf(usize)) |bit_index| {
        const bit = @as(std.math.Log2Int(usize), @intCast(bit_index));
        const mask = @as(usize, 1) << bit;

        // setting the bit should change the bit
        try testing.expect(x.load(.seq_cst) & mask == 0);
        try testing.expectEqual(@as(u1, 0), x.bitSet(bit, .seq_cst));
        try testing.expect(x.load(.seq_cst) & mask != 0);

        // setting it again shouldn't change the bit
        try testing.expectEqual(@as(u1, 1), x.bitSet(bit, .seq_cst));
        try testing.expect(x.load(.seq_cst) & mask != 0);

        // all the previous bits should have not changed (still be set)
        for (0..bit_index) |prev_bit_index| {
            const prev_bit = @as(std.math.Log2Int(usize), @intCast(prev_bit_index));
            const prev_mask = @as(usize, 1) << prev_bit;
            try testing.expect(x.load(.seq_cst) & prev_mask != 0);
        }
    }
}

test "Value.bitReset" {
    var x = Value(usize).init(0);

    for (0..@bitSizeOf(usize)) |bit_index| {
        const bit = @as(std.math.Log2Int(usize), @intCast(bit_index));
        const mask = @as(usize, 1) << bit;
        x.raw |= mask;

        // unsetting the bit should change the bit
        try testing.expect(x.load(.seq_cst) & mask != 0);
        try testing.expectEqual(@as(u1, 1), x.bitReset(bit, .seq_cst));
        try testing.expect(x.load(.seq_cst) & mask == 0);

        // unsetting it again shouldn't change the bit
        try testing.expectEqual(@as(u1, 0), x.bitReset(bit, .seq_cst));
        try testing.expect(x.load(.seq_cst) & mask == 0);

        // all the previous bits should have not changed (still be reset)
        for (0..bit_index) |prev_bit_index| {
            const prev_bit = @as(std.math.Log2Int(usize), @intCast(prev_bit_index));
            const prev_mask = @as(usize, 1) << prev_bit;
            try testing.expect(x.load(.seq_cst) & prev_mask == 0);
        }
    }
}

test "Value.bitToggle" {
    var x = Value(usize).init(0);

    for (0..@bitSizeOf(usize)) |bit_index| {
        const bit = @as(std.math.Log2Int(usize), @intCast(bit_index));
        const mask = @as(usize, 1) << bit;

        // toggling the bit should change the bit
        try testing.expect(x.load(.seq_cst) & mask == 0);
        try testing.expectEqual(@as(u1, 0), x.bitToggle(bit, .seq_cst));
        try testing.expect(x.load(.seq_cst) & mask != 0);

        // toggling it again *should* change the bit
        try testing.expectEqual(@as(u1, 1), x.bitToggle(bit, .seq_cst));
        try testing.expect(x.load(.seq_cst) & mask == 0);

        // all the previous bits should have not changed (still be toggled back)
        for (0..bit_index) |prev_bit_index| {
            const prev_bit = @as(std.math.Log2Int(usize), @intCast(prev_bit_index));
            const prev_mask = @as(usize, 1) << prev_bit;
            try testing.expect(x.load(.seq_cst) & prev_mask == 0);
        }
    }
}

/// Signals to the processor that the caller is inside a busy-wait spin-loop.
pub inline fn spinLoopHint() void {
    switch (builtin.target.cpu.arch) {
        // No-op instruction that can hint to save (or share with a hardware-thread)
        // pipelining/power resources
        // https://software.intel.com/content/www/us/en/develop/articles/benefitting-power-and-performance-sleep-loops.html
        .x86,
        .x86_64,
        => asm volatile ("pause"),

        // No-op instruction that serves as a hardware-thread resource yield hint.
        // https://stackoverflow.com/a/7588941
        .powerpc,
        .powerpcle,
        .powerpc64,
        .powerpc64le,
        => asm volatile ("or 27, 27, 27"),

        // `isb` appears more reliable for releasing execution resources than `yield`
        // on common aarch64 CPUs.
        // https://bugs.java.com/bugdatabase/view_bug.do?bug_id=8258604
        // https://bugs.mysql.com/bug.php?id=100664
        .aarch64,
        .aarch64_be,
        => asm volatile ("isb"),

        // `yield` was introduced in v6k but is also available on v6m.
        // https://www.keil.com/support/man/docs/armasm/armasm_dom1361289926796.htm
        .arm,
        .armeb,
        .thumb,
        .thumbeb,
        => if (comptime builtin.cpu.hasAny(.arm, &.{ .has_v6k, .has_v6m })) {
            asm volatile ("yield");
        },

        // The 8-bit immediate specifies the amount of cycles to pause for. We can't really be too
        // opinionated here.
        .hexagon,
        => asm volatile ("pause(#1)"),

        .riscv32,
        .riscv64,
        => if (comptime builtin.cpu.has(.riscv, .zihintpause)) {
            asm volatile ("pause");
        },

        else => {},
    }
}

test spinLoopHint {
    for (0..10) |_| {
        spinLoopHint();
    }
}

pub fn cacheLineForCpu(cpu: std.Target.Cpu) u16 {
    return switch (cpu.arch) {
        // x86_64: Starting from Intel's Sandy Bridge, the spatial prefetcher pulls in pairs of 64-byte cache lines at a time.
        // - https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-optimization-manual.pdf
        // - https://github.com/facebook/folly/blob/1b5288e6eea6df074758f877c849b6e73bbb9fbb/folly/lang/Align.h#L107
        //
        // aarch64: Some big.LITTLE ARM archs have "big" cores with 128-byte cache lines:
        // - https://www.mono-project.com/news/2016/09/12/arm64-icache/
        // - https://cpufun.substack.com/p/more-m1-fun-hardware-information
        //
        // - https://github.com/torvalds/linux/blob/3a7e02c040b130b5545e4b115aada7bacd80a2b6/arch/arc/Kconfig#L212
        // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_ppc64x.go#L9
        .x86_64,
        .aarch64,
        .aarch64_be,
        .arc,
        .powerpc64,
        .powerpc64le,
        => 128,

        // https://github.com/llvm/llvm-project/blob/e379094328e49731a606304f7e3559d4f1fa96f9/clang/lib/Basic/Targets/Hexagon.h#L145-L151
        .hexagon,
        => if (cpu.has(.hexagon, .v73)) 64 else 32,

        // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_arm.go#L7
        // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_mips.go#L7
        // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_mipsle.go#L7
        // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_mips64x.go#L9
        // - https://github.com/torvalds/linux/blob/3a7e02c040b130b5545e4b115aada7bacd80a2b6/arch/sparc/include/asm/cache.h#L14
        .arm,
        .armeb,
        .thumb,
        .thumbeb,
        .mips,
        .mipsel,
        .mips64,
        .mips64el,
        .sparc,
        .sparc64,
        => 32,

        // - https://github.com/torvalds/linux/blob/3a7e02c040b130b5545e4b115aada7bacd80a2b6/arch/m68k/include/asm/cache.h#L10
        .m68k,
        => 16,

        // - https://www.ti.com/lit/pdf/slaa498
        .msp430,
        => 8,

        // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_s390x.go#L7
        // - https://sxauroratsubasa.sakura.ne.jp/documents/guide/pdfs/Aurora_ISA_guide.pdf
        .s390x,
        .ve,
        => 256,

        // Other x86 and WASM platforms have 64-byte cache lines.
        // The rest of the architectures are assumed to be similar.
        // - https://github.com/golang/go/blob/dda2991c2ea0c5914714469c4defc2562a907230/src/internal/cpu/cpu_x86.go#L9
        // - https://github.com/golang/go/blob/0a9321ad7f8c91e1b0c7184731257df923977eb9/src/internal/cpu/cpu_loong64.go#L11
        // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_wasm.go#L7
        // - https://github.com/golang/go/blob/19e923182e590ae6568c2c714f20f32512aeb3e3/src/internal/cpu/cpu_riscv64.go#L7
        // - https://github.com/torvalds/linux/blob/3a7e02c040b130b5545e4b115aada7bacd80a2b6/arch/xtensa/variants/csp/include/variant/core.h#L209
        // - https://github.com/torvalds/linux/blob/3a7e02c040b130b5545e4b115aada7bacd80a2b6/arch/csky/Kconfig#L183
        // - https://www.xmos.com/download/The-XMOS-XS3-Architecture.pdf
        else => 64,
    };
}

/// The estimated size of the CPU's cache line when atomically updating memory.
/// Add this much padding or align to this boundary to avoid atomically-updated
/// memory from forcing cache invalidations on near, but non-atomic, memory.
///
/// https://en.wikipedia.org/wiki/False_sharing
/// https://github.com/golang/go/search?q=CacheLinePadSize
pub const cache_line: comptime_int = cacheLineForCpu(builtin.cpu);

test "current CPU has a cache line size" {
    _ = cache_line;
}

pub const Op = union(enum) {
    load,
    store,
    rmw: std.builtin.AtomicRmwOp,
    cmpxchg: enum { weak, strong },

    /// Check if the operation is supported on the given type.
    pub fn supported(op: Op, comptime T: type) bool {
        return op.supportedOnCpu(T, builtin.cpu);
    }

    /// Check if the operation is supported on the given type, on a specified CPU.
    pub fn supportedOnCpu(op: Op, comptime T: type, cpu: std.Target.Cpu) bool {
        const valid_types = op.supportedTypes();
        const is_valid_type = switch (@typeInfo(T)) {
            .bool => valid_types.bool,
            .int => valid_types.integer,
            .float => valid_types.float,
            .@"enum" => valid_types.@"enum",
            .error_set => valid_types.error_set,
            .@"struct" => |s| s.layout == .@"packed" and valid_types.packed_struct,

            .optional => |opt| switch (@typeInfo(opt.child)) {
                .pointer => |ptr| switch (ptr.size) {
                    .slice, .c => false,
                    .one, .many => !ptr.is_allowzero and valid_types.pointer,
                },
            },
            .pointer => |ptr| switch (ptr.size) {
                .slice => false,
                .one, .many, .c => valid_types.pointer,
            },

            else => false,
        };
        if (!is_valid_type) return false;

        if (!std.math.isPowerOfTwo(@sizeOf(T))) return false;
        const condition = op.supportedSizes(cpu.arch).get(@sizeOf(T)) orelse {
            return false;
        };

        return condition.check(cpu.features);
    }

    /// Get the set of sizes supported by this operation on the specified architecture.
    // TODO: Audit this. I've done my best for the architectures I'm familiar with, but there's probably a lot that can improved
    pub fn supportedSizes(op: Op, arch: std.Target.Cpu.Arch) Sizes {
        switch (arch) {
            .avr,
            .msp430,
            => return .upTo(2, .always),

            .arc,
            .hexagon,
            .m68k,
            .mips,
            .mipsel,
            .nvptx,
            .or1k,
            .powerpc,
            .powerpcle,
            .riscv32,
            .xcore,
            .kalimba,
            .lanai,
            .csky,
            .spirv32,
            .loongarch32,
            .xtensa,
            .propeller,
            => return .upTo(4, .always),

            .bpfel,
            .bpfeb,
            .mips64,
            .mips64el,
            .nvptx64,
            .powerpc64,
            .powerpc64le,
            .riscv64,
            .s390x,
            .ve,
            .spirv64,
            .loongarch64,
            => return .upTo(8, .always),

            .amdgcn => switch (op) {
                .load, .store, .cmpxchg => {
                    var sizes: Sizes = .none;
                    sizes.put(4, .always);
                    sizes.put(8, .always);
                    return sizes;
                },
                // On AMDGCN, there are no instructions for atomic operations other than load and store
                // (as of LLVM 15), and so these need to be implemented in terms of atomic CAS.
                .rmw => return .none,
            },

            .sparc => {
                const cas: Sizes = .upTo(4, .all(.sparc, &.{.hasleoncasa}));
                switch (op) {
                    .cmpxchg => return cas,
                    .load, .store => return .upTo(4, .always),
                    .rmw => |rmw| switch (rmw) {
                        .Xchg => return .upTo(4, .always),
                        else => return cas, // Implemented in terms of CASA
                    },
                }
            },

            .sparc64 => {
                const cas: Sizes = .upTo(8, .all(.sparc, &.{.hasleoncasa}));
                switch (op) {
                    .cmpxchg => return cas,
                    .load, .store => return .upTo(8, .always),
                    .rmw => |rmw| switch (rmw) {
                        .Xchg => return .upTo(8, .always),
                        else => return cas, // Implemented in terms of CASXA
                    },
                }
            },

            .arm, .armeb, .thumb, .thumbeb => {
                // Sources:
                // https://developer.arm.com/documentation/dui0489/i/arm-and-thumb-instructions/ldrex
                // https://developer.arm.com/documentation/ddi0406/c/Application-Level-Architecture/Instruction-Details/Alphabetical-list-of-instructions/SWP--SWPB
                // https://developer.arm.com/documentation/ddi0419/c/Application-Level-Architecture/ARM-Architecture-Memory-Model/Memory-types-and-attributes-and-the-memory-order-model/Atomicity-in-the-ARM-architecture

                // NOTE: comptime is needed here to store these conditions in rodata!
                const supports_swp: FeatureCondition = comptime .all(.arm, &.{.v2a});
                const supports_small_rex: FeatureCondition = comptime .@"or"(&.{ .all(.arm, &.{.mclass, .has_v7}), .all(.arm, &.{.mclass, .has_v8m}), .notAll(.arm, &.{.mclass, .has_v6k}) });
                const supports_rex: FeatureCondition = comptime .@"or"(&.{ supports_small_rex, .@"and"(&.{ .notAll(.arm, &.{.mclass}), .all(.arm, &.{.has_v6}) }) });
                const supports_rexd: FeatureCondition = comptime .@"and"(&.{ .notAny(.arm, &.{.mclass}), .all(.arm, &.{.has_v6k}) });

                const rex_sizes = blk: {
                    var sizes: Sizes = .none;
                    sizes.put(1, supports_small_rex);
                    sizes.put(2, supports_small_rex);
                    sizes.put(4, supports_rex);
                    sizes.put(8, supports_rexd);
                    break :blk sizes;
                };

                switch (op) {
                    // aligned loads and stores up to 32-bits become single-copy atomic in v6 / v6m. Before only words were atomic.
                    // ldrex / strex introduced in v6
                    // ldrex(b/h/d) / strex(b/h/d) introduced in v6k except ldrexd/strexd in m-class cpus.
                    .load, .store, => {
                        var sizes: Sizes = .none;
                        sizes.put(1, .all(.arm, &.{.has_v6}));
                        sizes.put(2, .all(.arm, &.{.has_v6}));
                        sizes.put(4, .always); // TODO: audit this
                        return sizes;
                    },
                    .cmpxchg => return rex_sizes,
                    // ldrex / strex introduced in v6
                    // ldrex(b/h/d) / strex(b/h/d) instroduced in v6k
                    .rmw => |rmw_op| switch (rmw_op) {
                        // swp(b) introduced in v2a, deprecated in v6
                        .Xchg => {
                            var sizes: Sizes = .none;
                            sizes.put(1, comptime .@"or"(&.{supports_swp, supports_small_rex}));
                            sizes.put(2, supports_small_rex);
                            sizes.put(4, comptime .@"or"(&.{supports_swp, supports_rex}));
                            sizes.put(8, supports_rexd);
                            return sizes;
                        },
                        else => return rex_sizes,
                    },
                }
            },

            .aarch64,
            .aarch64_be,
            => return .upTo(16, .always),

            .wasm32,
            .wasm64,
            => {
                if (op == .rmw) switch (op.rmw) {
                    .Xchg,
                    .Add,
                    .Sub,
                    .And,
                    .Or,
                    .Xor,
                    => {},

                    .Nand,
                    .Max,
                    .Min,
                    => return .none, // Not supported on wasm
                };

                return .upTo(8, .all(.wasm, &.{.atomics}));
            },

            .x86 => {
                var sizes: Sizes = .upTo(4, .always);
                if (op == .cmpxchg) {
                    sizes.put(8, .all(.x86, &.{.cx8}));
                }
                return sizes;
            },

            .x86_64 => {
                var sizes: Sizes = .upTo(8, .always);
                if (op == .cmpxchg) {
                    sizes.put(16, .all(.x86, &.{.cx16}));
                }
                return sizes;
            },
        }
    }

    pub const Sizes = struct {
        /// Bitset of supported sizes. If size `2^n` is present, `supported & (1 << n)` will be non-zero.
        /// For each set bit, the corresponding entry in `required_features` and `prohibited_features` will be populated.
        supported: BitsetInt,
        /// for each set bit in `supported`, the corresponding entry here stores a `FeatureCondition` that indicates
        /// the requirements on CPU features in order to support that size. For unset bits, the element is `undefined`.
        feature_conditions: [bit_set_len]FeatureCondition,

        const bit_set_len = std.math.log2_int(usize, max_supported_size) + 1;
        const BitsetInt = @Type(.{ .int = .{
            .signedness = .unsigned,
            .bits = bit_set_len,
        } });

        pub fn isEmpty(sizes: Sizes) bool {
            return sizes.supported == 0;
        }
        pub fn get(sizes: Sizes, size: u64) ?FeatureCondition {
            if (size == 0) return .always; // 0-bit types are always atomic, because they only hold a single value
            if (!std.math.isPowerOfTwo(size)) return null;
            if (sizes.supported & size == 0) return null;
            return sizes.feature_conditions[std.math.log2_int(u64, size)];
        }

        pub fn findMax(sizes: Sizes, features: std.Target.Cpu.Feature.Set) usize {
            var bits = sizes.supported;
            while (bits != 0) {
                const max = std.math.log2_int(BitsetInt, bits);
                const mask = @as(BitsetInt, 1) << max;
                bits &= ~mask;
                if (sizes.feature_conditions[max].check(features)) {
                    return mask;
                }
            }
            return 0;
        }

        pub fn findMin(sizes: Sizes, features: std.Target.Cpu.Feature.Set) usize {
            var bits = sizes.supported;
            while (bits != 0) {
                const min = @ctz(bits);
                const mask = @as(BitsetInt, 1) << @intCast(min);
                bits &= ~mask;
                if (sizes.feature_conditions[min].check(features)) {
                    return mask;
                }
            }
            return 0;
        }

        /// Prints the set as a list of possible sizes.
        /// eg. `1, 2, 4, or 8`
        pub fn formatPossibilities(sizes: Sizes, writer: *std.Io.Writer) !void {
            if (sizes.supported == 0) {
                return writer.writeAll("<none>");
            }

            var bits = sizes.supported;
            var count: usize = 0;
            while (bits != 0) : (count += 1) {
                const mask = @as(BitsetInt, 1) << @intCast(@ctz(bits));
                bits &= ~mask;

                if (count > 1 or (count > 0 and bits != 0)) {
                    try writer.writeAll(", ");
                }
                if (bits == 0) {
                    try writer.writeAll("or ");
                }

                try writer.print("{d}", .{mask});
            }
        }

        const none: Sizes = .{
            .supported = 0,
            .feature_conditions = undefined,
        };

        fn upTo(max: BitsetInt, condition: FeatureCondition) Sizes {
            std.debug.assert(std.math.isPowerOfTwo(max));
            var sizes: Sizes = .{
                .supported = (max << 1) -% 1,
                .feature_conditions = @splat(condition),
            };

            // Safety
            const max_idx = std.math.log2_int(BitsetInt, max);
            @memset(sizes.feature_conditions[max_idx + 1 ..], undefined);

            return sizes;
        }

        fn put(sizes: *Sizes, size: BitsetInt, condition: FeatureCondition) void {
            sizes.supported |= size;
            sizes.feature_conditions[std.math.log2_int(u64, size)] = condition;
        }
    };

    pub const FeatureCondition = union(enum) {
        always,
        intersects: Set,
        superset: Set,
        not_intersects: Set,
        not_superset: Set,
        any_condition: []const FeatureCondition,
        all_conditions: []const FeatureCondition,

        const Set = std.Target.Cpu.Feature.Set;

        pub const Formatter = struct {
            condition: FeatureCondition,
            family: std.Target.Cpu.Arch.Family,

            pub fn format(formatter: Formatter, writer: *std.Io.Writer) !void {
                switch (formatter.condition) {
                    .always => try writer.writeAll("true"),
                    .intersects => |set| try writer.print("{f}", .{set.fmtList(formatter.family, "or")}),
                    .superset => |set| try writer.print("{f}", .{set.fmtList(formatter.family, "and")}),
                    .not_intersects => |set| try writer.print("not ({f})", .{set.fmtList(formatter.family, "or")}),
                    .not_superset => |set| try writer.print("not ({f})", .{set.fmtList(formatter.family, "and")}),
                    .any_condition, .all_conditions => |conditions| {
                        const conjunction = switch(std.meta.activeTag(formatter.condition)) {
                            .any_condition => " or ",
                            .all_conditions => " and ",
                            else => unreachable,
                        };

                        for (conditions, 0..) |condition, i| {
                            try writer.print("({f})", .{condition.fmt(formatter.family)});

                            if(i != conditions.len - 1) {
                                try writer.writeAll(conjunction);
                            }
                        }
                    }
                }
            }
        };

        pub fn check(self: FeatureCondition, features: Set) bool {
            return switch (self) {
                .always => true,
                .intersects => |set| features.intersectsWith(set),
                .superset => |set| features.isSuperSetOf(set),
                .not_intersects => |set| !features.intersectsWith(set),
                .not_superset => |set| !features.isSuperSetOf(set),
                .any_condition => |conditions| or_cond: for(conditions) |condition| {
                    if(condition.check(features)) {
                        break :or_cond true;
                    }
                } else false,
                .all_conditions => |conditions| and_cond: for (conditions) |condition| {
                    if(!condition.check(features)) {
                        break :and_cond false;
                    }
                } else true,
            };
        }

        pub fn fmt(condition: FeatureCondition, family: std.Target.Cpu.Arch.Family) Formatter {
            return .{ .condition = condition, .family = family }; 
        }

        fn any(comptime family: std.Target.Cpu.Arch.Family, values: []const @field(std.Target, @tagName(family)).Feature) FeatureCondition {
            const ns = @field(std.Target, @tagName(family));
            return .{ .intersects = ns.featureSet(values) };
        }

        fn all(comptime family: std.Target.Cpu.Arch.Family, values: []const @field(std.Target, @tagName(family)).Feature) FeatureCondition {
            const ns = @field(std.Target, @tagName(family));
            return .{ .superset = ns.featureSet(values) };
        }

        fn notAny(comptime family: std.Target.Cpu.Arch.Family, values: []const @field(std.Target, @tagName(family)).Feature) FeatureCondition {
            const ns = @field(std.Target, @tagName(family));
            return .{ .not_intersects = ns.featureSet(values) };
        }

        fn notAll(comptime family: std.Target.Cpu.Arch.Family, values: []const @field(std.Target, @tagName(family)).Feature) FeatureCondition {
            const ns = @field(std.Target, @tagName(family));
            return .{ .not_superset = ns.featureSet(values) };
        }

        fn @"or"(values: []const FeatureCondition) FeatureCondition {
            return .{ .any_condition = values };
        }

        fn @"and"(values: []const FeatureCondition) FeatureCondition {
            return .{ .all_conditions = values };
        }
    };

    /// The maximum size supported by any architecture
    const max_supported_size = 16;

    pub fn format(op: Op, writer: *std.Io.Writer) !void {
        switch (op) {
            .load => try writer.writeAll("@atomicLoad"),
            .store => try writer.writeAll("@atomicStore"),
            .rmw => |rmw| try writer.print("@atomicRmw(.{s})", .{@tagName(rmw)}),
            .cmpxchg => |strength| switch (strength) {
                .weak => try writer.writeAll("@cmpxchgWeak"),
                .strong => try writer.writeAll("@cmpxchgStrong"),
            },
        }
    }

    /// Returns a description of the kinds of type supported by this operation.
    pub fn supportedTypes(op: Op) Types {
        return switch (op) {
            .load, .store => .{},
            .rmw => |rmw| switch (rmw) {
                .Xchg => .{},
                .Add, .Sub, .Min, .Max => .{
                    .bool = false,
                    .@"enum" = false,
                    .error_set = false,
                },
                .And, .Nand, .Or, .Xor => .{
                    .float = false,
                    .bool = false,
                    .@"enum" = false,
                    .error_set = false,
                },
            },
            .cmpxchg => .{
                // floats are not supported for cmpxchg because float equality differs from bitwise equality
                .float = false,
            },
        };
    }
    pub const Types = packed struct {
        bool: bool = true,
        integer: bool = true,
        float: bool = true,
        @"enum": bool = true,
        error_set: bool = true,
        packed_struct: bool = true,
        pointer: bool = true,

        pub fn format(types: Types, writer: *std.io.Writer) !void {
            const bits: @typeInfo(Types).@"struct".backing_integer.? = @bitCast(types);
            var count = @popCount(bits);
            inline for (@typeInfo(Types).@"struct".fields) |field| {
                if (@field(types, field.name)) {
                    var name = field.name[0..].*;
                    std.mem.replaceScalar(u8, &name, '_', ' ');
                    try writer.writeAll(&name);

                    count -= 1;
                    switch (count) {
                        0 => {},
                        1 => try writer.writeAll(", or "),
                        else => try writer.writeAll(", "),
                    }
                }
            }
        }
    };

    test supportedOnCpu {
        const x86 = std.Target.x86;
        try std.testing.expect(
            supportedOnCpu(.load, u64, x86.cpu.x86_64.toCpu(.x86_64)),
        );
        try std.testing.expect(
            !supportedOnCpu(.{ .cmpxchg = .weak }, u128, x86.cpu.x86_64.toCpu(.x86_64)),
        );
        try std.testing.expect(
            supportedOnCpu(.{ .cmpxchg = .weak }, u128, x86.cpu.x86_64_v2.toCpu(.x86_64)),
        );

        const aarch64 = std.Target.aarch64;
        try std.testing.expect(
            supportedOnCpu(.load, u64, aarch64.cpu.generic.toCpu(.aarch64)),
        );
    }

    test supportedSizes {
        const sizes = supportedSizes(.{ .cmpxchg = .strong }, .x86);

        try std.testing.expect(sizes.get(4) != null);
        try std.testing.expect(sizes.get(4).?.check(.empty));

        try std.testing.expect(sizes.get(8) != null);
        try std.testing.expect(!sizes.get(8).?.check(.empty));
        try std.testing.expect(sizes.get(8).?.check(std.Target.x86.featureSet(&.{.cx8})));

        try std.testing.expect(sizes.get(16) == null);
    }

    test "wasm only supports atomics when the feature is enabled" {
        const cpu = std.Target.wasm.cpu;
        try std.testing.expect(
            !supportedOnCpu(.store, u32, cpu.mvp.toCpu(.wasm32)),
        );
        try std.testing.expect(
            supportedOnCpu(.store, u32, cpu.bleeding_edge.toCpu(.wasm32)),
        );
    }

    test "wasm32 supports up to 64-bit atomics" {
        const bleeding = std.Target.wasm.cpu.bleeding_edge.toCpu(.wasm32);
        try std.testing.expect(
            supportedOnCpu(.store, u64, bleeding),
        );
        try std.testing.expect(
            !supportedOnCpu(.store, u128, bleeding),
        );

        const sizes = supportedSizes(.{ .rmw = .Add }, .wasm32);
        try std.testing.expect(sizes.supported == 0b1111);
    }

    test "wasm32 doesn't support min, max, or nand RMW ops" {
        const bleeding = std.Target.wasm.cpu.bleeding_edge.toCpu(.wasm32);
        try std.testing.expect(
            !supportedOnCpu(.{ .rmw = .Min }, u32, bleeding),
        );
        try std.testing.expect(
            !supportedOnCpu(.{ .rmw = .Max }, u32, bleeding),
        );
        try std.testing.expect(
            !supportedOnCpu(.{ .rmw = .Nand }, u32, bleeding),
        );
    }

    test "x86_64 supports 128-bit cmpxchg with cx16 flag" {
        const x86 = std.Target.x86;
        const v2 = x86.cpu.x86_64_v2.toCpu(.x86_64);
        try std.testing.expect(
            supportedOnCpu(.{ .cmpxchg = .strong }, u128, v2),
        );

        const sizes = supportedSizes(.{ .cmpxchg = .strong }, .x86_64);
        try std.testing.expect(sizes.get(16) != null);
        try std.testing.expect(sizes.get(16).?.check(x86.featureSet(&.{.cx16})));
        try std.testing.expect(!sizes.get(16).?.check(.empty));
    }

    test "arm baseline supports all ops up to 64-bit" {
        const arm = std.Target.arm;
        const baseline = arm.cpu.baseline.toCpu(.arm);
        try std.testing.expect(supportedOnCpu(.{ .rmw = .Xchg }, u8, baseline));
        try std.testing.expect(supportedOnCpu(.{ .rmw = .Xchg }, u16, baseline));
        try std.testing.expect(supportedOnCpu(.{ .rmw = .Xchg }, u32, baseline));
        try std.testing.expect(supportedOnCpu(.{ .rmw = .Xchg }, u64, baseline));

        const sizes = supportedSizes(.{ .rmw = .Xchg }, .arm);
        try std.testing.expect(sizes.get(4) != null);
        try std.testing.expect(sizes.get(4).?.check(arm.featureSet(&.{.has_v6})));
        try std.testing.expect(!sizes.get(4).?.check(.empty));
    }

    test "arm supports 32-bit Xchg RWM op with v6 and without mclass feature" {
        const arm = std.Target.arm;
        const arm1136j_s = arm.cpu.arm1136j_s.toCpu(.arm);
        try std.testing.expect(supportedOnCpu(.{ .rmw = .Xchg }, u32, arm1136j_s));

        const sizes = supportedSizes(.{ .rmw = .Xchg }, .arm);
        try std.testing.expect(sizes.get(4) != null);
        try std.testing.expect(sizes.get(4).?.check(arm.featureSet(&.{.has_v6})));
        try std.testing.expect(!sizes.get(4).?.check(.empty));
    }

    test "arm supports 64-bit Xchg RWM op with v6k and without mclass features" {
        const arm = std.Target.arm;
        const mpcore = arm.cpu.mpcore.toCpu(.arm);
        try std.testing.expect(supportedOnCpu(.{ .rmw = .Xchg }, u64, mpcore));

        const sizes = supportedSizes(.{ .rmw = .Xchg }, .arm);
        try std.testing.expect(sizes.get(8) != null);
        try std.testing.expect(sizes.get(8).?.check(arm.featureSet(&.{.has_v6k})));
        try std.testing.expect(!sizes.get(8).?.check(.empty));
    }
};

test Op {
    try std.testing.expect(
        // Query atomic operation support for a specific CPU
        Op.supportedOnCpu(.load, u64, std.Target.aarch64.cpu.generic.toCpu(.aarch64)),
    );

    // Query atomic operation support for the target CPU
    _ = Op.supported(.load, u64);
}

const std = @import("std.zig");
const builtin = @import("builtin");
const AtomicOrder = std.builtin.AtomicOrder;
const testing = std.testing;
