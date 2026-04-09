// tui.zig — Declarative TUI component library.
//
// Components are structs initialized with properties, rendered into Rects.
// Compose them with Element type-erasure and VStack/HStack containers.
//
// Example:
//
//   const tui = @import("tui.zig");
//
//   // Declare components
//   var input = tui.Input{ .focused = true, .prompt = "> " };
//   var list = tui.ScrollList{ .items = items, .selected = 0 };
//
//   // Layout
//   const screen = tui.Rect.fromSize(cols, rows);
//   var rects: [2]tui.Rect = undefined;
//   _ = screen.splitRows(&.{ tui.Size{ .fixed = 1 }, tui.Size{ .flex = 1 } }, &rects);
//
//   // Render
//   var buf: [16384]u8 = undefined;
//   var pos: usize = 0;
//   pos += input.render(buf[pos..], rects[0]);
//   pos += list.render(buf[pos..], rects[1]);
//   writer.writeAll(buf[0..pos]);
//
//   // Or compose with layout containers:
//   const stack = tui.VStack{
//       .sizes = &.{ tui.Size{ .fixed = 1 }, tui.Size{ .flex = 1 } },
//       .children = &.{ input.element(), list.element() },
//   };
//   const n = stack.element().render(&buf, screen);

// Core types
pub const Rect = @import("tui/core.zig").Rect;
pub const Size = @import("tui/core.zig").Size;
pub const Element = @import("tui/core.zig").Element;
pub const Action = @import("tui/core.zig").Action;
pub const VStack = @import("tui/core.zig").VStack;
pub const HStack = @import("tui/core.zig").HStack;
pub const max_children = @import("tui/core.zig").max_children;
pub const pad = @import("tui/core.zig").pad;
pub const clipText = @import("tui/core.zig").clipText;
pub const padLine = @import("tui/core.zig").padLine;
pub const renderScrollbar = @import("tui/core.zig").renderScrollbar;
pub const isWordSep = @import("tui/core.zig").isWordSep;
pub const clipTextUnicode = @import("tui/core.zig").clipTextUnicode;
pub const displayWidth = @import("tui/core.zig").displayWidth;
pub const unicode = @import("tui/core.zig").unicode;

// Screen (double-buffered rendering)
pub const Screen = @import("tui/Screen.zig");

// Fuzzy filter engine
pub const FuzzyFilter = @import("tui/FuzzyFilter.zig").FuzzyFilter;
pub const FuzzyResult = @import("tui/FuzzyFilter.zig").Result;

// Components
pub const Text = @import("tui/Text.zig");
pub const Input = @import("tui/Input.zig");
pub const ScrollList = @import("tui/ScrollList.zig");
pub const Table = @import("tui/Table.zig");
pub const Menu = @import("tui/Menu.zig");
pub const Popup = @import("tui/Popup.zig");
pub const FuzzyList = @import("tui/FuzzyList.zig");

pub const Box = @import("tui/Box.zig").Box;
pub const Separator = @import("tui/Box.zig").Separator;
pub const StatusBar = @import("tui/Box.zig").StatusBar;

// Pull in all sub-module tests
test {
    _ = @import("tui/core.zig");
    _ = @import("tui/unicode.zig");
    _ = @import("tui/Screen.zig");
    _ = @import("tui/FuzzyFilter.zig");
    _ = @import("tui/Text.zig");
    _ = @import("tui/Box.zig");
    _ = @import("tui/Input.zig");
    _ = @import("tui/ScrollList.zig");
    _ = @import("tui/Table.zig");
    _ = @import("tui/Menu.zig");
    _ = @import("tui/Popup.zig");
    _ = @import("tui/FuzzyList.zig");
}
