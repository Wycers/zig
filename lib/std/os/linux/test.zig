const std = @import("../../std.zig");
const builtin = @import("builtin");
const linux = std.os.linux;
const mem = std.mem;
const elf = std.elf;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const fs = std.fs;

test "fallocate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "test_fallocate";
    const file = try tmp.dir.createFile(path, .{ .truncate = true, .mode = 0o666 });
    defer file.close();

    try expect((try file.stat()).size == 0);

    const len: i64 = 65536;
    switch (linux.getErrno(linux.fallocate(file.handle, 0, 0, len))) {
        .SUCCESS => {},
        .NOSYS => return error.SkipZigTest,
        .OPNOTSUPP => return error.SkipZigTest,
        else => |errno| std.debug.panic("unhandled errno: {}", .{errno}),
    }

    try expect((try file.stat()).size == len);
}

test "getpid" {
    try expect(linux.getpid() != 0);
}

test "timer" {
    const epoll_fd = linux.epoll_create();
    var err: linux.E = linux.getErrno(epoll_fd);
    try expect(err == .SUCCESS);

    const timer_fd = linux.timerfd_create(linux.CLOCK.MONOTONIC, 0);
    try expect(linux.getErrno(timer_fd) == .SUCCESS);

    const time_interval = linux.timespec{
        .tv_sec = 0,
        .tv_nsec = 2000000,
    };

    const new_time = linux.itimerspec{
        .it_interval = time_interval,
        .it_value = time_interval,
    };

    err = linux.getErrno(linux.timerfd_settime(@as(i32, @intCast(timer_fd)), 0, &new_time, null));
    try expect(err == .SUCCESS);

    var event = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.ET,
        .data = linux.epoll_data{ .ptr = 0 },
    };

    err = linux.getErrno(linux.epoll_ctl(@as(i32, @intCast(epoll_fd)), linux.EPOLL.CTL_ADD, @as(i32, @intCast(timer_fd)), &event));
    try expect(err == .SUCCESS);

    const events_one: linux.epoll_event = undefined;
    var events = [_]linux.epoll_event{events_one} ** 8;

    err = linux.getErrno(linux.epoll_wait(@as(i32, @intCast(epoll_fd)), &events, 8, -1));
    try expect(err == .SUCCESS);
}

test "statx" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file_name = "just_a_temporary_file.txt";
    var file = try tmp.dir.createFile(tmp_file_name, .{});
    defer file.close();

    var statx_buf: linux.Statx = undefined;
    switch (linux.getErrno(linux.statx(file.handle, "", linux.AT.EMPTY_PATH, linux.STATX_BASIC_STATS, &statx_buf))) {
        .SUCCESS => {},
        // The statx syscall was only introduced in linux 4.11
        .NOSYS => return error.SkipZigTest,
        else => unreachable,
    }

    var stat_buf: linux.Stat = undefined;
    switch (linux.getErrno(linux.fstatat(file.handle, "", &stat_buf, linux.AT.EMPTY_PATH))) {
        .SUCCESS => {},
        else => unreachable,
    }

    try expect(stat_buf.mode == statx_buf.mode);
    try expect(@as(u32, @bitCast(stat_buf.uid)) == statx_buf.uid);
    try expect(@as(u32, @bitCast(stat_buf.gid)) == statx_buf.gid);
    try expect(@as(u64, @bitCast(@as(i64, stat_buf.size))) == statx_buf.size);
    try expect(@as(u64, @bitCast(@as(i64, stat_buf.blksize))) == statx_buf.blksize);
    try expect(@as(u64, @bitCast(@as(i64, stat_buf.blocks))) == statx_buf.blocks);
}

test "user and group ids" {
    if (builtin.link_libc) return error.SkipZigTest;
    try expectEqual(linux.getauxval(elf.AT_UID), linux.getuid());
    try expectEqual(linux.getauxval(elf.AT_GID), linux.getgid());
    try expectEqual(linux.getauxval(elf.AT_EUID), linux.geteuid());
    try expectEqual(linux.getauxval(elf.AT_EGID), linux.getegid());
}

test "fadvise" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file_name = "temp_posix_fadvise.txt";
    var file = try tmp.dir.createFile(tmp_file_name, .{});
    defer file.close();

    var buf: [2048]u8 = undefined;
    try file.writeAll(&buf);

    const ret = linux.fadvise(file.handle, 0, 0, linux.POSIX_FADV.SEQUENTIAL);
    try expectEqual(@as(usize, 0), ret);
}

fn setup_cpu_set(cpus: *const [4]usize, set: *linux.cpu_set_t) void {
    linux.CPU_ZERO(set);
    for (cpus) |pos| {
        linux.CPU_SET(pos, set);
    }
}

test "cpu_set_t" {
    if (builtin.link_libc) return error.SkipZigTest;

    // CPU_ZERO
    var set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    for (set, 0..) |_, i| {
        set[i] = i;
    }
    linux.CPU_ZERO(&set);
    for (0..16) |i| {
        try expectEqual(@as(usize, 0x00), set[i]);
    }

    // CPU_COUNT
    for (0..linux.CPU_SETSIZE) |i| {
        linux.CPU_SET(i, &set);
        try expect(linux.CPU_ISSET(i, set));
        try expectEqual(i + 1, linux.CPU_COUNT(set));
    }
    for (0..16) |i| {
        try expectEqual(@as(usize, 0xFF), set[i]);
    }

    // CPU_CLR
    for (0..linux.CPU_SETSIZE) |i| {
        linux.CPU_CLR(i, &set);
        try expect(linux.CPU_ISSET(i, set) == false);
    }

    // CPU_SET
    const cases = [_][4]usize{
        [_]usize{ 2, 0, 0, 0 },
        [_]usize{ 7, 8, 0, 0 },
        [_]usize{ 5, 14, 24, 0 },
        [_]usize{ 4, 12, 13, 127 },
    };
    for (cases) |case| {
        setup_cpu_set(&case, &set);
        for (0..16) |i| {
            var expected: usize = 0x00;
            for (case) |pos| {
                if (pos / @sizeOf(usize) == i) {
                    var p: u6 = @intCast(pos % @sizeOf(usize));
                    expected |= @as(usize, 1) << p;
                }
            }
            try expectEqual(expected, set[i]);
        }
    }

    // CPU_SET invalid cpu number
    linux.CPU_ZERO(&set);
    linux.CPU_SET(@as(usize, 128), &set);
    for (0..16) |i| {
        try expectEqual(@as(usize, 0x00), set[i]);
    }

    var op1: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    var op2: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    var res: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);

    const a = [_]usize{ 5, 14, 24, 78 };
    const b = [_]usize{ 1, 5, 9, 24 };
    const res_and = [_]usize{ 5, 24 };
    const res_or = [_]usize{ 1, 5, 9, 14, 24, 78 };
    const res_xor = [_]usize{ 1, 9, 14, 78 };

    setup_cpu_set(&a, &op1);
    setup_cpu_set(&b, &op2);

    linux.CPU_AND(&res, op1, op2);
    try expectEqual(res_and.len, linux.CPU_COUNT(res));
    for (res_and) |pos| {
        try expect(linux.CPU_ISSET(pos, res));
    }

    linux.CPU_OR(&res, op1, op2);
    try expectEqual(res_or.len, linux.CPU_COUNT(res));
    for (res_or) |pos| {
        try expect(linux.CPU_ISSET(pos, res));
    }

    linux.CPU_XOR(&res, op1, op2);
    try expectEqual(res_xor.len, linux.CPU_COUNT(res));
    for (res_xor) |pos| {
        try expect(linux.CPU_ISSET(pos, res));
    }

    try expectEqual(false, linux.CPU_EQUAL(op1, op2));
    setup_cpu_set(&a, &op1);
    setup_cpu_set(&a, &op2);
    try expectEqual(true, linux.CPU_EQUAL(op1, op2));
}
