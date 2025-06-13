const std = @import("std");
const irq = @import("arch").irq;
const arch = @import("arch");

pub const UartError = error{ NotInitialized, BufferFull, BufferEmpty, Timeout };

pub const Port = enum(u16) {
    COM1 = 0x3F8,
    COM2 = 0x2F8,
    COM3 = 0x3E8,
    COM4 = 0x2E8,

    pub fn irqNumber(self: Port) u8 {
        return switch (self) {
            .COM1, .COM3 => 4,
            .COM2, .COM4 => 3,
        };
    }
};

pub const BaudRate = enum(u32) {
    B9600 = 9600,
    B19200 = 19200,
    B38400 = 38400,
    B57600 = 57600,
    B115200 = 115200,

    fn divisor(self: BaudRate) u16 {
        return @intCast(115200 / @intFromEnum(self));
    }
};

pub const Config = struct {
    port: Port = .COM1,
    baud_rate: BaudRate = .B115200,
    enable_interrupts: bool = true,
};

const Reg = enum(u8) {
    DATA = 0,    // Data Register
    IER = 1,     // Interrupt Enable Register
    FCR = 2,     // FIFO Control Register
    LCR = 3,     // Line Control
    MCR = 4,     // Modem Control
    LSR = 5,     // Line Status
    MSR = 6,     // Modem Status
};

const LCR = struct {
    const DATA_8_BITS = 0x03;
    const STOP_1_BIT = 0x00;
    const NO_PARITY = 0x00;
    const DLAB = 0x80;
};

const LSR = struct {
    const DATA_READY = 0x01;
    const THR_EMPTY = 0x20;
    const ERROR_MASK = 0x8E;
};

const IER = struct {
    const RX_READY = 0x01;
    const TX_EMPTY = 0x02;
    const LINE_STATUS = 0x04;
};

const FCR = struct {
    const ENABLE = 0x01;
    const CLEAR_RX = 0x02;
    const CLEAR_TX = 0x04;
    const TRIGGER_14 = 0xC0;
};

const MCR = struct {
    const DTR = 0x01;
    const RTS = 0x02;
    const OUT2 = 0x08; // Required for interrupts
};


pub const Uart = struct {

    const BUFFER_SIZE = 256;
    const BUFFER_MASK = BUFFER_SIZE - 1;

    base_port: u16,
    irq_num: u8,
    initialized: bool = false,

    // TX Buffer
    tx_buffer: [BUFFER_SIZE]u8 = undefined,
    tx_head: u8 = 0,
    tx_tail: u8 = 0,
    tx_busy: bool = false,

    // RX Buffer
    rx_buffer: [BUFFER_SIZE]u8 = undefined,
    rx_head: u8 = 0,
    rx_tail: u8 = 0,

    pub fn init(self: *Uart, config: Config) !void {
        self.base_port = @intFromEnum(config.port);
        self.irq_num = config.port.irqNumber();

        // disable interrupts
        self.writeReg(.IER, 0);

        // set baud rate
        const div = config.baud_rate.divisor();
        self.writeReg(.LCR, LCR.DLAB);
        self.writeReg(.DATA, @truncate(div));
        self.writeReg(.IER, @truncate(div >> 8));

        // 8N1, no break, no DLAB
        self.writeReg(.LCR, LCR.DATA_8_BITS | LCR.STOP_1_BIT | LCR.NO_PARITY);

        // enable FIFO, clear buffers
        self.writeReg(.FCR, FCR.ENABLE | FCR.CLEAR_RX | FCR.CLEAR_TX | FCR.TRIGGER_14);

        // enable DTR, RTS, OUT2
        self.writeReg(.MCR, MCR.DTR | MCR.RTS | MCR.OUT2);

        // Clear any pending data
        _ = self.readReg(.LSR);
        _ = self.readReg(.DATA);

        // reset buffers
        self.tx_head = 0;
        self.tx_tail = 0;
        self.tx_busy = false;
        self.rx_head = 0;
        self.rx_tail = 0;

        if (config.enable_interrupts) {
            try irq.irq.registerIrq(self.irq_num, uartHandler);

            // Enable RX and line status interrupts
            self.writeReg(.IER, IER.RX_READY | IER.LINE_STATUS);
        }

        self.initialized = true;
    }

    pub fn deinit(self: *Uart) void {
        if (!self.initialized) return;

        self.writeReg(.IER, 0); // Disable interrupts
        irq.irq.unregisterIrq(self.irq_num) catch {};
        self.initialized = false;
    }

    pub fn write(self: *Uart, data: []const u8) UartError!usize {
        if (!self.initialized) return UartError.NotInitialized;
        if (data.len == 0) return 0;

        var written: usize = 0;
        irq.irq.disable();
        defer irq.irq.enable();

        // Buffer the data
        for (data) |byte| {
            if (self.txFull()) break;

            self.tx_buffer[self.tx_head] = byte;
            self.tx_head = (self.tx_head + 1) & BUFFER_MASK;
            written += 1;
        }

        // Start transmission if not busy
        self.startTx();
        return written;
    }

    pub fn read(self: *Uart, buffer: []u8) UartError!usize {
        if (!self.initialized) return UartError.NotInitialized;
        if (buffer.len == 0) return 0;

        var read_count: usize = 0;
        irq.irq.disable();
        defer irq.irq.enable();

        while (read_count < buffer.len and !self.rxEmpty()) {
            buffer[read_count] = self.rx_buffer[self.rx_tail];
            self.rx_tail = (self.rx_tail + 1) & BUFFER_MASK;
            read_count += 1;
        }

        return read_count;
    }

    pub fn readByte(self: *Uart) UartError!u8 {
        irq.irq.disable();
        var byte: [1]u8 = undefined;
        const count = try self.read(&byte);
        irq.irq.enable();
        return if (count > 0) byte[0] else UartError.BufferEmpty;
    }

    pub fn txReady(self: *const Uart) bool {
        return !self.txFull();
    }

    pub fn rxReady(self: *const Uart) bool {
        return !self.rxEmpty();
    }

    pub fn flush(self: *Uart) UartError!void {
        var timeout: u32 = 100000;
        while (!self.txEmpty() and timeout > 0) {
            self.startTx(); // Handle missed interrupts
            timeout -= 1;
            asm volatile ("hlt");
        }
        return if (timeout == 0) UartError.Timeout else {};
    }

    fn writeReg(self: *const Uart, reg: Reg, value: u8) void {
        irq.irq.disable();
        const port = self.base_port + @intFromEnum(reg);
        arch.outb(port, value);
        irq.irq.enable();
    }

    fn readReg(self: *const Uart, reg: Reg) u8 {
        const port = self.base_port + @intFromEnum(reg);
        return arch.inb(port);
    }

    fn txEmpty(self: *const Uart) bool {
        return self.tx_head == self.tx_tail;
    }

    fn txFull(self: *const Uart) bool {
        return ((self.tx_head + 1) & BUFFER_MASK) == self.tx_tail;
    }

    fn rxEmpty(self: *const Uart) bool {
        return self.rx_head == self.rx_tail;
    }

    fn rxFull(self: *const Uart) bool {
        return ((self.rx_head + 1) & BUFFER_MASK) == self.rx_tail;
    }

    fn startTx(self: *Uart) void {
        if (self.txEmpty() or self.tx_busy) return;

        const lsr = self.readReg(.LSR);
        if ((lsr & LSR.THR_EMPTY) == 0) return;

        // Send next byte
        const byte = self.tx_buffer[self.tx_tail];
        self.tx_tail = (self.tx_tail + 1) & BUFFER_MASK;
        self.writeReg(.DATA, byte);
        self.tx_busy = true;

        // Enable TX interrupt if we have more data
        if (!self.txEmpty()) {
            const ier = self.readReg(.IER);
            self.writeReg(.IER, ier | IER.TX_EMPTY);
        }
    }

    fn handleInterrupt(self: *Uart) void {
        // TODO @(dleiferives,fa9bb658-556e-4035-98f8-2a41656afa2d): check rflags
        // to make sure that interrupts are not enabled again during an isr ~#
        irq.irq.disable();
        const lsr = self.readReg(.LSR);

        // Handle errors
        if ((lsr & LSR.ERROR_MASK) != 0) {
            _ = self.readReg(.DATA); // Clear error
        }

        // Handle received data
        if ((lsr & LSR.DATA_READY) != 0) {
            const byte = self.readReg(.DATA);
            if (!self.rxFull()) {
                self.rx_buffer[self.rx_head] = byte;
                self.rx_head = (self.rx_head + 1) & BUFFER_MASK;
            }
        }

        // Handle transmit empty
        if ((lsr & LSR.THR_EMPTY) != 0) {
            self.tx_busy = false;
            if (!self.txEmpty()) {
                self.startTx();
            } else {
                // Disable TX interrupt
                const ier = self.readReg(.IER);
                var tx_empty_mask: u8 = IER.TX_EMPTY;
                self.writeReg(.IER, ier & ~tx_empty_mask);
                _ = &tx_empty_mask; // Prevent unused variable warning
            }
        }
        if (!arch.cpu.in_interrupt()) {
            irq.irq.enable();
        }
    }
};

var com1: Uart = .{
    .base_port = @intFromEnum(Port.COM1),
    .irq_num = Port.COM1.irqNumber(),
};

fn uartHandler(frame: *irq.InterruptFrame) void {
    _ = frame;
    com1.handleInterrupt();
}

pub fn init(config: Config) !void {
    return com1.init(config);
}

pub fn deinit() void {
    com1.deinit();
}

pub fn write(data: []const u8) UartError!usize {
    return com1.write(data);
}

pub fn read(buffer: []u8) UartError!usize {
    return com1.read(buffer);
}

pub fn readByte() UartError!u8 {
    return com1.readByte();
}

pub fn print(comptime fmt: []const u8, args: anytype) UartError!void {
    _ = args;
    _ = try com1.write(fmt);
}

pub fn txReady() bool {
    return com1.txReady();
}

pub fn rxReady() bool {
    return com1.rxReady();
}

pub fn flush() UartError!void {
    return com1.flush();
}

pub const Writer = struct {
    pub const Error = UartError;

    pub fn write(_: Writer, bytes: []const u8) Error!usize {
        return com1.write(bytes);
    }

    pub fn writeAll(self: Writer, bytes: []const u8) Error!void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const written = try self.write(remaining);
            remaining = remaining[written..];
        }
    }
};

pub const Reader = struct {
    pub const Error = UartError;

    pub fn read(_: Reader, buffer: []u8) Error!usize {
        return com1.read(buffer);
    }
};

pub fn writer() Writer {
    return .{};
}

pub fn reader() Reader {
    return .{};
}
