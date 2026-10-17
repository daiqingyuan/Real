// Migrated with the user's authorization from their QQ lyrics integration.
// Provenance retained: DES core ported from LDDC tripledes.py / C# QQMusicDecoder.
// This decoder is third-party-derived; it is not claimed as an original real/Dan implementation.
// Upstream LDDC file: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>; GPL-3.0-only.
// Referenced C# QQMusicDecoder: Copyright (c) 2023 WXRIW; MIT.
// Exact primary-source revisions and verbatim license texts: Resources/Licenses/QQDecoder-*.
// This attribution record does not establish license clearance for the app.
// Local changes bound inflation and validate full cipher blocks.
// Source reference: docs/qrc-lyrics-pipeline.md in the user-provided integration.
import Foundation

// MARK: - zlib C interop (libz explicitly linked by the app target)

private let Z_OK: Int32 = 0

@_silgen_name("uncompress")
private func zlib_uncompress(
    _ dest: UnsafeMutablePointer<UInt8>!,
    _ destLen: UnsafeMutablePointer<UInt>!,
    _ source: UnsafePointer<UInt8>!,
    _ sourceLen: UInt
) -> Int32

private func zlibUncompress(_ src: Data) -> Data? {
    guard !src.isEmpty, src.count <= 2_000_000 else { return nil }
    let maximum = 4_000_000
    var capacity = min(maximum, max(4096, src.count * 4))
    while capacity <= maximum {
        var destination = Data(count: capacity)
        var actual = UInt(capacity)
        let result = destination.withUnsafeMutableBytes { output in
            src.withUnsafeBytes { input in
                zlib_uncompress(output.bindMemory(to: UInt8.self).baseAddress, &actual,
                    input.bindMemory(to: UInt8.self).baseAddress, UInt(src.count))
            }
        }
        if result == Z_OK { return destination.prefix(Int(actual)) }
        guard result == -5, capacity < maximum else { return nil } // Z_BUF_ERROR needs a larger destination.
        capacity = min(maximum, capacity * 2)
    }
    return nil
}

enum QQMusicQRCDecoder {

    // MARK: - DES Constants

    private static let qrcKey: [UInt8] = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)

    private static let DECRYPT: Int = 0
    private static let ENCRYPT: Int = 1

    private static let sbox: [[UInt32]] = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
         0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
         4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
         15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
         3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
         0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
         13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
         13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
         13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
         1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
         13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
         10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
         3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
         14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
         4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
         11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
         10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
         9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
         4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
         13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
         1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
         6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
         1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
         7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
         2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]

    // Cached 3DES key schedule for the standard QRC key in DECRYPT mode
    private static let cachedSchedule: [[[UInt8]]] = {
        let k = qrcKey
        return [
            keySchedule(key: Array(k[16..<24]), mode: DECRYPT),
            keySchedule(key: Array(k[8..<16]), mode: ENCRYPT),
            keySchedule(key: Array(k[0..<8]), mode: DECRYPT),
        ]
    }()

    // MARK: - Public API

    static func decode(_ hex: String) -> String? {
        let bytes = Array(hex.utf8)
        guard !bytes.isEmpty, bytes.count <= 4_000_000, bytes.count % 16 == 0 else { return nil }
        func nibble(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 65...70: return value - 55
            case 97...102: return value - 87
            default: return nil
            }
        }
        var encrypted = [UInt8]()
        encrypted.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            encrypted.append(high << 4 | low)
        }
        let schedule = tripledesKeySetup(key: qrcKey, mode: DECRYPT)
        var decrypted = Data()
        decrypted.reserveCapacity(encrypted.count)
        for index in stride(from: 0, to: encrypted.count, by: 8) {
            if index % 8192 == 0, Task.isCancelled { return nil }
            decrypted.append(contentsOf: tripledesCrypt(data: Array(encrypted[index..<(index + 8)]), schedule: schedule))
        }
        guard let data = zlibUncompress(decrypted) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Triple DES

    private static func tripledesKeySetup(key: [UInt8], mode: Int) -> [[[UInt8]]] {
        if mode == DECRYPT && key == qrcKey {
            return cachedSchedule
        }
        if mode == ENCRYPT {
            return [
                keySchedule(key: Array(key[0..<8]), mode: ENCRYPT),
                keySchedule(key: Array(key[8..<16]), mode: DECRYPT),
                keySchedule(key: Array(key[16..<24]), mode: ENCRYPT),
            ]
        }
        return [
            keySchedule(key: Array(key[16..<24]), mode: DECRYPT),
            keySchedule(key: Array(key[8..<16]), mode: ENCRYPT),
            keySchedule(key: Array(key[0..<8]), mode: DECRYPT),
        ]
    }

    private static func tripledesCrypt(data: [UInt8], schedule: [[[UInt8]]]) -> [UInt8] {
        var result = data
        for i in 0..<3 {
            result = crypt(inputData: result, key: schedule[i])
        }
        return result
    }

    // MARK: - DES Core (ported from LDDC tripledes.py / C# QQMusicDecoder)

    private static func bitnum(_ a: [UInt8], _ b: Int, _ c: Int) -> UInt32 {
        let byteIndex = (b / 32) * 4 + 3 - (b % 32) / 8
        let bitIndex = 7 - b % 8
        return (UInt32(a[byteIndex]) >> bitIndex & 1) << c
    }

    private static func bitnumIntr(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
        return ((a >> (31 - b)) & 1) << c
    }

    private static func bitnumIntl(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
        return ((a << b) & 0x80000000) >> c
    }

    private static func sboxBit(_ a: UInt32) -> Int {
        return Int((a & 32) | ((a & 31) >> 1) | ((a & 1) << 4))
    }

    private static func initialPermutation(_ inputData: [UInt8]) -> (UInt32, UInt32) {
        let s0: UInt32 =
            bitnum(inputData, 57, 31) | bitnum(inputData, 49, 30) | bitnum(inputData, 41, 29) | bitnum(inputData, 33, 28) |
            bitnum(inputData, 25, 27) | bitnum(inputData, 17, 26) | bitnum(inputData, 9, 25) | bitnum(inputData, 1, 24) |
            bitnum(inputData, 59, 23) | bitnum(inputData, 51, 22) | bitnum(inputData, 43, 21) | bitnum(inputData, 35, 20) |
            bitnum(inputData, 27, 19) | bitnum(inputData, 19, 18) | bitnum(inputData, 11, 17) | bitnum(inputData, 3, 16) |
            bitnum(inputData, 61, 15) | bitnum(inputData, 53, 14) | bitnum(inputData, 45, 13) | bitnum(inputData, 37, 12) |
            bitnum(inputData, 29, 11) | bitnum(inputData, 21, 10) | bitnum(inputData, 13, 9) | bitnum(inputData, 5, 8) |
            bitnum(inputData, 63, 7) | bitnum(inputData, 55, 6) | bitnum(inputData, 47, 5) | bitnum(inputData, 39, 4) |
            bitnum(inputData, 31, 3) | bitnum(inputData, 23, 2) | bitnum(inputData, 15, 1) | bitnum(inputData, 7, 0)

        let s1: UInt32 =
            bitnum(inputData, 56, 31) | bitnum(inputData, 48, 30) | bitnum(inputData, 40, 29) | bitnum(inputData, 32, 28) |
            bitnum(inputData, 24, 27) | bitnum(inputData, 16, 26) | bitnum(inputData, 8, 25) | bitnum(inputData, 0, 24) |
            bitnum(inputData, 58, 23) | bitnum(inputData, 50, 22) | bitnum(inputData, 42, 21) | bitnum(inputData, 34, 20) |
            bitnum(inputData, 26, 19) | bitnum(inputData, 18, 18) | bitnum(inputData, 10, 17) | bitnum(inputData, 2, 16) |
            bitnum(inputData, 60, 15) | bitnum(inputData, 52, 14) | bitnum(inputData, 44, 13) | bitnum(inputData, 36, 12) |
            bitnum(inputData, 28, 11) | bitnum(inputData, 20, 10) | bitnum(inputData, 12, 9) | bitnum(inputData, 4, 8) |
            bitnum(inputData, 62, 7) | bitnum(inputData, 54, 6) | bitnum(inputData, 46, 5) | bitnum(inputData, 38, 4) |
            bitnum(inputData, 30, 3) | bitnum(inputData, 22, 2) | bitnum(inputData, 14, 1) | bitnum(inputData, 6, 0)

        return (s0, s1)
    }

    private static func inversePermutation(_ s0: UInt32, _ s1: UInt32) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 8)

        data[3] = UInt8(bitnumIntr(s1, 7, 7) | bitnumIntr(s0, 7, 6) | bitnumIntr(s1, 15, 5) |
                         bitnumIntr(s0, 15, 4) | bitnumIntr(s1, 23, 3) | bitnumIntr(s0, 23, 2) |
                         bitnumIntr(s1, 31, 1) | bitnumIntr(s0, 31, 0))

        data[2] = UInt8(bitnumIntr(s1, 6, 7) | bitnumIntr(s0, 6, 6) | bitnumIntr(s1, 14, 5) |
                         bitnumIntr(s0, 14, 4) | bitnumIntr(s1, 22, 3) | bitnumIntr(s0, 22, 2) |
                         bitnumIntr(s1, 30, 1) | bitnumIntr(s0, 30, 0))

        data[1] = UInt8(bitnumIntr(s1, 5, 7) | bitnumIntr(s0, 5, 6) | bitnumIntr(s1, 13, 5) |
                         bitnumIntr(s0, 13, 4) | bitnumIntr(s1, 21, 3) | bitnumIntr(s0, 21, 2) |
                         bitnumIntr(s1, 29, 1) | bitnumIntr(s0, 29, 0))

        data[0] = UInt8(bitnumIntr(s1, 4, 7) | bitnumIntr(s0, 4, 6) | bitnumIntr(s1, 12, 5) |
                         bitnumIntr(s0, 12, 4) | bitnumIntr(s1, 20, 3) | bitnumIntr(s0, 20, 2) |
                         bitnumIntr(s1, 28, 1) | bitnumIntr(s0, 28, 0))

        data[7] = UInt8(bitnumIntr(s1, 3, 7) | bitnumIntr(s0, 3, 6) | bitnumIntr(s1, 11, 5) |
                         bitnumIntr(s0, 11, 4) | bitnumIntr(s1, 19, 3) | bitnumIntr(s0, 19, 2) |
                         bitnumIntr(s1, 27, 1) | bitnumIntr(s0, 27, 0))

        data[6] = UInt8(bitnumIntr(s1, 2, 7) | bitnumIntr(s0, 2, 6) | bitnumIntr(s1, 10, 5) |
                         bitnumIntr(s0, 10, 4) | bitnumIntr(s1, 18, 3) | bitnumIntr(s0, 18, 2) |
                         bitnumIntr(s1, 26, 1) | bitnumIntr(s0, 26, 0))

        data[5] = UInt8(bitnumIntr(s1, 1, 7) | bitnumIntr(s0, 1, 6) | bitnumIntr(s1, 9, 5) |
                         bitnumIntr(s0, 9, 4) | bitnumIntr(s1, 17, 3) | bitnumIntr(s0, 17, 2) |
                         bitnumIntr(s1, 25, 1) | bitnumIntr(s0, 25, 0))

        data[4] = UInt8(bitnumIntr(s1, 0, 7) | bitnumIntr(s0, 0, 6) | bitnumIntr(s1, 8, 5) |
                         bitnumIntr(s0, 8, 4) | bitnumIntr(s1, 16, 3) | bitnumIntr(s0, 16, 2) |
                         bitnumIntr(s1, 24, 1) | bitnumIntr(s0, 24, 0))

        return data
    }

    private static func f(_ state: UInt32, key: [UInt8]) -> UInt32 {
        let t1: UInt32 =
            bitnumIntl(state, 31, 0) | ((state & 0xf0000000) >> 1) | bitnumIntl(state, 4, 5) |
            bitnumIntl(state, 3, 6) | ((state & 0x0f000000) >> 3) | bitnumIntl(state, 8, 11) |
            bitnumIntl(state, 7, 12) | ((state & 0x00f00000) >> 5) | bitnumIntl(state, 12, 17) |
            bitnumIntl(state, 11, 18) | ((state & 0x000f0000) >> 7) | bitnumIntl(state, 16, 23)

        let t2: UInt32 =
            bitnumIntl(state, 15, 0) | ((state & 0x0000f000) << 15) | bitnumIntl(state, 20, 5) |
            bitnumIntl(state, 19, 6) | ((state & 0x00000f00) << 13) | bitnumIntl(state, 24, 11) |
            bitnumIntl(state, 23, 12) | ((state & 0x000000f0) << 11) | bitnumIntl(state, 28, 17) |
            bitnumIntl(state, 27, 18) | ((state & 0x0000000f) << 9) | bitnumIntl(state, 0, 23)

        var lrgstate: [UInt32] = [
            (t1 >> 24) & 0x000000ff,
            (t1 >> 16) & 0x000000ff,
            (t1 >> 8) & 0x000000ff,
            (t2 >> 24) & 0x000000ff,
            (t2 >> 16) & 0x000000ff,
            (t2 >> 8) & 0x000000ff,
        ]

        for i in 0..<6 {
            lrgstate[i] ^= UInt32(key[i])
        }

        let newState: UInt32 =
            (sbox[0][sboxBit(lrgstate[0] >> 2)] << 28) |
            (sbox[1][sboxBit(((lrgstate[0] & 0x03) << 4) | (lrgstate[1] >> 4))] << 24) |
            (sbox[2][sboxBit(((lrgstate[1] & 0x0f) << 2) | (lrgstate[2] >> 6))] << 20) |
            (sbox[3][sboxBit(lrgstate[2] & 0x3f)] << 16) |
            (sbox[4][sboxBit(lrgstate[3] >> 2)] << 12) |
            (sbox[5][sboxBit(((lrgstate[3] & 0x03) << 4) | (lrgstate[4] >> 4))] << 8) |
            (sbox[6][sboxBit(((lrgstate[4] & 0x0f) << 2) | (lrgstate[5] >> 6))] << 4) |
            sbox[7][sboxBit(lrgstate[5] & 0x3f)]

        return bitnumIntl(newState, 15, 0) | bitnumIntl(newState, 6, 1) | bitnumIntl(newState, 19, 2) |
               bitnumIntl(newState, 20, 3) | bitnumIntl(newState, 28, 4) | bitnumIntl(newState, 11, 5) |
               bitnumIntl(newState, 27, 6) | bitnumIntl(newState, 16, 7) | bitnumIntl(newState, 0, 8) |
               bitnumIntl(newState, 14, 9) | bitnumIntl(newState, 22, 10) | bitnumIntl(newState, 25, 11) |
               bitnumIntl(newState, 4, 12) | bitnumIntl(newState, 17, 13) | bitnumIntl(newState, 30, 14) |
               bitnumIntl(newState, 9, 15) | bitnumIntl(newState, 1, 16) | bitnumIntl(newState, 7, 17) |
               bitnumIntl(newState, 23, 18) | bitnumIntl(newState, 13, 19) | bitnumIntl(newState, 31, 20) |
               bitnumIntl(newState, 26, 21) | bitnumIntl(newState, 2, 22) | bitnumIntl(newState, 8, 23) |
               bitnumIntl(newState, 18, 24) | bitnumIntl(newState, 12, 25) | bitnumIntl(newState, 29, 26) |
               bitnumIntl(newState, 5, 27) | bitnumIntl(newState, 21, 28) | bitnumIntl(newState, 10, 29) |
               bitnumIntl(newState, 3, 30) | bitnumIntl(newState, 24, 31)
    }

    private static func crypt(inputData: [UInt8], key: [[UInt8]]) -> [UInt8] {
        let (s0Init, s1Init) = initialPermutation(inputData)
        var s0 = s0Init
        var s1 = s1Init

        for idx in 0..<15 {
            let prevS1 = s1
            s1 = f(s1, key: key[idx]) ^ s0
            s0 = prevS1
        }
        s0 = f(s1, key: key[15]) ^ s0

        return inversePermutation(s0, s1)
    }

    private static func keySchedule(key: [UInt8], mode: Int) -> [[UInt8]] {
        var schedule = [[UInt8]](repeating: [UInt8](repeating: 0, count: 6), count: 16)
        let keyRndShift: [Int] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
        let keyPermC: [Int] = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35]
        let keyPermD: [Int] = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
        let keyCompression: [Int] = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36,
                                      46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31]

        var c: UInt32 = 0
        var d: UInt32 = 0

        for i in 0..<28 {
            c |= bitnum(key, keyPermC[i], 31 - i)
            d |= bitnum(key, keyPermD[i], 31 - i)
        }

        for i in 0..<16 {
            let shift = keyRndShift[i]
            c = ((c << shift) | (c >> (28 - shift))) & 0xfffffff0
            d = ((d << shift) | (d >> (28 - shift))) & 0xfffffff0

            let togen = mode == DECRYPT ? 15 - i : i

            schedule[togen] = [UInt8](repeating: 0, count: 6)

            for j in 0..<24 {
                let val = UInt8(bitnumIntr(c, keyCompression[j], 7 - (j % 8)) & 0xff)
                schedule[togen][j / 8] = schedule[togen][j / 8] | val
            }
            for j in 24..<48 {
                let val = UInt8(bitnumIntr(d, keyCompression[j] - 27, 7 - (j % 8)) & 0xff)
                schedule[togen][j / 8] = schedule[togen][j / 8] | val
            }
        }

        return schedule
    }
}
