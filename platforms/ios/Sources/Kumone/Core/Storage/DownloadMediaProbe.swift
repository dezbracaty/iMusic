#if os(iOS)
import Foundation

/// Classifies only evidence available in a bounded byte window. A positive
/// result authorizes continuing the transfer; the complete file is rechecked.
struct DownloadMediaProbe {
    let fileExtension: String?
    var audio: DownloadAudioQuality?
    var nextBoxOffset: Int?

    static func inspect(_ data: Data) -> Self {
        var start = 0
        if data.count >= 10, data.starts(with: "ID3".utf8) {
            let size = data[6..<10]
            guard size.allSatisfy({ $0 < 128 }) else { return .init(fileExtension: nil) }
            start = 10 + size.reduce(0) { ($0 << 7) | Int($1) }
            if data[3] == 4, data[5] & 0x10 != 0 { start += 10 }
        }
        guard data.count >= start + 12 else { return .init(fileExtension: nil) }
        func matches(_ text: String, at offset: Int = 0) -> Bool {
            data.dropFirst(start + offset).starts(with: text.utf8)
        }
        if matches("fLaC") {
            guard data.count >= start + 42, data[start + 4] & 0x7f == 0,
                  data.u32(at: start + 4) & 0x00ff_ffff == 34 else {
                return .init(fileExtension: "flac")
            }
            let packed = data.u32(at: start + 18)
            let depth = (packed >> 4 & 31) + 1
            guard packed >> 12 > 0, depth >= 4 else { return .init(fileExtension: "flac") }
            return .init(fileExtension: "flac", audio: .init(codec: "FLAC", bitRate: nil, bitDepth: depth))
        }
        if ["ftyp", "moov", "mdat", "free", "wide", "skip"].contains(data.fourCC(at: start + 4)), start == 0 {
            return inspectMovie(data, base: 0)
        }
        if matches("WAVE", at: 8), matches("RIFF") || matches("RF64") { return .init(fileExtension: "wav") }
        if matches("FORM"), matches("AIFF", at: 8) || matches("AIFC", at: 8) { return .init(fileExtension: "aiff") }
        if matches("caff") { return .init(fileExtension: "caf") }
        if matches("ADIF") {
            return .init(fileExtension: "aac", audio: .init(codec: "AAC", bitRate: nil, bitDepth: nil))
        }
        guard data[start] == 0xff, data[start + 1] & 0xe0 == 0xe0 else { return .init(fileExtension: nil) }
        switch data[start + 1] & 0x06 {
        case 0 where data[start + 1] & 0xf0 == 0xf0:
            return .init(fileExtension: "aac", audio: .init(codec: "AAC", bitRate: nil, bitDepth: nil))
        case 2 where data[start + 1] & 0x18 != 0x08:
            return .init(fileExtension: "mp3", audio: .init(codec: "MP3", bitRate: nil, bitDepth: nil))
        default:
            return .init(fileExtension: nil)
        }
    }

    /// Starts at a proven top-level atom boundary, whether in the prefix
    /// or a representation-validated range. Never scans audio for "moov".
    static func inspectMovie(_ data: Data, base: Int) -> Self {
        var offset = 0
        while let box = Box(in: data, at: offset, limit: nil) {
            if box.type == "moov" {
                guard box.end <= data.count else {
                    return .init(fileExtension: "m4a", nextBoxOffset: base + offset)
                }
                return .init(fileExtension: "m4a", audio: movieAudio(data, in: box))
            }
            if box.end > data.count {
                return .init(fileExtension: "m4a", nextBoxOffset: base + box.end)
            }
            offset = box.end
        }
        return .init(fileExtension: "m4a", nextBoxOffset: base + offset)
    }

    private static func movieAudio(_ data: Data, in moov: Box) -> DownloadAudioQuality? {
        let tracks = moov.children(in: data).filter { $0.type == "trak" }.compactMap { track -> Box? in
            guard let media = track.child("mdia", in: data),
                  let handler = media.child("hdlr", in: data),
                  handler.payload + 12 <= handler.end,
                  data.fourCC(at: handler.payload + 8) == "soun" else { return nil }
            return media
        }
        guard tracks.count == 1,
              let info = tracks[0].child("minf", in: data),
              let table = info.child("stbl", in: data),
              let descriptions = table.child("stsd", in: data),
              descriptions.payload + 8 <= descriptions.end,
              data.u32(at: descriptions.payload + 4) == 1,
              let sample = Box(in: data, at: descriptions.payload + 8, limit: descriptions.end),
              sample.payload + 28 <= sample.end else { return nil }

        let version = data[sample.payload + 8]
        let minor = data[sample.payload + 9]
        guard version == 0 else { return nil }
        let extra: Int
        switch minor {
        case 0: extra = 0
        case 1: extra = 16
        case 2: extra = 36
        default: return nil
        }
        let children = Box.list(in: data, from: sample.payload + 28 + extra, to: sample.end)
        switch sample.type {
        case "alac":
            // The codec configuration, rather than the generic sample entry,
            // carries the encoded bit depth.
            guard let config = children.first(where: { $0.type == "alac" }),
                  config.payload + 28 <= config.end else { return nil }
            let depth = Int(data[config.payload + 9])
            guard [16, 20, 24, 32].contains(depth) else { return nil }
            return .init(codec: "ALAC", bitRate: nil, bitDepth: depth)
        case "mp4a":
            guard let esds = children.first(where: { $0.type == "esds" }) else { return nil }
            return aacDescription(data, in: esds)
        default:
            return nil
        }
    }

    private static func aacDescription(_ data: Data, in box: Box) -> DownloadAudioQuality? {
        guard let es = descriptor(data, at: box.payload + 4, limit: box.end, tag: 3),
              es.count >= 3 else { return nil }
        let flags = data[es.lowerBound + 2]
        var offset = es.lowerBound + 3
        if flags & 0x80 != 0 { offset += 2 }
        if flags & 0x40 != 0 {
            guard offset < es.upperBound else { return nil }
            offset += 1 + Int(data[offset])
        }
        if flags & 0x20 != 0 { offset += 2 }
        guard let decoder = descriptor(data, at: offset, limit: es.upperBound, tag: 4),
              decoder.count >= 13, data[decoder.lowerBound] == 0x40,
              let config = descriptor(data, at: decoder.lowerBound + 13, limit: decoder.upperBound, tag: 5),
              !config.isEmpty, [1, 2, 3, 4, 5, 17, 23, 29].contains(data[config.lowerBound] >> 3) else { return nil }
        let bitrate = data.u32(at: decoder.lowerBound + 9)
        return .init(codec: "AAC", bitRate: bitrate > 0 ? bitrate : nil, bitDepth: nil)
    }

    private static func descriptor(_ data: Data, at start: Int, limit: Int, tag: UInt8) -> Range<Int>? {
        guard start < limit, data[start] == tag else { return nil }
        var offset = start + 1
        var length = 0
        for _ in 0..<4 {
            guard offset < limit else { return nil }
            let byte = data[offset]
            offset += 1
            length = length << 7 | Int(byte & 0x7f)
            if byte & 0x80 == 0 {
                guard length <= limit - offset else { return nil }
                return offset..<(offset + length)
            }
        }
        return nil
    }

    private struct Box {
        let type: String
        let payload: Int
        let end: Int

        init?(in data: Data, at offset: Int, limit: Int?) {
            guard offset >= 0, offset + 8 <= min(limit ?? data.count, data.count) else { return nil }
            let size = data.u32(at: offset)
            type = data.fourCC(at: offset + 4)
            if size == 1 {
                guard offset + 16 <= min(limit ?? data.count, data.count), data.u32(at: offset + 8) == 0 else {
                    return nil
                }
                payload = offset + 16
                end = offset + data.u32(at: offset + 12)
            } else {
                guard size > 0 else { return nil }
                payload = offset + 8
                end = offset + size
            }
            guard end >= payload, end <= (limit ?? DownloadStream.maximumBytes) else { return nil }
        }

        static func list(in data: Data, from start: Int, to end: Int) -> [Self] {
            var list: [Self] = []
            var offset = start
            while offset < end {
                guard let box = Self(in: data, at: offset, limit: end) else { return [] }
                list.append(box)
                offset = box.end
            }
            return list
        }

        func children(in data: Data) -> [Self] { Self.list(in: data, from: payload, to: end) }
        func child(_ name: String, in data: Data) -> Self? { children(in: data).first { $0.type == name } }
    }
}

private extension Data {
    func u32(at index: Int) -> Int {
        (index..<index + 4).reduce(0) { ($0 << 8) | Int(self[$1]) }
    }

    func fourCC(at index: Int) -> String {
        String(decoding: self[index..<index + 4], as: UTF8.self)
    }
}
#endif
