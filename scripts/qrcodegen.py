"""Minimal QR code generator (byte mode, error correction level L).

Only what the login helper needs: byte-mode payloads up to version 8, one mask
pattern, rendered as UTF-8 half blocks for the terminal. Standard library only,
so the script runs anywhere Python does.

Reference: ISO/IEC 18004. Tables below cover versions 1-8 at level L.
"""

# version -> (ec codewords per block, [(block count, data codewords per block)])
BLOCKS_L = {
    1: (7, [(1, 19)]),
    2: (10, [(1, 34)]),
    3: (15, [(1, 55)]),
    4: (20, [(1, 80)]),
    5: (26, [(1, 108)]),
    6: (18, [(2, 68)]),
    7: (20, [(2, 78)]),
    8: (24, [(2, 97)]),
}

# version -> alignment pattern centre coordinates
ALIGN = {
    1: [],
    2: [6, 18],
    3: [6, 22],
    4: [6, 26],
    5: [6, 30],
    6: [6, 34],
    7: [6, 22, 38],
    8: [6, 24, 42],
}

FORMAT_L_MASK0 = 0b01000  # level L (01) + mask pattern 0 (000)


def _gf_tables():
    exp = [0] * 512
    log = [0] * 256
    value = 1
    for i in range(255):
        exp[i] = value
        log[value] = i
        value <<= 1
        if value & 0x100:
            value ^= 0x11D
    for i in range(255, 512):
        exp[i] = exp[i - 255]
    return exp, log


GF_EXP, GF_LOG = _gf_tables()


def _gf_mul(a, b):
    if a == 0 or b == 0:
        return 0
    return GF_EXP[GF_LOG[a] + GF_LOG[b]]


def _rs_divisor(degree):
    result = [0] * degree
    result[-1] = 1
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = _gf_mul(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = _gf_mul(root, 0x02)
    return result


def _rs_remainder(data, divisor):
    result = [0] * len(divisor)
    for byte in data:
        factor = byte ^ result.pop(0)
        result.append(0)
        for i, coef in enumerate(divisor):
            result[i] ^= _gf_mul(coef, factor)
    return result


def _bch(value, poly, bits):
    """Remainder of value << bits divided by poly, in GF(2)."""
    rem = value << bits
    for i in range(rem.bit_length() - 1, bits - 1, -1):
        if rem >> i & 1:
            rem ^= poly << (i - bits)
    return rem


def _capacity(version):
    return sum(count * size for count, size in BLOCKS_L[version][1])


def _pick_version(length):
    for version in sorted(BLOCKS_L):
        header_bits = 4 + (8 if version < 10 else 16)
        if length * 8 + header_bits <= _capacity(version) * 8:
            return version
    raise ValueError("内容过长，超出本实现的版本范围（最多 %d 字节）" % max(BLOCKS_L))


def _encode_data(payload, version):
    bits = []

    def push(value, length):
        for shift in range(length - 1, -1, -1):
            bits.append(value >> shift & 1)

    push(0b0100, 4)  # byte mode
    push(len(payload), 8)
    for byte in payload:
        push(byte, 8)

    capacity_bits = _capacity(version) * 8
    push(0, min(4, capacity_bits - len(bits)))
    while len(bits) % 8:
        bits.append(0)

    codewords = [int("".join(str(b) for b in bits[i:i + 8]), 2) for i in range(0, len(bits), 8)]
    pad = (0xEC, 0x11)
    index = 0
    while len(codewords) < _capacity(version):
        codewords.append(pad[index % 2])
        index += 1
    return codewords


def _add_error_correction(codewords, version):
    ec_len, groups = BLOCKS_L[version]
    divisor = _rs_divisor(ec_len)
    blocks = []
    pos = 0
    for count, size in groups:
        for _ in range(count):
            chunk = codewords[pos:pos + size]
            pos += size
            blocks.append((chunk, _rs_remainder(chunk, divisor)))

    result = []
    for i in range(max(len(data) for data, _ in blocks)):
        for data, _ in blocks:
            if i < len(data):
                result.append(data[i])
    for i in range(ec_len):
        for _, ec in blocks:
            result.append(ec[i])
    return result


class _Grid:
    def __init__(self, version):
        self.version = version
        self.size = 17 + 4 * version
        self.modules = [[False] * self.size for _ in range(self.size)]
        self.reserved = [[False] * self.size for _ in range(self.size)]

    def set_func(self, row, col, dark):
        self.modules[row][col] = dark
        self.reserved[row][col] = True

    def draw_finder(self, row, col):
        for dr in range(-1, 8):
            for dc in range(-1, 8):
                r, c = row + dr, col + dc
                if 0 <= r < self.size and 0 <= c < self.size:
                    inside = 0 <= dr <= 6 and 0 <= dc <= 6
                    ring = inside and (dr in (0, 6) or dc in (0, 6) or (2 <= dr <= 4 and 2 <= dc <= 4))
                    self.set_func(r, c, ring)

    def draw_alignment(self, row, col):
        for dr in range(-2, 3):
            for dc in range(-2, 3):
                self.set_func(row + dr, col + dc, max(abs(dr), abs(dc)) != 1)

    def draw_patterns(self):
        self.draw_finder(0, 0)
        self.draw_finder(0, self.size - 7)
        self.draw_finder(self.size - 7, 0)

        for i in range(self.size):
            if not self.reserved[6][i]:
                self.set_func(6, i, i % 2 == 0)
            if not self.reserved[i][6]:
                self.set_func(i, 6, i % 2 == 0)

        centres = ALIGN[self.version]
        last = len(centres) - 1
        for i, row in enumerate(centres):
            for j, col in enumerate(centres):
                corner = (i == 0 and j == 0) or (i == 0 and j == last) or (i == last and j == 0)
                if not corner:
                    self.draw_alignment(row, col)

        if self.version >= 7:
            for i in range(6):
                for j in range(3):
                    self.reserved[i][self.size - 11 + j] = True
                    self.reserved[self.size - 11 + j][i] = True

        # Reserve format areas so data placement skips them.
        for i in range(9):
            for r, c in ((8, i), (i, 8)):
                if not self.reserved[r][c]:
                    self.reserved[r][c] = True
        for i in range(8):
            self.reserved[8][self.size - 1 - i] = True
            self.reserved[self.size - 1 - i][8] = True
        self.set_func(8, self.size - 8, True)  # dark module

    def place_data(self, codewords):
        bits = []
        for byte in codewords:
            for shift in range(7, -1, -1):
                bits.append(byte >> shift & 1)
        index = 0
        right = self.size - 1
        upward = True
        while right >= 1:
            if right == 6:
                right -= 1
            rows = range(self.size - 1, -1, -1) if upward else range(self.size)
            for row in rows:
                for col in (right, right - 1):
                    if not self.reserved[row][col]:
                        dark = bits[index] == 1 if index < len(bits) else False
                        index += 1
                        if (row + col) % 2 == 0:  # mask pattern 0
                            dark = not dark
                        self.modules[row][col] = dark
            upward = not upward
            right -= 2

    def draw_version(self):
        """18-bit version info, required from version 7 upwards."""
        bits = (self.version << 12) | _bch(self.version, 0x1F25, 12)
        for i in range(18):
            dark = bits >> i & 1 == 1
            row, col = i // 3, i % 3
            self.modules[row][self.size - 11 + col] = dark
            self.modules[self.size - 11 + col][row] = dark

    def draw_format(self):
        data = FORMAT_L_MASK0
        bits = (data << 10) | _bch(data, 0x537, 10)
        bits ^= 0x5412
        positions = [
            (8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8),
            (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8),
        ]
        for i, (row, col) in enumerate(positions):
            dark = bits >> i & 1 == 1
            self.modules[row][col] = dark
            if i < 8:
                self.modules[8][self.size - 1 - i] = dark
            else:
                self.modules[self.size - 15 + i][8] = dark
        self.modules[8][self.size - 8] = True

        if self.version >= 7:
            self.draw_version()


def make(text):
    """Return the module matrix (list of rows of bool) for text."""
    payload = text.encode("utf-8")
    version = _pick_version(len(payload))
    codewords = _add_error_correction(_encode_data(payload, version), version)
    grid = _Grid(version)
    grid.draw_patterns()
    grid.place_data(codewords)
    grid.draw_format()
    return grid.modules


def render(matrix, quiet=2, compact=True, ascii_only=False):
    """Render as half blocks; two module rows share one text line.

    ascii_only keeps the output inside ASCII so a GBK console can still print it.
    """
    size = len(matrix)
    pad = [[False] * size for _ in range(quiet)]
    rows = pad + matrix + pad
    blank = [False] * (size + 2 * quiet)
    rows = [[False] * quiet + row + [False] * quiet for row in rows]

    lines = []
    if compact and not ascii_only:
        for i in range(0, len(rows), 2):
            top = rows[i]
            bottom = rows[i + 1] if i + 1 < len(rows) else blank
            line = []
            for a, b in zip(top, bottom):
                line.append("\u2588" if a and b else "\u2580" if a else "\u2584" if b else " ")
            lines.append("".join(line))
    else:
        dark = "##" if ascii_only else "\u2588\u2588"
        for row in rows:
            lines.append("".join(dark if m else "  " for m in row))
    return "\n".join(lines)
