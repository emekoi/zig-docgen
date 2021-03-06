//! A tokenizer for zig.
//!
//! This is uses the current compiler tokenizer as a partial reference, but the
//! overall structure is quite different and should be a bit easier to follow.
//!
//! This also keeps track of comment information as tokens for documentation generation.
// TODO: Track sufficient indentation information in blocks. If the token is the first in a line,
// mark it with an integer specifying how many tabs/spaces preceed it.

const std = @import("std");
const debug = std.debug;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const HashMap = std.HashMap;

/// A TokenId represents a kind of token. It will also hold its associated data if present.
const TokenId = enum.{
    Ampersand,
    Arrow,
    AtSign,
    Bang,
    BinOr,
    BinXor,
    BitAndEq,
    BitOrEq,
    BitShiftLeft,
    BitShiftLeftEq,
    BitShiftRight,
    BitShiftRightEq,
    BitXorEq,
    CharLiteral,
    CmpEq,
    CmpGreaterOrEq,
    CmpGreaterThan,
    CmpLessOrEq,
    CmpLessThan,
    CmpNotEq,
    Colon,
    Comment,
    Comma,
    Dash,
    DivEq,
    DocComment,
    Dot,
    DoubleQuestion,
    Ellipsis2,
    Ellipsis3,
    Eof,
    Eq,
    FatArrow,
    FloatLiteral,
    IntLiteral,
    KeywordAlign,
    KeywordAnd,
    KeywordAsm,
    KeywordBreak,
    KeywordColdCC,
    KeywordCompTime,
    KeywordConst,
    KeywordContinue,
    KeywordDefer,
    KeywordElse,
    KeywordEnum,
    KeywordError,
    KeywordErrDefer,
    KeywordExport,
    KeywordExtern,
    KeywordFalse,
    KeywordFn,
    KeywordFor,
    KeywordGoto,
    KeywordIf,
    KeywordInline,
    KeywordNakedCC,
    KeywordNoAlias,
    KeywordNull,
    KeywordOr,
    KeywordPacked,
    KeywordPub,
    KeywordReturn,
    KeywordStdcallCC,
    KeywordStruct,
    KeywordSwitch,
    KeywordTest,
    KeywordThis,
    KeywordTrue,
    KeywordUndefined,
    KeywordUnion,
    KeywordUnreachable,
    KeywordUse,
    KeywordVar,
    KeywordVolatile,
    KeywordWhile,
    LBrace,
    LBracket,
    LParen,
    Maybe,
    MaybeAssign,
    MinusEq,
    MinusPercent,
    MinusPercentEq,
    MultiLineStringLiteral,
    ModEq,
    ModuleDocComment,
    NumberSign,
    Percent,
    PercentDot,
    PercentPercent,
    Plus,
    PlusEq,
    PlusPercent,
    PlusPercentEq,
    PlusPlus,
    RBrace,
    RBracket,
    RParen,
    Semicolon,
    Slash,
    Star,
    StarStar,
    StringLiteral,
    Symbol,
    Tilde,
    TimesEq,
    TimesPercent,
    TimesPercentEq,
};

const Kw = struct.{
    name: []const u8,
    id: TokenId,

    pub fn new(name: []const u8, id: TokenId) Kw {
        return Kw.{
            .name = name,
            .id = id,
        };
    }
};

const keywords = []Kw.{
    Kw.new("align", TokenId.KeywordAlign),
    Kw.new("and", TokenId.KeywordAnd),
    Kw.new("asm", TokenId.KeywordAsm),
    Kw.new("break", TokenId.KeywordBreak),
    Kw.new("coldcc", TokenId.KeywordColdCC),
    Kw.new("comptime", TokenId.KeywordCompTime),
    Kw.new("const", TokenId.KeywordConst),
    Kw.new("continue", TokenId.KeywordContinue),
    Kw.new("defer", TokenId.KeywordDefer),
    Kw.new("else", TokenId.KeywordElse),
    Kw.new("enum", TokenId.KeywordEnum),
    Kw.new("error", TokenId.KeywordError),
    Kw.new("errdefer", TokenId.KeywordErrDefer),
    Kw.new("extern", TokenId.KeywordExtern),
    Kw.new("false", TokenId.KeywordFalse),
    Kw.new("fn", TokenId.KeywordFn),
    Kw.new("for", TokenId.KeywordFor),
    Kw.new("if", TokenId.KeywordIf),
    Kw.new("inline", TokenId.KeywordInline),
    Kw.new("nakedcc", TokenId.KeywordNakedCC),
    Kw.new("noalias", TokenId.KeywordNoAlias),
    Kw.new("null", TokenId.KeywordNull),
    Kw.new("or", TokenId.KeywordOr),
    Kw.new("packed", TokenId.KeywordPacked),
    Kw.new("pub", TokenId.KeywordPub),
    Kw.new("return", TokenId.KeywordReturn),
    Kw.new("stdcallcc", TokenId.KeywordStdcallCC),
    Kw.new("struct", TokenId.KeywordStruct),
    Kw.new("switch", TokenId.KeywordSwitch),
    Kw.new("test", TokenId.KeywordTest),
    Kw.new("true", TokenId.KeywordTrue),
    Kw.new("undefined", TokenId.KeywordUndefined),
    Kw.new("union", TokenId.KeywordUnion),
    Kw.new("unreachable", TokenId.KeywordUnreachable),
    Kw.new("use", TokenId.KeywordUse),
    Kw.new("var", TokenId.KeywordVar),
    Kw.new("volatile", TokenId.KeywordVolatile),
    Kw.new("while", TokenId.KeywordWhile),
};

fn getKeywordId(symbol: []const u8) ?TokenId {
    for (keywords) |kw| {
        if (std.mem.eql(u8, kw.name, symbol)) {
            return kw.id;
        }
    }
    return null;
}

const IntOrFloat = enum.{
    Int: u64,   // TODO: Convert back to u128 when __floatuntidf implemented.
    Float: f64,
};

const DigitError = error.{
    BadValueForRadix,
    ValueOutOfRange,
};

/// Returns the digit value of the specified character under the specified radix.
///
/// If the value is too large, an error is returned.
fn getDigitValueForRadix(comptime radix: u8, c: u8) DigitError!u8 {
    const value = switch (c) {
        '0' ... '9' => |x| x - '0' ,
        'a' ... 'z' => |x| x - 'a' + 10 ,
        'A' ... 'Z' => |x| x - 'A' + 10 ,
        else => return error.ValueOutOfRange,
    };

    if (value < radix) {
        return value;
    } else {
        return error.BadValueForRadix;
    }
}

/// Extra data associated with a particular token.
pub const TokenData = enum.{
    InternPoolRef: []const u8,
    Integer: u64,
    Float: f64, // TODO: Could change to an f128 (or arbitrary-precision) when printing works
    Char: u8,
    Error: error,
};

fn printCharEscaped(c: u8) !void {
    const printf = std.io.stdout.printf;

    return switch (c) {
        '\r' => try printf("\\r"),
        '\t' => try printf("\\t"),
        '\n' => try printf("\\n"),
        '\\' => try printf("\\\\"),
        else => try printf("{c}", c),
    };
}

/// A Token consists of a type/id and an associated location/span within the source file.
pub const Token = struct.{
    id: TokenId,
    span: Span,
    data: ?TokenData,

    pub fn print(self: *const Token) !void {
        const printf = std.io.stdout.printf;

        return try printf("{}:{} {}",
            self.span.start_line,
            self.span.start_column,
            @enumTagName(self.id)
        );

        if (self.data) |inner| {
            return try printf(" (");
            switch (inner) {
                TokenData.InternPoolRef => |p_ref| {
                    for (p_ref) |c| {
                        return try printCharEscaped(c);
                    }
                },
                TokenData.Integer => |i| {
                    return try printf("{}", i);
                },
                TokenData.Float => |f| {
                    return try printf("{}", f);
                },
                TokenData.Char => |c| {
                    return try printCharEscaped(c);
                },
                TokenData.Error => |e| {
                    return try printf("{}", @errorName(e));
                },
            }
            return try printf(")");
        }

        return try printf("\n");
    }
};

/// A Span represents a contiguous sequence (byte-wise) of a source file.
pub const Span = struct.{
    start_byte: usize,
    end_byte: usize,
    start_line: usize,
    start_column: usize,
};

const TokenizerError = error.{
    UnicodeCharCodeOutOfRange,
    NewlineInStringLiteral,
    InvalidCharacter,
    InvalidCharacterAfterBackslash,
    MissingCharLiteralData,
    ExtraCharLiteralData,
    EofWhileParsingLiteral,
};

fn u8eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// The second value is heap allocated.
pub const InternPool = HashMap([]const u8, []const u8, std.mem.hash_slice_u8, u8eql);

pub const Tokenizer = struct.{
    const Self = @This();

    tokens: ArrayList(Token),
    lines: ArrayList(usize),
    intern_pool: InternPool,
    errors: ArrayList(Token),
    consumed: bool,
    allocator: &Allocator,

    c_token: ?Token,
    c_byte: usize,
    c_line: usize,
    c_column : usize,
    c_buf: []const u8,

    /// Initialize a new tokenizer to handle the specified input buffer.
    pub fn init(allocator: *Allocator) Self {
        return Self.{
            .tokens = ArrayList(Token).init(allocator),
            .lines = ArrayList(usize).init(allocator),
            .intern_pool = InternPool.init(allocator),
            .errors = ArrayList(Token).init(allocator),
            .consumed = false,
            .allocator = allocator,

            .c_token = null,
            .c_byte = 0,
            .c_line = 1,
            .c_column = 1,
            .c_buf = undefined,
        };
    }

    /// Deinitialize the internal tokenizer state.
    pub fn deinit(self: *Self) void {
        self.tokens.deinit();
        self.lines.deinit();
        self.intern_pool.deinit();
        self.errors.deinit();
    }

    /// Returns the next byte in the buffer and advances our position.
    ///
    /// If we have reached the end of the stream, null is returned.
    fn nextByte(self: *Self) ?u8 {
        if (self.c_byte >= self.c_buf.len) {
            return null;
        } else {
            const i = self.c_byte;
            self.bump(1);
            return self.c_buf[i];
        }
    }

    /// Mark the current position as the start of a token.
    fn beginToken(self: *Self) void {
        self.c_token = Token.{
            .id = undefined,
            .span = Span.{
                .start_byte = self.c_byte,
                .end_byte = undefined,
                .start_line = self.c_line,
                .start_column = self.c_column,
            },
            .data = null,
        };
    }

    /// Set the id of the current token.
    fn setToken(self: *Self, id: TokenId) void {
        self.c_token.?.*.id = id;
    }

    /// Mark the current position as the end of the current token.
    ///
    /// A token must have been previously set using beginToken.
    fn endToken(self: *Self) !void {
        var c = self.c_token.?;
        c.span.end_byte = self.c_byte + 1;
        return try self.tokens.append(c);
        self.c_token = null;
    }

    /// Set the data field for a ArrayList(u8) field using the internal InternPool.
    ///
    /// This takes ownership of the underlying memory.
    fn setInternToken(self: *Self, data: *ArrayList(u8)) !void {
        const ref = if (self.intern_pool.get(data.toSliceConst())) |entry| {
            data.deinit();
            return entry.value;
        } else {
            _ = try self.intern_pool.put(data.toSliceConst(), data.toSliceConst());
            data.toSliceConst();
        };

        self.c_token.?.*.data = TokenData.InternPoolRef.{ ref };
    }

    /// Mark the current position as the end of a token and set it to a new id.
    fn setEndToken(self: *Self, id: TokenId) !void {
        self.setToken(id);
        return try self.endToken();
    }

    /// Peek at the character n steps ahead in the stream.
    ///
    /// If no token is found, returns the null byte.
    // TODO: Return an actual null? Much more verbose during usual parsing though.
    fn peek(self: *Self, comptime i: usize) u8 {
        if (self.c_byte + i >= self.c_buf.len) {
            return 0;
        } else {
            return self.c_buf[self.c_byte + i];
        }
    }

    /// Advance the cursor location by n steps.
    ///
    /// Bumping past the end of the buffer has no effect.
    fn bump(self: *Self, comptime i: usize) void {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (self.c_byte >= self.c_buf.len) {
                break;
            }

            if (self.peek(0) == '\n') {
                self.c_line += 1;
                self.c_column = 1;
            } else {
                self.c_column += 1;
            }
            self.c_byte += 1;
        }
    }

    // Actual processing helper routines.

    /// Consume an entire integer of the specified radix.
    fn consumeInteger(self: &Self, comptime radix: u8, init_value: u64) !u64 {
        var number = init_value;
        var overflowed = false;

        while (true) {
            const ch = self.peek(0);

            const value = if (getDigitValueForRadix(radix, ch)) |ok| {
                self.bump(1);

                // TODO: Need arbitrary precision to handle this overflow
                if (!overflowed) {
                    {
                        const previous_number = number;
                        if (@mulWithOverflow(u64, number, radix, &number)) {
                            // Revert to previous as this will give partially accurate values for
                            // floats at least.
                            number = previous_number;
                            overflowed = true;
                        }
                    }

                    {
                        const previous_number = number;
                        if (@addWithOverflow(u64, number, ok, &number)) {
                            number = previous_number;
                            overflowed = true;
                        }
                    }
                }
            } else |_| {
                return number;
            };
        }
    }

    /// Consumes a decimal exponent for a float.
    ///
    /// This includes an optional leading +, -.
    fn consumeFloatExponent(self: &Self, exponent_sign: &bool) !u64 {
        *exponent_sign = switch (self.peek(0)) {
            '-' => {
                self.bump(1);
                true;
            },
            '+' => {
                self.bump(1);
                false;
            },
            else => {
                false;
            },
        };

        return self.consumeInteger(10, 0);
    }

    /// Process a float with the specified radix starting from the decimal part.
    ///
    /// The non-decimal portion should have been processed by `consumeNumber`.
    fn consumeFloatFractional(self: &Self, comptime radix: u8, whole_part: u64) !f64 {
        debug.assert(radix == 10 or radix == 16);

        var number = try self.consumeInteger(radix, 0);

        switch (self.peek(0)) {
            'e', 'E' => {
                self.bump(1);

                var is_neg_exp: bool = undefined;
                var exp = try self.consumeFloatExponent(&is_neg_exp);

                const whole = if (number != 0) {
                    const digit_count = usize(1 + std.math.log10(number));
                    var frac_part = f64(number);

                    var i: usize = 0;
                    while (i < digit_count) : (i += 1) {
                        frac_part /= 10;
                    }

                    f64(whole_part) + frac_part;
                } else {
                    f64(whole_part);
                };

                if (is_neg_exp) {
                    return whole / std.math.pow(f64, 10, f64(exp));
                } else {
                    return whole * std.math.pow(f64, 10, f64(exp));
                }
            },

            'p', 'P' => {
                self.bump(1);

                var is_neg_exp: bool = undefined;
                var exp = try self.consumeFloatExponent(&is_neg_exp);

                const whole = if (number != 0) {
                    const digit_count = usize(1 + std.math.log(f64, 16, f64(number)));
                    var frac_part = f64(number);

                    var i: usize = 0;
                    while (i < digit_count) : (i += 1) {
                        frac_part /= 10;
                    }

                    f64(whole_part) + frac_part;
                } else {
                    f64(whole_part);
                };

                if (is_neg_exp) {
                    return whole / std.math.pow(f64, 2, f64(exp));
                } else {
                    return whole * std.math.pow(f64, 2, f64(exp));
                }
            },

            else => {
                const frac_part = f64(number) / (std.math.pow(f64, f64(10), f64(1 + std.math.log10(number))));
                return f64(whole_part) + frac_part;
            },
        }
    }

    /// Processes integer with the specified radix.
    ///
    /// The integer will be represented by an unsigned value.
    ///
    /// This will only modify the current stream position.
    //
    // TODO: Use big integer generally improve here.
    fn consumeNumber(self: &Self, comptime radix: u8, init_value: ?u8) !IntOrFloat {
        var init_number: u64 = if (init_value) |v| {
            try getDigitValueForRadix(radix, v);
        } else {
            0;
        };

        const number = try self.consumeInteger(radix, init_number);

        // TODO: Need to be separated by a non-symbol token.
        // Raise an error if we find a non-alpha-numeric that doesn't fit. Do at caller?
        //
        // i.e. 1230174ADAKHJ is invalid.
        if (self.peek(0) == '.') {
            self.bump(1);
            return IntOrFloat.Float.{ try self.consumeFloatFractional(radix, number) };
        } else {
            return IntOrFloat.Int.{ number };
        }
    }

    /// Process a character code of the specified length and type.
    ///
    /// Returns the utf8 encoded value of the codepoint.
    ///
    /// This will only modify the current stream position.
    fn consumeCharCode(self: &Self,
        comptime radix: u8, comptime count: u8, comptime is_unicode: bool) !ArrayList(u8)
    {
        var utf8_code = ArrayList(u8).init(self.allocator);
        errdefer utf8_code.deinit();

        var char_code: u32 = 0;
        comptime var i: usize = 0;
        inline while (i < count) : (i += 1) {
            char_code *= radix;
            char_code += try getDigitValueForRadix(radix, self.peek(0));
            self.bump(1);
        }

        if (is_unicode) {
            if (char_code <= 0x7f) {
                try utf8_code.append(u8(char_code));
            } else if (char_code <= 0x7ff) {
                try utf8_code.append(0xc0 | u8(char_code >> 6));
                try utf8_code.append(0x80 | u8(char_code & 0x3f));
            } else if (char_code <= 0xffff) {
                try utf8_code.append(0xe0 | u8(char_code >> 12));
                try utf8_code.append(0x80 | u8((char_code >> 6) & 0x3f));
                try utf8_code.append(0x80 | u8(char_code & 0x3f));
            } else if (char_code <= 0x10ffff) {
                try utf8_code.append(0xf0 | u8(char_code >> 18));
                try utf8_code.append(0x80 | u8((char_code >> 12) & 0x3f));
                try utf8_code.append(0x80 | u8((char_code >> 6) & 0x3f));
                try utf8_code.append(0x80 | u8(char_code & 0x3f));
            } else {
                return error.UnicodeCharCodeOutOfRange;
            }
        } else {
            try utf8_code.append(u8(char_code));
        }

        return utf8_code;
    }

    /// Process an escape code.
    ///
    /// Expects the '/' has already been handled by the caller.
    ///
    /// Returns the utf8 encoded value of the codepoint.
    fn consumeStringEscape(self: &Self) !ArrayList(u8) {
        return switch (self.peek(0)) {
            'x' => {
                self.bump(1);
                self.consumeCharCode(16, 2, false);
            },

            'u' => {
                self.bump(1);
                self.consumeCharCode(16, 4, true);
            },

            'U' => {
                self.bump(1);
                self.consumeCharCode(16, 6, true);
            },

            'n'  => {
                self.bump(1);
                var l = ArrayList(u8).init(self.allocator);
                try l.append('\n');
                l;
            },

            'r'  => {
                self.bump(1);
                var l = ArrayList(u8).init(self.allocator);
                try l.append('\r');
                l;
            },

            '\\' => {
                self.bump(1);
                var l = ArrayList(u8).init(self.allocator);
                try l.append('\\');
                l;
            },

            't'  => {
                self.bump(1);
                var l = ArrayList(u8).init(self.allocator);
                try l.append('\t');
                l;
            },

            '\'' => {
                self.bump(1);
                var l = ArrayList(u8).init(self.allocator);
                try l.append('\'');
                l;
            },

            '"'  => {
                self.bump(1);
                var l = ArrayList(u8).init(self.allocator);
                try l.append('\"');
                l;
            },

            else => {
                @panic("unexpected character");
            }
        };
    }

    /// Process a string, returning the encountered characters.
    fn consumeString(self: &Self) !ArrayList(u8) {
        var literal = ArrayList(u8).init(self.allocator);
        errdefer literal.deinit();

        while (true) {
            switch (self.peek(0)) {
                '"' => {
                    self.bump(1);
                    break;
                },

                '\n' => {
                    return error.NewlineInStringLiteral;
                },

                '\\' => {
                    self.bump(1);
                    var value = try self.consumeStringEscape();
                    try literal.appendSlice(value.toSliceConst());
                    value.deinit();
                },

                0 => {
                    return error.EofWhileParsingLiteral;
                },

                else => |c| {
                    self.bump(1);
                    try literal.append(c);
                },
            }
        }

        return literal;
    }

    /// Process a line comment, returning the encountered characters
    // NOTE: We do not want to strip whitespace from comments since things like diagrams may require
    // it to be formatted correctly. We could do trailing but don't bother right now.
    fn consumeUntilNewline(self: &Self) !ArrayList(u8) {
        var comment = ArrayList(u8).init(self.allocator);
        errdefer comment.deinit();

        while (self.nextByte()) |c| {
            switch (c) {
                '\n' => {
                    break;
                },

                else => {
                    try comment.append(c);
                }
            }
        }

        return comment;
    }

    /// Return the next token from the buffer.
    pub fn next(t: &Self) !?*const Token {
        if (t.consumed) {
            return null;
        }

        t.beginToken();
        if (t.nextByte()) |ch| {
            switch (ch) {
                ' ', '\r', '\n', '\t' => {},

                '(' => try t.setEndToken(TokenId.LParen),
                ')' => try t.setEndToken(TokenId.RParen),
                ',' => try t.setEndToken(TokenId.Comma),
                '{' => try t.setEndToken(TokenId.LBrace),
                '}' => try t.setEndToken(TokenId.RBrace),
                '[' => try t.setEndToken(TokenId.LBracket),
                ']' => try t.setEndToken(TokenId.RBracket),
                ';' => try t.setEndToken(TokenId.Semicolon),
                ':' => try t.setEndToken(TokenId.Colon),
                '#' => try t.setEndToken(TokenId.NumberSign),
                '~' => try t.setEndToken(TokenId.Tilde),

                '_', 'a' ... 'z', 'A' ... 'Z' => {
                    var symbol = ArrayList(u8).init(t.allocator);
                    try symbol.append(ch);

                    while (true) {
                        switch (t.peek(0)) {
                            '_', 'a' ... 'z', 'A' ... 'Z', '0' ... '9' => |c| {
                                t.bump(1);
                                try symbol.append(c);
                            },

                            else => {
                                break;
                            },
                        }
                    }

                    if (getKeywordId(symbol.toSliceConst())) |id| {
                        symbol.deinit();
                        try t.setEndToken(id);
                    } else {
                        try t.setInternToken(&symbol);
                        try t.setEndToken(TokenId.Symbol);
                    }
                },

                '0' => {
                    const value = switch (t.peek(0)) {
                        'b' => {
                            t.bump(1);
                            try t.consumeNumber(2, null);
                        },

                        'o' => {
                            t.bump(1);
                            try t.consumeNumber(8, null);
                        },

                        'x' => {
                            t.bump(1);
                            try t.consumeNumber(16, null);
                        },

                        else => {
                            // TODO: disallow anything after a 0 except a dot.
                            try t.consumeNumber(10, null);
                        },
                    };

                    switch (value) {
                        IntOrFloat.Int => |i| {
                            (t.c_token).data.?.* = TokenData.Integer.{ i };
                            try t.setEndToken(TokenId.IntLiteral);
                        },
                        IntOrFloat.Float => |f| {
                            (t.c_token).data.?.* = TokenData.Float.{ f };
                            try t.setEndToken(TokenId.FloatLiteral);
                        },
                    }
                },

                '1' ... '9' => {
                    const value = try t.consumeNumber(10, ch);
                    switch (value) {
                        IntOrFloat.Int => |i| {
                            (t.c_token).data.?.* = TokenData.Integer.{ i };
                            try t.setEndToken(TokenId.IntLiteral);
                        },
                        IntOrFloat.Float => |f| {
                            (t.c_token).data.?.* = TokenData.Float.{ f };
                            try t.setEndToken(TokenId.FloatLiteral);
                        },
                    }
                },

                '"' => {
                    var literal = try t.consumeString();
                    try t.setInternToken(&literal);
                    try t.setEndToken(TokenId.StringLiteral);
                },

                '-' => {
                    switch (t.peek(0)) {
                        '>' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.Arrow);
                        },

                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.MinusEq);
                        },

                        '!' => {
                            t.bump(1);
                            switch (t.peek(0)) {
                                '=' => {
                                    t.bump(1);
                                    try t.setEndToken(TokenId.MinusPercentEq);
                                },

                                else => {
                                    try t.setEndToken(TokenId.MinusPercent);
                                },
                            }
                        },

                        else => {
                            try t.setEndToken(TokenId.Dash);
                        }
                    }
                },

                '+' => {
                    switch (t.peek(0)) {
                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.PlusEq);
                        },

                        '+' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.PlusPlus);
                        },

                        '!' => {
                            t.bump(1);
                            switch (t.peek(0)) {
                                '=' => {
                                    t.bump(1);
                                    try t.setEndToken(TokenId.PlusPercentEq);
                                },

                                else => {
                                    try t.setEndToken(TokenId.PlusPercent);
                                },
                            }
                        },

                        else => {
                            try t.setEndToken(TokenId.Plus);
                        }
                    }
                },

                '*' => {
                    switch (t.peek(0)) {
                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.TimesEq);
                        },

                        '*' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.StarStar);
                        },

                        '!' => {
                            t.bump(1);
                            switch (t.peek(0)) {
                                '=' => {
                                    t.bump(1);
                                    try t.setEndToken(TokenId.TimesPercentEq);
                                },

                                else => {
                                    try t.setEndToken(TokenId.TimesPercent);
                                }
                            }
                        },

                        else => {
                            try t.setEndToken(TokenId.Star);
                        },
                    }
                },

                '/' => {
                    switch (t.peek(0)) {
                        '/' => {
                            t.bump(1);
                            switch (t.peek(0)) {
                                '!' => {
                                    t.bump(1);
                                    t.setToken(TokenId.ModuleDocComment);
                                },

                                '/' => {
                                    t.bump(1);
                                    t.setToken(TokenId.DocComment);
                                },

                                else => {
                                    t.setToken(TokenId.Comment);
                                },
                            }

                            var comment_inner = try t.consumeUntilNewline();
                            try t.setInternToken(&comment_inner);
                            try t.endToken();
                        },

                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.DivEq);
                        },

                        else => {
                            try t.setEndToken(TokenId.Slash);
                        },
                    }
                },

                '!' => {
                    switch (t.peek(0)) {
                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.ModEq);
                        },

                        '.' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.PercentDot);
                        },

                        '!' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.PercentPercent);
                        },

                        else => {
                            try t.setEndToken(TokenId.Percent);
                        },
                    }
                },

                '@' => {
                    switch (t.peek(0)) {
                        '"' => {
                            t.bump(1);
                            var literal = try t.consumeString();
                            try t.setInternToken(&literal);
                            try t.setEndToken(TokenId.Symbol);
                        },

                        else => {
                            try t.setEndToken(TokenId.AtSign);
                        },
                    }
                },

                '&' => {
                    switch (t.peek(0)) {
                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.BitAndEq);
                        },

                        else => {
                            try t.setEndToken(TokenId.Ampersand);
                        }
                    }
                },

                '^' => {
                    switch (t.peek(0)) {
                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.BitXorEq);
                        },

                        else => {
                            try t.setEndToken(TokenId.BinXor);
                        }
                    }
                },

                '|' => {
                    switch (t.peek(0)) {
                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.BitOrEq);
                        },

                        else => {
                            try t.setEndToken(TokenId.BinOr);
                        }
                    }
                },

                '=' => {
                    switch (t.peek(0)) {
                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.CmpEq);
                        },

                        '>' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.FatArrow);
                        },

                        else => {
                            try t.setEndToken(TokenId.Eq);
                        },
                    }
                },

                '!' => {
                    switch (t.peek(0)) {
                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.CmpNotEq);
                        },

                        else => {
                            try t.setEndToken(TokenId.Bang);
                        },
                    }
                },

                '<' => {
                    switch (t.peek(0)) {
                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.CmpLessOrEq);
                        },

                        '<' => {
                            t.bump(1);
                            switch (t.peek(0)) {
                                '=' => {
                                    t.bump(1);
                                    try t.setEndToken(TokenId.BitShiftLeftEq);
                                },

                                else => {
                                    try t.setEndToken(TokenId.BitShiftLeft);
                                },
                            }
                        },

                        else => {
                            try t.setEndToken(TokenId.CmpLessThan);
                        },
                    }
                },

                '>' => {
                    switch (t.peek(0)) {
                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.CmpGreaterOrEq);
                        },

                        '>' => {
                            t.bump(1);
                            switch (t.peek(0)) {
                                '=' => {
                                    t.bump(1);
                                    try t.setEndToken(TokenId.BitShiftRightEq);
                                },

                                else => {
                                    try t.setEndToken(TokenId.BitShiftRight);
                                },
                            }
                        },

                        else => {
                            try t.setEndToken(TokenId.CmpGreaterThan);
                        },
                    }
                },

                '.' => {
                    switch (t.peek(0)) {
                        '.' => {
                            t.bump(1);
                            switch (t.peek(0)) {
                                '.' => {
                                    t.bump(1);
                                    return try t.setEndToken(TokenId.Ellipsis3);
                                },

                                else => {
                                    try t.setEndToken(TokenId.Ellipsis2);
                                },
                            }
                        },

                        else => {
                            try t.setEndToken(TokenId.Dot);
                        },
                    }
                },

                '?' => {
                    switch (t.peek(0)) {
                        '?' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.DoubleQuestion);
                        },

                        '=' => {
                            t.bump(1);
                            try t.setEndToken(TokenId.MaybeAssign);
                        },

                        else => {
                            try t.setEndToken(TokenId.Maybe);
                        }
                    }
                },

                '\'' => {
                    switch (t.peek(0)) {
                        '\'' => {
                            return error.MissingCharLiteralData;
                        },

                        '\\' => {
                            t.bump(1);
                            var value = try t.consumeStringEscape();

                            if (t.peek(0) != '\'') {
                                return error.ExtraCharLiteralData;
                            } else {
                                t.bump(1);
                                std.debug.assert(value.len == 1);
                                (??t.c_token).data = TokenData.Char { value.toSliceConst()[0] };
                                value.deinit();
                                try t.setEndToken(TokenId.CharLiteral);
                            }
                        },

                        0 => {
                            return error.EofWhileParsingLiteral;
                        },

                        else => {
                            if (t.peek(1) != '\'') {
                                return error.ExtraCharLiteralData;
                            } else {
                                (??t.c_token).data = TokenData.Char { t.peek(0) };
                                t.bump(2);
                                try t.setEndToken(TokenId.CharLiteral);
                            }
                        },
                    }
                },

                '\\' => {
                    switch (t.peek(0)) {
                        '\\' => {
                            t.bump(1);
                            var literal = try t.consumeUntilNewline();
                            try t.setInternToken(&literal);
                            try t.setEndToken(TokenId.MultiLineStringLiteral);
                        },

                        else => {
                            return error.InvalidCharacterAfterBackslash;
                        },
                    }
                },

                else => {
                    return error.InvalidCharacter;
                }
            }
        } else {
            t.consumed = true;
            try t.setEndToken(TokenId.Eof);
        }

        &t.tokens.toSliceConst()[t.tokens.len - 1]
    }

    /// Construct a new tokenization instance and return it in its completed state.
    ///
    // NOTE: If we want to return a stream of tokens, tie this to an underlying tokenization state
    // which handles the intern pool.
    //
    // NOTE: The tokenizer will continue through errors until the complete buffer has been processed.
    // The list of errors encountered will be stored in the `errors` field.
    pub fn process(self: &Self, buf: []const u8) !void {
        self.c_buf = buf;

        // This iterates over the entire buffer. Tokens are returned as references but are still
        // stored in the `tokens` field.
        while (true) {
            if (self.next()) |ch| {
                if (ch == null) {
                    break;
                }
            } else |err| switch (err) {
                else => return err,
            }
        }
    }
};
