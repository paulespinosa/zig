/// Represents export trie used in MachO executables and dynamic libraries.
/// The purpose of an export trie is to encode as compactly as possible all
/// export symbols for the loader `dyld`.
/// The export trie encodes offset and other information using ULEB128
/// encoding, and is part of the __LINKEDIT segment.
///
/// Description from loader.h:
///
/// The symbols exported by a dylib are encoded in a trie. This is a compact
/// representation that factors out common prefixes. It also reduces LINKEDIT pages
/// in RAM because it encodes all information (name, address, flags) in one small,
/// contiguous range. The export area is a stream of nodes. The first node sequentially
/// is the start node for the trie.
///
/// Nodes for a symbol start with a uleb128 that is the length of the exported symbol
/// information for the string so far. If there is no exported symbol, the node starts
/// with a zero byte. If there is exported info, it follows the length.
///
/// First is a uleb128 containing flags. Normally, it is followed by a uleb128 encoded
/// offset which is location of the content named by the symbol from the mach_header
/// for the image. If the flags is EXPORT_SYMBOL_FLAGS_REEXPORT, then following the flags
/// is a uleb128 encoded library ordinal, then a zero terminated UTF8 string. If the string
/// is zero length, then the symbol is re-export from the specified dylib with the same name.
/// If the flags is EXPORT_SYMBOL_FLAGS_STUB_AND_RESOLVER, then following the flags is two
/// uleb128s: the stub offset and the resolver offset. The stub is used by non-lazy pointers.
/// The resolver is used by lazy pointers and must be called to get the actual address to use.
///
/// After the optional exported symbol information is a byte of how many edges (0-255) that
/// this node has leaving it, followed by each edge. Each edge is a zero terminated UTF8 of
/// the addition chars in the symbol, followed by a uleb128 offset for the node that edge points to.
const Trie = @This();

const std = @import("std");
const mem = std.mem;
const leb = std.debug.leb;
const log = std.log.scoped(.link);
const Allocator = mem.Allocator;

pub const Symbol = struct {
    name: []const u8,
    offset: u64,
    export_flags: u64,
};

const Edge = struct {
    from: *Node,
    to: *Node,
    label: []const u8,

    fn deinit(self: *Edge, alloc: *Allocator) void {
        self.to.deinit(alloc);
        alloc.destroy(self.to);
        self.from = undefined;
        self.to = undefined;
    }
};

const Node = struct {
    export_flags: ?u64 = null,
    offset: ?u64 = null,
    edges: std.ArrayListUnmanaged(Edge) = .{},

    fn deinit(self: *Node, alloc: *Allocator) void {
        for (self.edges.items) |*edge| {
            edge.deinit(alloc);
        }
        self.edges.deinit(alloc);
    }

    fn put(self: *Node, alloc: *Allocator, fromEdge: ?*Edge, prefix: usize, label: []const u8) !*Node {
        // Traverse all edges.
        for (self.edges.items) |*edge| {
            const match = mem.indexOfDiff(u8, edge.label, label) orelse return self; // Got a full match, don't do anything.
            if (match - prefix > 0) {
                // If we match, we advance further down the trie.
                return edge.to.put(alloc, edge, match, label);
            }
        }

        if (fromEdge) |from| {
            if (mem.eql(u8, from.label, label[0..prefix])) {
                if (prefix == label.len) return self;
            } else {
                // Fixup nodes. We need to insert an intermediate node between
                // from.to and self.
                // Is: A -> B
                // Should be: A -> C -> B
                const mid = try alloc.create(Node);
                mid.* = .{};
                const to_label = from.label;
                from.to = mid;
                from.label = label[0..prefix];

                try mid.edges.append(alloc, .{
                    .from = mid,
                    .to = self,
                    .label = to_label,
                });

                if (prefix == label.len) return self; // We're done.

                const new_node = try alloc.create(Node);
                new_node.* = .{};

                try mid.edges.append(alloc, .{
                    .from = mid,
                    .to = new_node,
                    .label = label,
                });

                return new_node;
            }
        }

        // Add a new edge.
        const node = try alloc.create(Node);
        node.* = .{};

        try self.edges.append(alloc, .{
            .from = self,
            .to = node,
            .label = label,
        });

        return node;
    }

    fn writeULEB128Mem(self: Node, alloc: *Allocator, buffer: *std.ArrayListUnmanaged(u8)) Trie.WriteError!void {
        if (self.offset) |offset| {
            // Terminal node info: encode export flags and vmaddr offset of this symbol.
            var info_buf_len: usize = 0;
            var info_buf: [@sizeOf(u64) * 2]u8 = undefined;
            info_buf_len += try leb.writeULEB128Mem(info_buf[0..], self.export_flags.?);
            info_buf_len += try leb.writeULEB128Mem(info_buf[info_buf_len..], offset);

            // Encode the size of the terminal node info.
            var size_buf: [@sizeOf(u64)]u8 = undefined;
            const size_buf_len = try leb.writeULEB128Mem(size_buf[0..], info_buf_len);

            // Now, write them to the output buffer.
            try buffer.ensureCapacity(alloc, buffer.items.len + info_buf_len + size_buf_len);
            buffer.appendSliceAssumeCapacity(size_buf[0..size_buf_len]);
            buffer.appendSliceAssumeCapacity(info_buf[0..info_buf_len]);
        } else {
            // Non-terminal node is delimited by 0 byte.
            try buffer.append(alloc, 0);
        }
        // Write number of edges (max legal number of edges is 256).
        try buffer.append(alloc, @intCast(u8, self.edges.items.len));

        var node_offset_info: [@sizeOf(u8)]u64 = undefined;
        for (self.edges.items) |edge, i| {
            // Write edges labels leaving out space in-between to later populate
            // with offsets to each node.
            try buffer.ensureCapacity(alloc, buffer.items.len + edge.label.len + 1 + @sizeOf(u64)); // +1 to account for null-byte
            buffer.appendSliceAssumeCapacity(edge.label);
            buffer.appendAssumeCapacity(0);
            node_offset_info[i] = buffer.items.len;
            const padding = [_]u8{0} ** @sizeOf(u64);
            buffer.appendSliceAssumeCapacity(padding[0..]);
        }

        for (self.edges.items) |edge, i| {
            const offset = buffer.items.len;
            try edge.to.writeULEB128Mem(alloc, buffer);
            // We can now populate the offset to the node pointed by this edge.
            // TODO this is not the approach taken by `ld64` which does several iterations
            // to close the gap between the space encoding the offset to the node pointed
            // by this edge. However, it seems that as long as we are contiguous, the padding
            // introduced here should not influence the performance of `dyld`. I'm leaving
            // this TODO here though as a reminder to re-investigate in the future and especially
            // when we start working on dylibs in case `dyld` refuses to cooperate and/or the
            // performance is noticably sufferring.
            // Link to official impl: https://opensource.apple.com/source/ld64/ld64-123.2.1/src/abstraction/MachOTrie.hpp
            var offset_buf: [@sizeOf(u64)]u8 = undefined;
            const offset_buf_len = try leb.writeULEB128Mem(offset_buf[0..], offset);
            mem.copy(u8, buffer.items[node_offset_info[i]..], offset_buf[0..offset_buf_len]);
        }
    }
};

root: Node,

/// Insert a symbol into the trie, updating the prefixes in the process.
/// This operation may change the layout of the trie by splicing edges in
/// certain circumstances.
pub fn put(self: *Trie, alloc: *Allocator, symbol: Symbol) !void {
    const node = try self.root.put(alloc, null, 0, symbol.name);
    node.offset = symbol.offset;
    node.export_flags = symbol.export_flags;
}

pub const WriteError = error{ OutOfMemory, NoSpaceLeft };

/// Write the trie to a buffer ULEB128 encoded.
pub fn writeULEB128Mem(self: Trie, alloc: *Allocator, buffer: *std.ArrayListUnmanaged(u8)) WriteError!void {
    return self.root.writeULEB128Mem(alloc, buffer);
}

pub fn deinit(self: *Trie, alloc: *Allocator) void {
    self.root.deinit(alloc);
}

test "Trie basic" {
    const testing = @import("std").testing;
    var gpa = testing.allocator;

    var trie: Trie = .{
        .root = .{},
    };
    defer trie.deinit(gpa);

    // root
    testing.expect(trie.root.edges.items.len == 0);

    // root --- _st ---> node
    try trie.put(gpa, .{
        .name = "_st",
        .offset = 0,
        .export_flags = 0,
    });
    testing.expect(trie.root.edges.items.len == 1);
    testing.expect(mem.eql(u8, trie.root.edges.items[0].label, "_st"));

    {
        // root --- _st ---> node --- _start ---> node
        try trie.put(gpa, .{
            .name = "_start",
            .offset = 0,
            .export_flags = 0,
        });
        testing.expect(trie.root.edges.items.len == 1);

        const nextEdge = &trie.root.edges.items[0];
        testing.expect(mem.eql(u8, nextEdge.label, "_st"));
        testing.expect(nextEdge.to.edges.items.len == 1);
        testing.expect(mem.eql(u8, nextEdge.to.edges.items[0].label, "_start"));
    }
    {
        // root --- _ ---> node --- _st ---> node --- _start ---> node
        //                  |
        //                  |   --- _main ---> node
        try trie.put(gpa, .{
            .name = "_main",
            .offset = 0,
            .export_flags = 0,
        });
        testing.expect(trie.root.edges.items.len == 1);

        const nextEdge = &trie.root.edges.items[0];
        testing.expect(mem.eql(u8, nextEdge.label, "_"));
        testing.expect(nextEdge.to.edges.items.len == 2);
        testing.expect(mem.eql(u8, nextEdge.to.edges.items[0].label, "_st"));
        testing.expect(mem.eql(u8, nextEdge.to.edges.items[1].label, "_main"));

        const nextNextEdge = &nextEdge.to.edges.items[0];
        testing.expect(mem.eql(u8, nextNextEdge.to.edges.items[0].label, "_start"));
    }
}
