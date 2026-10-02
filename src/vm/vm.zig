const std = @import("std");

const AST = @import("ast");
const BuildConfig = @import("config");
const Compilation = @import("compilation");
const Instruction = Compilation.Instruction;
const Diagnostic = Compilation.Diagnostic;
const Printing = @import("printing");
const Runtime = @import("shared_runtime");
const Memory = Runtime.Memory;
const EquationFetcher = Runtime.EquationFetcher;
const Types = Runtime.Types;
const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Special = Types.Special;
const EquationUnnormalized = Types.EquationUnnormalized;

pub const Core = @import("core.zig");
const CoreMode = @import("core_types.zig").CoreMode;
const CoreId = @import("core_types.zig").CoreId;
const CoreRc = @import("core_types.zig").CoreRc;
const CoreRole = @import("core_types.zig").CoreRole;
const CtrlSig = @import("core_types.zig").CtrlSig;
const ActTimer = @import("core_types.zig").ActTimer;
const VmError = @import("core_types.zig").Error;

pub const CoreMasterCtrl = @import("core_master_ctrl.zig");
pub const CoreSlaveCtrl = @import("core_slave_ctrl.zig");
pub const SlaveCtrlState = @import("core_slave_ctrl.zig").State;

pub const CtrlCh = @import("flag_channel.zig").CtrlCh;

pub const Builtin = @import("builtin.zig");
pub const Importer = @import("importer.zig");
pub const Interaction = @import("interactions.zig");
const Normalize = @import("normalize.zig");
pub const normalizeEquation = Normalize.normalizeEquation;

const VM = @This();
const Self = VM;

const getUser = "getUser";

cfg: Config,

global_ctx: GlobalCtx,
runtime: *Runtime,

vm_core: Core,
vmode: VMode,

var available_core_id: u32 = 0;

const VMode = union(enum) {
    s: Single,
    m: Multi,

    fn initS() VMode {
        return .{ .s = {} };
    }

    fn initM(
        cfg: Config,
        runtime: *Runtime,
        gpa: std.mem.Allocator,
        global_ctx: GlobalCtx,
    ) !VMode {
        // TODO:(kogora) support timout_opt in Config (now it is null)
        return .{ .m = try Multi.init(null, cfg.cores_num, gpa, runtime, global_ctx, runtime.io) };
    }

    fn deinit(
        self: *VMode,
        gpa: std.mem.Allocator,
        global_ctx: GlobalCtx,
    ) void {
        switch (self.*) {
            .s => {},
            .m => |*m| {
                m.deinit(global_ctx, gpa);
            },
        }
    }

    const Single = void;
    const Multi = struct {
        master_ctrl: *CoreMasterCtrl,
        slots: []Slot,
        slot_acts: []SlotAct,

        const max_slot_cnt = 64;

        const SlotAct = struct {
            res: ?Result = null,
            timer: ActTimer,

            fn clear(slot_act: *SlotAct) void {
                slot_act.res = null;
                slot_act.timer.stop();
            }
        };

        const FailPolicy = enum {
            retry_on_fail,
            exit_on_fail,
        };

        const Result = enum {
            success,
            retry,
            fail,
        };

        fn slotsDeinit(
            slots: []Slot,
            global_ctx: GlobalCtx,
            gpa: std.mem.Allocator,
        ) void {
            for (slots) |*slot| {
                global_ctx.destroyLocal(slot.core.local_ctx, gpa);
                slot.ch.ch.destroy(gpa);
            }

            gpa.free(slots);
        }

        fn slotsInit(
            runtime: *Runtime,
            global_ctx: GlobalCtx,
            slots_cnt: usize,
            gpa: std.mem.Allocator,
        ) ![]Slot {
            const slots: []Slot = try gpa.alloc(Slot, slots_cnt);
            errdefer gpa.free(slots);

            for (slots) |*slot| {
                // FIX:(kogora) if error => mem leak now
                const ch = try CtrlCh.create(gpa);
                const ctx = global_ctx.createLocal(gpa);

                slot.init(CoreMode.multiThread, available_core_id, ch, runtime, ctx);

                available_core_id += 1;
            }

            return slots;
        }

        fn slotActsDeInit(slot_acts: []SlotAct, gpa: std.mem.Allocator) void {
            gpa.free(slot_acts);
        }

        fn slotActsInit(
            gpa: std.mem.Allocator,
            io: std.Io,
            slots_cnt: usize,
            timeout_opt: ?i64,
        ) ![]SlotAct {
            const slot_acts: []SlotAct = try gpa.alloc(SlotAct, slots_cnt);
            errdefer gpa.free(slot_acts);

            for (slot_acts) |*slot_act| {
                slot_act.* = .{
                    .timer = ActTimer.init(timeout_opt, io),
                };
            }

            return slot_acts;
        }

        fn masterCtrlDeinit(master_ctrl: *CoreMasterCtrl, gpa: std.mem.Allocator) void {
            master_ctrl.deinit();
            gpa.destroy(master_ctrl);
        }

        fn masterCtrlInit(gpa: std.mem.Allocator) !*CoreMasterCtrl {
            const master_ctrl = try gpa.create(CoreMasterCtrl);
            errdefer gpa.destroy(master_ctrl);

            master_ctrl.* = CoreMasterCtrl.init();
            return master_ctrl;
        }

        fn deinit(
            self: *Multi,
            global_ctx: GlobalCtx,
            gpa: std.mem.Allocator,
        ) void {
            masterCtrlDeinit(self.master_ctrl, gpa);
            slotActsDeInit(self.slot_acts, gpa);
            slotsDeinit(self.slots, global_ctx, gpa);
        }

        fn init(
            timout_opt: ?i64,
            slot_cnt: usize,
            gpa: std.mem.Allocator,
            runtime: *Runtime,
            global_ctx: GlobalCtx,
            io: std.Io,
        ) !Multi {
            if (slot_cnt > Multi.max_slot_cnt) {
                return VmError.NotSupported;
            }

            const slots = try slotsInit(runtime, global_ctx, slot_cnt, gpa);
            errdefer slotsDeinit(slots, global_ctx, gpa);

            const slot_acts = try slotActsInit(gpa, io, slot_cnt, timout_opt);
            errdefer slotActsDeInit(slot_acts, gpa);

            const master_ctrl = try masterCtrlInit(gpa);
            errdefer masterCtrlDeinit(master_ctrl, gpa);

            return .{
                .slots = slots,
                .slot_acts = slot_acts,
                .master_ctrl = master_ctrl,
            };
        }

        fn waitUntil(
            self: *Multi,
            comptime policy: FailPolicy,
            context: anytype,
            comptime act: fn (*Slot, @TypeOf(context)) Result,
        ) ?usize {
            var in_work = std.bit_set.IntegerBitSet(max_slot_cnt).initEmpty();
            var first_fail_idx: ?usize = null;

            for (self.slot_acts, 0..) |*slot_act, idx| {
                slot_act.clear();
                in_work.set(idx);
            }

            while (in_work.count() != 0) {
                next_slot: for (self.slots, self.slot_acts, 0..) |*slot, *slot_act, idx| {
                    if (!in_work.isSet(idx)) {
                        continue :next_slot;
                    }

                    var res = act(slot, context);
                    switch (res) {
                        .success, .fail => {},
                        .retry => {
                            if (!slot_act.timer.is_start) {
                                slot_act.timer.start();
                            } else if (slot_act.timer.is_timeout()) {
                                res = .fail;
                            }
                        },
                    }
                    slot_act.res = res;

                    if (res == .retry) {
                        std.atomic.spinLoopHint();
                        continue :next_slot;
                    }

                    in_work.unset(idx);

                    if (res == .fail) {
                        if (first_fail_idx == null) {
                            first_fail_idx = idx;
                        }

                        if (policy == .exit_on_fail) {
                            return first_fail_idx;
                        }
                    }
                }
            }

            return first_fail_idx;
        }

        fn anyCoreThreadSpawned(self: *Multi) bool {
            for (self.slots) |*slot| {
                if (slot.thread != null) {
                    return true;
                }
            }

            return false;
        }

        fn spawnCoreThreads(self: *Multi) !void {
            for (self.slots) |*slot| {
                slot.thread = try std.Thread.spawn(.{}, Core.runEquations, .{&slot.core});
            }
        }

        fn killCoreThreads(self: *Multi) void {
            _ = self.waitUntil(.retry_on_fail, CtrlSig.kill_sig, Slot.sigSent);

            for (self.slots) |*slot| {
                if (slot.thread) |thread| {
                    thread.join();
                    slot.thread = null;
                }
            }
        }
    };
};

pub const Config = struct {
    cores_num: usize,
    heap_size: usize,

    warmup: bool = false,

    pub fn isValid(cfg: *const Config) !void {
        if (cfg.cores_num == 0) {
            return VmError.NotSupported;
        }

        if (cfg.cores_num > VMode.Multi.max_slot_cnt) {
            return VmError.NotSupported;
        }
    }

    pub fn getMode(cfg: *const Config) CoreMode {
        return if (cfg.cores_num == 1) .singleThread else .multiThread;
    }
};

pub const Slot = struct {
    ch: CtrlCh.Master,
    ctrl: CoreSlaveCtrl,

    core: Core,
    thread: ?std.Thread = null,

    pub fn init(
        self: *Slot,
        mode: CoreMode,
        raw_id: u32,
        ch: *CtrlCh,
        runtime: *Runtime,
        ctx: Core.LocalCtx,
    ) void {
        const master_ch = ch.getMaster();
        const slave_ch = ch.getSlave();

        self.* = .{
            .ch = master_ch,
            .ctrl = CoreSlaveCtrl.init(slave_ch),
            .core = Core.init(
                CoreId{ .slave = raw_id },
                mode,
                runtime,
                Core.CoreCtrl{ .slave = &self.ctrl },
                ctx,
            ),
        };
    }

    const Result = VMode.Multi.Result;

    /// Checks the state once: no retries.
    fn stateIs(slot: *Slot, state: CoreSlaveCtrl.State) Result {
        return if (slot.ctrl.getState() == state) .success else .fail;
    }

    /// Retries until the state is reached (or the slot's timer expires).
    fn stateReached(slot: *Slot, state: CoreSlaveCtrl.State) Result {
        return if (slot.ctrl.getState() == state) .success else .retry;
    }

    /// Slots without a running thread are skipped (nobody would answer).
    fn sigSent(slot: *Slot, sig: CtrlSig) Result {
        if (slot.thread == null) {
            return .success;
        }

        return if (slot.ch.trySetFlag(sig)) .success else .retry;
        // FIX:(kogora) i should send and get success answer
        // now it doesnt work
    }
};

pub const GlobalCtx = struct {
    agent_heap: Memory.Heap(Agent),
    name_heap: Memory.Heap(Name),
    equation_fetcher: EquationFetcher,

    fn HeapType(comptime T: type) type {
        switch (BuildConfig.heap) {
            .basic => return Memory.BasicHeap(T),
            .objpool => return Memory.ObjPool(T),
        }
    }

    fn heapInit(comptime T: type, heap_size: usize, gpa: std.mem.Allocator) !Memory.Heap(T) {
        const basic_heap = try gpa.create(HeapType(T));

        basic_heap.* = switch (BuildConfig.heap) {
            .basic => try Memory.BasicHeap(T).init(gpa, heap_size),
            .objpool => try Memory.ObjPool(T).init(gpa, heap_size),
        };

        return basic_heap.heap();
    }

    fn heapDeinit(comptime T: type, heap: Memory.Heap(T), gpa: std.mem.Allocator) void {
        const basic_heap: *HeapType(T) = @ptrCast(@alignCast(heap.ptr));

        basic_heap.deinit(gpa);
        gpa.destroy(basic_heap);
    }

    fn equationFetcherInit(gpa: std.mem.Allocator) !EquationFetcher {
        const FetcherType = EquationFetcher.TwoDequeEquationFetcher;
        const two_deque_equation_fetcher = try gpa.create(FetcherType);
        two_deque_equation_fetcher.* = .init(gpa);

        return two_deque_equation_fetcher.equationFetcher();
    }

    fn equationFetcherDeinit(equation_fetcher: EquationFetcher, gpa: std.mem.Allocator) void {
        const FetcherType = EquationFetcher.TwoDequeEquationFetcher;
        const two_deque_equation_fetcher: *FetcherType = @ptrCast(@alignCast(equation_fetcher.ptr));
        two_deque_equation_fetcher.deinit();
        gpa.destroy(two_deque_equation_fetcher);
    }

    fn getHeapUser(comptime T: type, heap: Memory.Heap(T), gpa: std.mem.Allocator) Memory.Heap(T) {
        _ = gpa;
        const Concrete = HeapType(T);
        if (@hasDecl(Concrete, getUser)) {
            const concrete: *Concrete = @ptrCast(@alignCast(heap.ptr));
            return concrete.getUser();
        }

        // TODO:(kogora) mb should be unreachable
        return heap;
    }

    fn getFetcherUser(fetcher: EquationFetcher, gpa: std.mem.Allocator) EquationFetcher {
        _ = gpa;
        const Concrete = EquationFetcher.TwoDequeEquationFetcher;
        if (@hasDecl(Concrete, getUser)) {
            const concrete: *Concrete = @ptrCast(@alignCast(fetcher.ptr));
            return concrete.getUser();
        }
        return fetcher;
    }

    pub fn init(runtime: *Runtime, config: Config) !GlobalCtx {
        const agent_heap = try heapInit(Agent, config.heap_size, runtime.gpa);
        errdefer heapDeinit(Agent, agent_heap, runtime.gpa);

        const name_heap = try heapInit(Name, config.heap_size, runtime.gpa);
        errdefer heapDeinit(Name, name_heap, runtime.gpa);

        const equation_fetcher = try equationFetcherInit(runtime.gpa);
        errdefer equationFetcherDeinit(equation_fetcher, runtime.gpa);

        return .{
            .agent_heap = agent_heap,
            .name_heap = name_heap,
            .equation_fetcher = equation_fetcher,
        };
    }

    pub fn deinit(self: *GlobalCtx, gpa: std.mem.Allocator) void {
        equationFetcherDeinit(self.equation_fetcher, gpa);
        heapDeinit(Name, self.name_heap, gpa);
        heapDeinit(Agent, self.agent_heap, gpa);
    }

    pub fn createLocal(self: GlobalCtx, gpa: std.mem.Allocator) Core.LocalCtx {
        return .{
            .agent_heap = getHeapUser(Agent, self.agent_heap, gpa),
            .name_heap = getHeapUser(Name, self.name_heap, gpa),
            .equation_fetcher = getFetcherUser(self.equation_fetcher, gpa),
        };
    }

    pub fn createVmLocal(self: GlobalCtx) !Core.LocalCtx {
        const S = struct {
            var exist: bool = false;
        };

        if (S.exist) {
            return error.AccessDenied;
        }

        S.exist = true;
        return .{
            .agent_heap = self.agent_heap,
            .name_heap = self.name_heap,
            .equation_fetcher = self.equation_fetcher,
        };
    }

    pub fn destroyLocal(self: GlobalCtx, local_ctx: Core.LocalCtx, gpa: std.mem.Allocator) void {
        _ = self;
        _ = local_ctx;
        _ = gpa;
    }

    pub fn balanceEquations(self: *GlobalCtx) void {
        _ = self;
        // TODO:(kogora) equation balancer should be implemented as a part (and responsibility)
        // of the concrete fetcher, but it should provide an endpoint for vm-using. The function
        // is a wrapper above that endpoint.
    }

    pub fn pushEquation(self: GlobalCtx, eq: EquationUnnormalized) !void {
        try Normalize.pushEquation(self.name_heap, self.equation_fetcher, eq);
    }

    pub fn pushUrgentEquation(self: GlobalCtx, eq: EquationUnnormalized) !void {
        try Normalize.pushUrgentEquation(self.name_heap, self.equation_fetcher, eq);
    }
};

pub fn deinit(self: *Self) void {
    switch (self.vmode) {
        .s => {},
        .m => |*m| {
            std.debug.assert(!m.anyCoreThreadSpawned());

            m.deinit(self.global_ctx, self.runtime.gpa);
        },
    }

    self.global_ctx.deinit(self.runtime.gpa);
}

pub fn init(runtime: *Runtime, cfg: Config) !Self {
    try cfg.isValid();

    const mode = cfg.getMode();
    std.debug.assert(mode == CoreMode.singleThread); // TODO:(kogora): multithread version

    var vm_core: Core = undefined;
    var vmode: VMode = undefined;

    var global_ctx = try GlobalCtx.init(runtime, cfg);
    errdefer global_ctx.deinit(runtime.gpa);

    switch (mode) {
        .singleThread => {
            vmode = VMode.initS();
            vm_core = Core.init(
                CoreId{ .master = {} },
                mode,
                runtime,
                null,
                try global_ctx.createVmLocal(),
            );
        },
        .multiThread => {
            vmode = try VMode.initM(cfg, runtime, runtime.gpa, global_ctx);
            errdefer vmode.deinit(runtime.gpa, global_ctx);

            vm_core = Core.init(
                CoreId{ .master = {} },
                mode,
                runtime,
                Core.CoreCtrl{ .master = vmode.m.master_ctrl },
                try global_ctx.createVmLocal(),
            );
        },
    }

    return .{
        .vm_core = vm_core,
        .vmode = vmode,
        .global_ctx = global_ctx,
        .runtime = runtime,
        .cfg = cfg,
    };
}

fn objToValueNumber(agent_heap: Memory.Heap(Agent), num: AST.Object) !Value {
    const numtype = try Special.parse(num.name);
    const agent_id = Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?;
    const agent = try agent_heap.allocOne();

    agent.* = .{ .id = agent_id, .ports = @splat(null) };
    agent.ports[0] = Value{ .special = numtype };

    return .{ .agent = agent };
}

fn objToValueAgent(self: *Self, obj: AST.Object) anyerror!Value {
    const portlist = obj.portlist.?;
    const agent_id = try self.runtime.agent_id_map.get(obj.name);
    const arity = try self.runtime.agent_arities.get(agent_id, portlist.len);
    const agent = try self.global_ctx.agent_heap.allocOne();

    agent.* = .{ .id = agent_id, .ports = @splat(null) };
    {
        var idx: u8 = 0;
        while (idx < arity) : (idx += 1) {
            // Temporary names are needed
            agent.ports[idx] = try self.objToValue(portlist[idx].val);
        }
    }

    return Value{ .agent = agent };
}

fn objToValueName(self: *Self, obj: AST.Object) !Value {
    const name = try self.global_ctx.name_heap.allocOne();

    name.* = .{ .port = null };
    try self.runtime.associated_names.put(obj.name, name);

    return .{ .name = name };
}

fn objToValue(
    self: *Self,
    obj: AST.Object,
) anyerror!Value {
    if (obj.isNumber()) {
        const num = obj.portlist.?[0].val;
        return objToValueNumber(self.global_ctx.agent_heap, num);
    }

    if (obj.portlist != null) {
        return self.objToValueAgent(obj);
    }

    if (self.runtime.associated_names.getPtr(obj.name)) |maybe_name| {
        if (maybe_name.*) |name| {
            maybe_name.* = null;
            if (name.port) |port| {
                defer self.global_ctx.name_heap.freeOne(name);

                return port;
            } else {
                return .{ .name = name };
            }
        } else {
            // Implicitly reusing
        }
    }

    return self.objToValueName(obj);
}

inline fn printStmt(self: *Self, name_to_print: AST.Name) !void {
    if (self.runtime.associated_names.get(name_to_print.val)) |maybe_name| {
        if (maybe_name) |name| {
            if (name.port) |port| {
                try Printing.tryPrint(self.runtime, self.runtime.gpa, port);
            } else {
                std.debug.print("<MOVED>\n", .{});
            }
        } else {
            std.debug.print("<EMPTY>\n", .{});
        }
    } else {
        std.debug.print("<UNDEFINED>\n", .{});
    }
}

inline fn freeStmt(self: *Self, names: []const AST.Name) !void {
    for (names) |wrapped_name| {
        const name = wrapped_name.val;
        if (self.runtime.associated_names.get(name)) |maybe_wire| {
            defer _ = self.runtime.associated_names.remove(name);
            if (maybe_wire) |wire| {
                const traversed = wire.traverseFree(self.vm_core.local_ctx.name_heap);
                defer self.vm_core.local_ctx.name_heap.freeOne(traversed);
                if (traversed.port) |port| {
                    // of course, there shouldn't be anything other than an agent
                    try Builtin.Eraser.erase(&self.vm_core, port.agent);
                }
            }
        } else {
            std.debug.print("Trying to free non-existent name {s}\n", .{name});
        }
    }
}

inline fn useStmt(self: *Self, import_path: []const u8) !void {
    const final_import_path = if (std.fs.path.isAbsolute(import_path)) try self.runtime.gpa.dupe(u8, import_path) else blk: {
        const dirname = std.fs.path.dirname(self.runtime.main_file.path).?;
        break :blk try std.fs.path.resolve(self.runtime.gpa, &.{ dirname, import_path });
    };
    defer self.runtime.gpa.free(final_import_path);

    try self.runtime.importer.import(final_import_path, self.runtime);
}

inline fn ruleStmt(self: *Self, rule: AST.Rule) !void {
    var diag: Diagnostic = .{};
    const compiled_rule = Instruction.compileRule(self.runtime, rule, &diag) catch |err| {
        if (Diagnostic.isHandledError(err)) {
            const message =
                try diag.getPrettyMessage(
                    self.runtime.main_file.contents,
                    self.runtime.main_file.tokens,
                    self.runtime.gpa,
                );
            defer self.runtime.gpa.free(message);
            std.debug.print("{s}", .{message});
            return error.CompilationError;
        } else {
            return err;
        }
    };
    if (BuildConfig.debug_printing.print_compiled_instructions) {
        try Instruction.debugPrintInstruction(self.runtime, compiled_rule[1]);
        const guard_size = 40;
        const guard: [guard_size]u8 = comptime @splat('=');
        std.debug.print("{s}\n", .{&guard});
    }
    if (compiled_rule[0] == .agents) {
        try self.runtime.rule_table.map.put(compiled_rule[0].agents, compiled_rule[1]);
    } else {
        try self.runtime.wildcard_table.put(compiled_rule[0].wildcard, compiled_rule[1]);
    }
}

inline fn prepareActivePair(self: *Self, ap: AST.ActivePair) !void {
    const lhs = try self.objToValue(ap.lhs.val);
    const rhs = try self.objToValue(ap.rhs.val);
    const eq = EquationUnnormalized{ .lhs = lhs, .rhs = rhs };

    try self.global_ctx.pushEquation(eq);
}

inline fn execActivePairVmCore(self: *Self) !void {
    try self.vm_core.runEquations();
}

inline fn execActivePairMultiCores(self: *Self) !void {
    if (self.cfg.warmup) {
        try self.vm_core.runEquations();
        self.global_ctx.balanceEquations();
        return;
    }

    // TODO:(kogora): multithread version
    try self.vmode.m.slots[0].core.runEquations();
}

inline fn execActivePairMode(self: *Self, mode: CoreMode) !void {
    switch (mode) {
        .singleThread => try self.execActivePairVmCore(),
        .multiThread => try self.execActivePairMultiCores(),
    }
}

inline fn execActivePair(self: *Self, mode: CoreMode) !void {
    if (BuildConfig.debug_printing.benchmark) {
        const start = std.Io.Clock.awake.now(self.runtime.io);
        try self.execActivePairMode(mode);
        const end = std.Io.Clock.awake.now(self.runtime.io);

        const duration = start.durationTo(end);
        std.debug.print("Time passed: {}s\n", .{@as(f64, @floatFromInt(duration.toMilliseconds())) / 1000.0});
    } else {
        try self.execActivePairMode(mode);
    }

    if (BuildConfig.debug_printing.print_memory_usage) {
        self.global_ctx.agent_heap.printUsage();
        self.global_ctx.name_heap.printUsage();
    }
}

pub fn startCores(self: *Self) !void {
    if (self.cfg.getMode() != .multiThread) {
        return;
    }

    const m: *VMode.Multi = &self.vmode.m;

    // TODO:(kogora) create logger for vm and cores
    std.debug.print("vm: starting {} core(s)\n", .{m.slots.len});

    if (m.waitUntil(.retry_on_fail, SlaveCtrlState.newborn, Slot.stateIs)) |fail_slot_idx| {
        std.debug.print("vm: <TODO msg> {} core\n", .{fail_slot_idx});
        return error.CoreNotNewborn;
    }

    try m.spawnCoreThreads();
    errdefer m.killCoreThreads();

    if (m.waitUntil(.exit_on_fail, SlaveCtrlState.applicant, Slot.stateReached)) |fail_slot_idx| {
        std.debug.print("vm: <TODO msg> {} core\n", .{fail_slot_idx});
        return error.CoreNotApplicant;
    }
}

pub fn stopCores(self: *Self) void {
    if (self.cfg.getMode() != .multiThread) {
        return;
    }

    const m: *VMode.Multi = &self.vmode.m;
    m.killCoreThreads();
}

pub fn runProgram(self: *Self, program: AST.Program) !void {
    for (program.statements) |statement| {
        switch (statement.val) {
            .print_stmt => |name_to_print| try self.printStmt(name_to_print),
            .free_stmt => |names| try self.freeStmt(names),
            .use_stmt => |import_path| try self.useStmt(import_path),
            .rule => |rule| try self.ruleStmt(rule),
            .active_pair => |ap| {
                try self.prepareActivePair(ap);
                try self.execActivePair(self.vm_core.mode);
            },
            else => unreachable,
        }
    }
}
