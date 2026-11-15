import AetherEngine
import Foundation

/// What a release name says of a version, read the way Radarr and Sonarr read one and TRaSH
/// Guides' custom formats sort one: through an ordered table of rules (`ReleaseName.rules`), each a
/// pattern for one term. "4k dolby vision bluray REMUX HEVC-DV-HDR10+-10BIT [EN]" says 2160 lines,
/// Dolby Vision with HDR10+, a Blu-ray remux, and HEVC; the bit depth, the language and the
/// punctuation say nothing more. Where a kind of term takes one value, the first rule of it to
/// match wins, so the table lists the more telling first: a remux before the Blu-ray it came from,
/// WEBRip before the "WEB" that WEB-DL also matches.
///
/// Words a title can have too are read only from after the year or the episode number, when the
/// name has one: editions and extras, as in "Uncut Gems" or "Step Up 3D", a bare "WEB" as in
/// "Charlotte's Web", and the audio, as in "Mr. Holland's Opus". What the server measured of the
/// file comes before all of this (`VersionLabel`, `AudioLabel`).
nonisolated struct ReleaseName: Equatable, Sendable {
    /// The picture's class in lines: 2160, 1080, 480 for anything standard definition.
    var resolution: Int?
    /// In the table's order, Dolby Vision first.
    var ranges: [DynamicRange] = []
    var source: ReleaseSource?
    var codec: VideoCodec?
    /// "Director's Cut", "IMAX", in the order the table lists them.
    var editions: [String] = []
    /// "3D", "HFR", "Upscaled".
    var extras: [String] = []
    var spatialAudio: SpatialAudio?
    var audio: AudioFormat?
    /// "7.1", "Stereo", only alongside an audio format, where a number like it is a layout.
    var channels: String?
    /// The release group, "FraMeSToR" of "…Atmos-FraMeSToR": noise, but what tells apart two
    /// releases alike in everything else.
    var group: String?

    /// Reads `texts`, such as a version's name and its file's name, as one.
    init(_ texts: [String]) {
        let texts = texts.map { $0.replacingOccurrences(of: "_", with: " ") }.filter { !$0.isEmpty }
        let whole = texts.joined(separator: " / ")
        let afterTitle = texts.map(Self.afterTitle).joined(separator: " / ")
        // An edition named as Jellyfin and Plex name one, "{edition-…}", is the edition.
        var isNamedEdition = false
        for rule in Self.rules {
            let text = rule.afterTitle ? afterTitle : whole
            guard let match = rule.pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            switch rule.term {
            case .resolution(let lines): resolution = resolution ?? lines
            case .range(let range): if !ranges.contains(range) { ranges.append(range) }
            case .source(let source): self.source = self.source ?? source
            case .codec(let codec): self.codec = self.codec ?? codec
            case .edition(let label):
                guard !isNamedEdition else { continue }
                // A group is a name as written, "{edition-IMAX}"; otherwise words as a release runs them together.
                isNamedEdition = match.numberOfRanges > 1
                let edition = label ?? (isNamedEdition ? Self.captured(match, in: text) : Self.tidy(Self.captured(match, in: text)))
                if !edition.isEmpty, !editions.contains(edition) { editions.append(edition) }
            case .extra(let label): if !extras.contains(label) { extras.append(label) }
            case .spatial(let spatial): spatialAudio = spatialAudio ?? spatial
            case .audio(let format): audio = audio ?? format
            }
        }
        if audio != nil || spatialAudio != nil {
            channels = Self.channels(in: whole)
        }
        if resolution != nil || source != nil || codec != nil || audio != nil {
            group = texts.last.flatMap(Self.group)
        }
    }

    init(_ text: String) {
        self.init([text])
    }

    // MARK: The rules

    /// A term a release name can carry, and what a rule for it finds.
    enum Term: Hashable, Sendable {
        case resolution(Int)
        case range(DynamicRange)
        case source(ReleaseSource)
        case codec(VideoCodec)
        /// Nil names it by the words matched, or by the pattern's first group when it has one.
        case edition(String?)
        case extra(String)
        case spatial(SpatialAudio)
        case audio(AudioFormat)
    }

    struct Rule: Sendable {
        let term: Term
        let pattern: NSRegularExpression
        /// Read only from after the title, which can say the same words.
        var afterTitle = false
    }

    /// Every rule, in the order they're tried. A pattern stands for whole words: nothing of a
    /// letter or digit runs into it, though an audio format may run into its channels, as in
    /// "DDP5.1".
    static let rules: [Rule] = [
        // Resolution: a number before a word for a size, which names like "1080p UHD BluRay" use
        // for the source the picture came from.
        word(.resolution(4320), "4320p|4320|8k"),
        word(.resolution(2160), "2160p|2160"),
        word(.resolution(1440), "1440p|1440"),
        word(.resolution(1080), "1080[pi]|1080"),
        word(.resolution(720), "720p|720"),
        word(.resolution(480), "576p|576|540p|480p|480|360p"),
        word(.resolution(2160), "4k|uhd"),
        word(.resolution(1440), "2k"),
        word(.resolution(1080), "fhd|full[ .-]?hd"),
        word(.resolution(480), "sd|sdtv|dvd(?:rip|r|5|9)?"),

        // High dynamic range: each the name says.
        word(.range(.dolbyVision), "dv|dovi|dolby[ .-]?vision"),
        word(.range(.hdr10Plus), "hdr10(?:\\+|plus|p)|hdr10[ .-]plus"),
        word(.range(.hdr10), "hdr10"),
        word(.range(.hlg), "hlg"),
        word(.range(.hdr), "hdr"),

        // Source: the first that matches.
        word(.source(.remux), "(?:bd|uhd)?remux"),
        word(.source(.bluRay), "blu[ .-]?ray|bd(?:rip)?|br[ .-]?rip|bd25|bd50|bd66|bd100"),
        word(.source(.webRip), "web[ .-]?rip"),
        word(.source(.webDL), "web[ .-]?dl"),
        word(.source(.webDL), "web", afterTitle: true),
        word(.source(.hdtv), "hdtv|pdtv|sdtv|tvrip"),
        word(.source(.dvd), "dvd(?:rip|r|5|9)?"),

        // Video codec: the first that matches.
        word(.codec(.av1), "av1"),
        word(.codec(.hevc), "hevc|[hx][ .]?265"),
        word(.codec(.avc), "avc|[hx][ .]?264"),
        word(.codec(.vc1), "vc[ .-]?1"),
        word(.codec(.mpeg2), "mpeg[ .-]?2"),

        // Editions: every one that matches. Jellyfin's and Plex's own "{edition-…}" first.
        Rule(term: .edition(nil), pattern: regex("\\{edition-([^}]+)\\}")),
        word(.edition("Director's Cut"), "director['’]?s[ .-]?(?:cut|edition)", afterTitle: true),
        word(.edition("Extended"), "extended(?:[ .-]?(?:cut|edition|version))?", afterTitle: true),
        word(.edition("Theatrical"), "theatrical(?:[ .-]?(?:cut|edition|version))?", afterTitle: true),
        word(.edition("Final Cut"), "final[ .-]?cut", afterTitle: true),
        word(.edition(nil), "ultimate[ .-]?(?:cut|edition)", afterTitle: true),
        word(.edition("Special Edition"), "special[ .-]?edition", afterTitle: true),
        word(.edition("Collector's Edition"), "collector['’]?s[ .-]?edition", afterTitle: true),
        word(.edition(nil), "[0-9]{2,3}(?:st|nd|rd|th)?[ .-]?anniversary(?:[ .-]?edition)?", afterTitle: true),
        word(.edition("Unrated"), "unrated", afterTitle: true),
        word(.edition("Uncut"), "uncut", afterTitle: true),
        word(.edition("Uncensored"), "uncensored", afterTitle: true),
        word(.edition("IMAX"), "imax(?:[ .-]?enhanced)?", afterTitle: true),
        word(.edition("Remastered"), "remaster(?:ed)?", afterTitle: true),
        word(.edition("Criterion"), "criterion(?:[ .-]?collection)?", afterTitle: true),
        word(.edition("Open Matte"), "open[ .-]?matte", afterTitle: true),
        word(.edition("Redux"), "redux", afterTitle: true),
        word(.edition("Despecialized"), "despecialized", afterTitle: true),
        word(.edition("Fan Edit"), "fan[ .-]?edit", afterTitle: true),

        // Extras: every one that matches.
        word(.extra("3D"), "3d|h(?:alf)?[ .-]?(?:sbs|ou|tab)|sbs", afterTitle: true),
        word(.extra("HFR"), "hfr", afterTitle: true),
        word(.extra("Upscaled"), "upscaled?|ai[ .-]?upscaled?", afterTitle: true),

        // Audio: the spatial format, then the first format that matches, lossless first.
        lead(.spatial(.atmos), "atmos", afterTitle: true),
        lead(.spatial(.dtsX), "dts[ .:-]?x", afterTitle: true),
        lead(.audio(.trueHD), "true[ .-]?hd", afterTitle: true),
        lead(.audio(.dtsHDMA), "dts[ .-]?hd[ .-]?(?:ma|master[ .-]?audio)|dts[ .-]?ma", afterTitle: true),
        lead(.audio(.dtsHDHRA), "dts[ .-]?hd[ .-]?(?:hra?|high[ .-]?res(?:olution)?)", afterTitle: true),
        lead(.audio(.dtsHD), "dts[ .-]?hd", afterTitle: true),
        lead(.audio(.flac), "flac", afterTitle: true),
        lead(.audio(.pcm), "l?pcm", afterTitle: true),
        lead(.audio(.ddPlus), "ddp|dd\\+|e[ .-]?ac[ .-]?3|dolby[ .-]?digital[ .-]?plus", afterTitle: true),
        lead(.audio(.dtsES), "dts[ .-]?es", afterTitle: true),
        lead(.audio(.dts), "dts", afterTitle: true),
        lead(.audio(.dd), "dd|ac[ .-]?3|dolby[ .-]?digital", afterTitle: true),
        lead(.audio(.aac), "aac", afterTitle: true),
        lead(.audio(.opus), "opus", afterTitle: true),
        lead(.audio(.mp3), "mp3", afterTitle: true),
    ]

    /// A rule for whole words.
    private static func word(_ term: Term, _ pattern: String, afterTitle: Bool = false) -> Rule {
        Rule(term: term, pattern: regex("(?<![a-z0-9])(?:\(pattern))(?![a-z0-9])"), afterTitle: afterTitle)
    }

    /// A rule for words a number may follow, as an audio format's channels do.
    private static func lead(_ term: Term, _ pattern: String, afterTitle: Bool = false) -> Rule {
        Rule(term: term, pattern: regex("(?<![a-z0-9])(?:\(pattern))(?![a-z])"), afterTitle: afterTitle)
    }

    /// The picture's class `texts` name, by the resolution rules alone, for picking a version
    /// (`VersionTraits`), which asks often.
    static func resolution(in texts: [String]) -> Int? {
        let text = texts.joined(separator: " / ").replacingOccurrences(of: "_", with: " ")
        let range = NSRange(text.startIndex..., in: text)
        for rule in rules {
            guard case .resolution(let lines) = rule.term else { continue }
            if rule.pattern.firstMatch(in: text, range: range) != nil { return lines }
        }
        return nil
    }

    /// Nothing in it matched a rule.
    var saysNothing: Bool {
        resolution == nil && ranges.isEmpty && source == nil && codec == nil && editions.isEmpty && extras.isEmpty
            && spatialAudio == nil && audio == nil
    }

    static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are the table's own: one that doesn't compile is a mistake in it.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // MARK: Around the rules

    /// A year, or an episode's number, after which a name says what the release is.
    private static let titleEnd = regex("(?<![0-9])(?:19|20)[0-9]{2}(?![0-9])|(?<![a-z0-9])s[0-9]{1,2}e[0-9]{1,3}|(?<![0-9])[0-9]{1,2}x[0-9]{2}(?![0-9])")

    /// What follows the title: after the first year or episode number, or all of it without one.
    private static func afterTitle(_ text: String) -> String {
        guard let match = titleEnd.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }
        return String(text[range.upperBound...])
    }

    /// "5.1", "7.1", "2.0" and the like: one digit, a point or a space, and a 0 or 1.
    private static let channelPattern = regex("(?<![0-9])([125-8])[ .]([01])(?![0-9])")

    /// The first layout `text` names, as `AudioLabel` writes one.
    static func channels(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for match in channelPattern.matches(in: text, range: range) {
            let layout = "\(captured(match, in: text, group: 1)).\(captured(match, in: text, group: 2))"
            if let name = AudioLabel.layoutName(layout) { return name }
        }
        return nil
    }

    /// The text of a match's group, or of all of it without one.
    private static func captured(_ match: NSTextCheckingResult, in text: String, group: Int = 1) -> String {
        let range = match.numberOfRanges > group ? match.range(at: group) : match.range
        return Range(range, in: text).map { String(text[$0]) } ?? ""
    }

    /// Words as a name has them, run together with dots or dashes, as a title writes them:
    /// "ultimate.cut" is "Ultimate Cut".
    private static func tidy(_ words: String) -> String {
        words.split { $0 == "." || $0 == "-" || $0 == " " }
            .map { word in word.first.map { String($0).uppercased() + word.dropFirst().lowercased() } ?? "" }
            .joined(separator: " ")
    }

    /// "-GROUP" at the end of a release name, after any "[tags]" there; nil when that's a term,
    /// such as "-DL" of WEB-DL or "-10BIT".
    private static func group(of text: String) -> String? {
        var stem = text.trimmingCharacters(in: .whitespaces)
        while let bracket = stem.range(of: "\\s*\\[[^\\]]*\\]$", options: .regularExpression) {
            stem.removeSubrange(bracket)
        }
        guard let dash = stem.range(of: "-[A-Za-z0-9]{2,}$", options: .regularExpression) else { return nil }
        let group = String(stem[dash].dropFirst())
        let lowered = group.lowercased()
        let terms: Set<String> = ["dl", "rip", "hd", "ma", "es", "hdr", "sdr", "dv", "ray", "matte", "edit"]
        guard !terms.contains(lowered), !lowered.hasSuffix("bit"), group.contains(where: \.isLetter),
              !rules.contains(where: { $0.pattern.firstMatch(in: group, range: NSRange(group.startIndex..., in: group)) != nil })
        else { return nil }
        return group
    }
}

/// A picture's high dynamic range, as release names and Jellyfin's video range call it.
nonisolated enum DynamicRange: Hashable, Sendable {
    case dolbyVision, hdr10Plus, hdr10, hlg
    /// High dynamic range of a kind nothing says.
    case hdr

    var label: String {
        switch self {
        case .dolbyVision: "Dolby Vision"
        case .hdr10Plus: "HDR10+"
        case .hdr10: "HDR10"
        case .hlg: "HLG"
        case .hdr: "HDR"
        }
    }

    /// The ranges Jellyfin's `VideoRangeType` says, Dolby Vision's fallback among them only when
    /// it's HDR10+, which some screens show instead. Nil when it doesn't say: an older server, or
    /// "Unknown". Empty for standard range.
    static func of(rangeType: String?) -> [DynamicRange]? {
        guard let type = rangeType?.uppercased(), !type.isEmpty, type != "UNKNOWN", type != "DOVIINVALID" else { return nil }
        if type.hasPrefix("DOVI") { return type.contains("HDR10PLUS") ? [.dolbyVision, .hdr10Plus] : [.dolbyVision] }
        if type.hasPrefix("HDR10PLUS") { return [.hdr10Plus] }
        if type.hasPrefix("HDR10") { return [.hdr10] }
        if type.hasPrefix("HLG") { return [.hlg] }
        if type == "SDR" { return [] }
        return nil
    }

    /// The ranges a name says, as one picture has them: Dolby Vision keeps HDR10+ beside it,
    /// which some screens show instead, and leaves out the HDR10 every Dolby Vision release falls
    /// back to; a named HDR leaves out a plain "HDR".
    static func distinct(_ ranges: [DynamicRange]) -> [DynamicRange] {
        if ranges.contains(.dolbyVision) { return ranges.filter { $0 == .dolbyVision || $0 == .hdr10Plus } }
        if let named = ranges.first(where: { $0 != .hdr }) { return [named] }
        return ranges
    }
}

/// Where a release came from, the source TRaSH Guides' qualities rank.
nonisolated enum ReleaseSource: Hashable, Sendable {
    case remux, bluRay, webDL, webRip, hdtv, dvd

    var label: String {
        switch self {
        case .remux: "Remux"
        case .bluRay: "Blu-ray"
        case .webDL: "WEB-DL"
        case .webRip: "WEBRip"
        case .hdtv: "HDTV"
        case .dvd: "DVD"
        }
    }
}

nonisolated enum VideoCodec: Hashable, Sendable {
    case av1, hevc, avc, vc1, mpeg2

    var label: String {
        switch self {
        case .av1: "AV1"
        case .hevc: "HEVC"
        case .avc: "AVC"
        case .vc1: "VC-1"
        case .mpeg2: "MPEG-2"
        }
    }

    /// From a video stream's codec as FFmpeg names it.
    init?(stream codec: String?) {
        switch codec?.lowercased() {
        case "av1": self = .av1
        case "hevc", "h265": self = .hevc
        case "h264", "avc": self = .avc
        case "vc1": self = .vc1
        case "mpeg2video", "mpeg2": self = .mpeg2
        default: return nil
        }
    }
}

nonisolated enum SpatialAudio: Hashable, Sendable {
    case atmos, dtsX

    var label: String {
        switch self {
        case .atmos: "Dolby Atmos"
        case .dtsX: "DTS:X"
        }
    }
}

/// An audio format, as people know it: "Dolby TrueHD" for TrueHD, "Dolby Digital Plus" for DD+,
/// E-AC-3 or DDP.
nonisolated enum AudioFormat: Hashable, Sendable {
    case trueHD, dtsHDMA, dtsHDHRA, dtsHD, flac, alac, pcm, ddPlus, dtsES, dts, dd, aac, opus, mp3, mp2, vorbis
    case other(String)

    var label: String {
        switch self {
        case .trueHD: "Dolby TrueHD"
        case .dtsHDMA: "DTS-HD Master Audio"
        case .dtsHDHRA: "DTS-HD High Resolution"
        case .dtsHD: "DTS-HD"
        case .flac: "FLAC"
        case .alac: "ALAC"
        case .pcm: "PCM"
        case .ddPlus: "Dolby Digital Plus"
        case .dtsES: "DTS-ES"
        case .dts: "DTS"
        case .dd: "Dolby Digital"
        case .aac: "AAC"
        case .opus: "Opus"
        case .mp3: "MP3"
        case .mp2: "MP2"
        case .vorbis: "Vorbis"
        case .other(let name): name
        }
    }

    /// DTS of any kind, which a name can tell more of than a stream's codec does.
    var isDTS: Bool {
        switch self {
        case .dtsHDMA, .dtsHDHRA, .dtsHD, .dtsES, .dts: true
        default: false
        }
    }

    /// From an audio stream's codec and profile as FFmpeg names them: "dts" with "DTS-HD MA".
    init?(codec: String?, profile: String?) {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        let profile = profile?.uppercased() ?? ""
        switch codec {
        case "truehd", "mlp": self = .trueHD
        case "eac3": self = .ddPlus
        case "ac3": self = .dd
        case "dts", "dca":
            // FFmpeg's profiles: "DTS-HD MA", "DTS-HD MA + DTS:X", "DTS-HD HRA", "DTS-ES", "DTS 96/24", "DTS Express".
            if profile.contains("HD MA") {
                self = .dtsHDMA
            } else if profile.contains("HRA") {
                self = .dtsHDHRA
            } else if profile.contains("DTS-HD") {
                self = .dtsHD
            } else if profile.contains("DTS-ES") {
                self = .dtsES
            } else {
                self = .dts
            }
        case "aac": self = .aac
        case "flac": self = .flac
        case "alac": self = .alac
        case "opus": self = .opus
        case "mp3": self = .mp3
        case "mp2": self = .mp2
        case "vorbis": self = .vorbis
        case let pcm where pcm.hasPrefix("pcm"): self = .pcm
        default: self = .other(codec.uppercased())
        }
    }
}

// MARK: Versions

/// A version as the pickers show it: the picture's size, "4K", and a few tags for what sets it
/// apart, "Dolby Vision", "Remux", "Director's Cut", with its main audio, "Dolby Atmos · 7.1", and
/// its bitrate, "52 Mbps", which tells apart even files alike in everything else.
/// What Jellyfin measured of the file comes first, its name (`ReleaseName`) where it measured
/// nothing: a range the server read as standard is standard, whatever the name says.
nonisolated struct VersionLabel: Equatable, Sendable {
    /// "4K", "1080p", "720p", "SD". Where nothing tells the size, the version's edition, its
    /// server name when that's a plain word or two such as "Stream", or "Version".
    var title: String
    /// In order: the dynamic range, the source, the codec when it isn't the one a picture of the
    /// size and range is made with anyway, the editions and the extras.
    var tags: [String]
    /// The main audio, "Dolby Atmos · 7.1"; nil when nothing says.
    var audio: String?
    /// Bits per second: as the server measured the file, or failing that its size over its
    /// length. Nil when neither says, as for a remote stream not yet opened.
    var bitrate: Int?
    /// The release group, which tells apart versions alike in all else (`VersionNames`).
    var group: String?

    /// "52 Mbps"
    var bitrateText: String? { bitrate.map(QualityLearning.label(forBitrate:)) }

    init(_ source: MediaSource) {
        let fileName = source.path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? ""
        let names = [source.name ?? "", fileName == source.name ? "" : fileName]
        let release = ReleaseName(names)
        let video = source.videoStream
        let resolution = VersionTraits.resolutionClass(of: source)

        let measured = DynamicRange.of(rangeType: video?.videoRangeType)
            ?? (video?.videoRange?.uppercased() == "SDR" ? [] : nil)
        var ranges = DynamicRange.distinct(measured ?? release.ranges)
        if measured == nil, video?.videoRange?.uppercased() == "HDR", ranges.isEmpty { ranges = [.hdr] }
        let codec = VideoCodec(stream: video?.codec) ?? release.codec
        var tags = ranges.map(\.label)
        if let source = release.source { tags.append(source.label) }
        if let codec, Self.isWorthNaming(codec, resolution: resolution, isHDR: !ranges.isEmpty) { tags.append(codec.label) }
        var editions = release.editions
        if resolution == nil, !editions.isEmpty {
            title = editions.removeFirst()
        } else if let resolution {
            title = Self.resolutionName(resolution)
        } else {
            title = Self.plainName(source.name, release: release) ?? "Version"
        }
        self.tags = tags + editions + release.extras

        let main = source.audioStreams.first { $0.index == source.defaultAudioStreamIndex } ?? source.audioStreams.first
        if let main {
            audio = AudioLabel(main).format
        } else {
            let tags = [release.spatialAudio?.label, release.audio.flatMap { AudioLabel.isImplied($0, by: release.spatialAudio) ? nil : $0.label },
                        release.channels].compactMap(\.self)
            audio = tags.isEmpty ? nil : tags.joined(separator: " · ")
        }
        group = release.group
        bitrate = VersionTraits(source).bitrate ?? Self.estimatedBitrate(of: source)
    }

    /// The bitrate a file's size and length make; nil without both.
    static func estimatedBitrate(of source: MediaSource) -> Int? {
        guard let size = source.plausibleSize, let seconds = source.runtimeSeconds, seconds > 0 else { return nil }
        return Int(Double(size) * 8 / seconds)
    }

    /// "8K", "4K", "1440p", "1080p", "720p", and below that "SD".
    static func resolutionName(_ lines: Int) -> String {
        switch lines {
        case 4320...: "8K"
        case 2160...: "4K"
        case 720...: "\(lines)p"
        default: "SD"
        }
    }

    /// AV1 always, which not every device decodes; HEVC only below 4K and in standard range,
    /// where AVC is the usual; AVC, VC-1 and MPEG-2 never.
    private static func isWorthNaming(_ codec: VideoCodec, resolution: Int?, isHDR: Bool) -> Bool {
        switch codec {
        case .av1: true
        case .hevc: !isHDR && (resolution ?? 0) < 2160
        case .avc, .vc1, .mpeg2: false
        }
    }

    /// The server's name for a version, when it's a plain word or two the rules found nothing
    /// in, such as a remote stream's "Stream"; not its placeholder "Default".
    private static func plainName(_ name: String?, release: ReleaseName) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name != "Default",
              release.saysNothing, name.count <= 24 else { return nil }
        return name.replacingOccurrences(of: ".", with: " ")
    }
}

// MARK: Audio

/// An audio track as the player lists it: "English", with tags for how it sounds, "Dolby Atmos",
/// "7.1". The stream's codec, profile and channels come before what its title says; the title
/// gives what they don't, and anything it says beyond them, as a commentary's "with Ridley Scott",
/// joins the name.
nonisolated struct AudioLabel: Equatable, Sendable {
    /// "English", "English · Commentary by Ridley Scott", "English · Audio Description".
    let title: String
    /// "Dolby Atmos", "Dolby Digital Plus", "5.1": the spatial format, the format unless the
    /// spatial one implies it, and the channels.
    let tags: [String]

    /// "Dolby Atmos · 7.1"; nil when nothing says.
    var format: String? { tags.isEmpty ? nil : tags.joined(separator: " · ") }

    /// "English · Dolby Atmos · 7.1"
    var line: String { ([title] + tags).joined(separator: " · ") }

    /// - Parameters:
    ///   - language: The stream's language code, "eng".
    ///   - name: The title the file gives the track.
    ///   - spatial: The spatial format the stream was measured to carry.
    ///   - fallback: The name with neither a language nor a title, "Track 3".
    init(language: String?, name: String?, codec: String?, profile: String?, channels: Int?, layout: String?,
         spatial measuredSpatial: SpatialAudio?, isCommentary: Bool, describesVideo: Bool, fallback: String) {
        let named = ReleaseName(name ?? "")
        let measured = AudioFormat(codec: codec, profile: profile)
        // The name refines DTS, whose codec is one for every kind, and stands in for a format unknown.
        let format: AudioFormat? = switch (measured, named.audio) {
        case (.dts?, let refined?) where refined.isDTS: refined
        case (nil, let named): named
        case (let measured, _): measured
        }
        let profileText = profile?.uppercased() ?? ""
        var spatial = measuredSpatial
            ?? (profileText.contains("ATMOS") ? .atmos : profileText.contains("DTS:X") ? .dtsX : nil)
        if spatial == nil, let fromName = named.spatialAudio, Self.canCarry(format, fromName) { spatial = fromName }
        let layout = layout.flatMap(Self.layoutName) ?? channels.flatMap(Self.channelsName)
            ?? ReleaseName.channels(in: name ?? "") ?? Self.layoutWord(in: name)
        tags = [spatial?.label, format.flatMap { Self.isImplied($0, by: spatial) ? nil : $0.label }, layout].compactMap(\.self)

        let languageName = Self.languageName(language)
        let leftover = Self.leftover(of: name, language: language, languageName: languageName)
        let describes = describesVideo || AccessibleMedia.namesAudioDescription(name)
        let comments = isCommentary || name?.localizedCaseInsensitiveContains("commentary") == true
        var parts = [languageName ?? leftover ?? fallback]
        if languageName != nil, let leftover { parts.append(leftover) }
        if comments, !(leftover?.localizedCaseInsensitiveContains("commentary") ?? false) { parts.append("Commentary") }
        if describes { parts.append("Audio Description") }
        title = parts.joined(separator: " · ")
    }

    /// One of the server's audio streams.
    init(_ stream: MediaStream, fallback: String = "Audio") {
        let spatial: SpatialAudio? = switch stream.audioSpatialFormat?.lowercased() {
        case "dolbyatmos": .atmos
        case "dtsx": .dtsX
        default: nil
        }
        self.init(language: stream.language, name: stream.title, codec: stream.codec, profile: stream.profile,
                  channels: stream.channels, layout: stream.channelLayout, spatial: spatial, isCommentary: false,
                  describesVideo: stream.isAudioDescription, fallback: fallback)
    }

    /// One of the player's audio tracks.
    init(_ track: TrackInfo) {
        self.init(language: track.language, name: TrackChooser.ownName(of: track), codec: track.codec, profile: track.profile,
                  channels: track.channels, layout: track.channelLayout,
                  spatial: track.isAtmos ? .atmos : track.isDTSX ? .dtsX : nil, isCommentary: track.isCommentary,
                  describesVideo: track.isVisualImpaired, fallback: "Track \(track.id)")
    }

    /// Dolby Atmos implies TrueHD, which carries it on discs, and DTS:X, DTS-HD Master Audio;
    /// Atmos in Dolby Digital Plus, as streaming services send it, is said.
    static func isImplied(_ format: AudioFormat, by spatial: SpatialAudio?) -> Bool {
        switch (spatial, format) {
        case (.atmos?, .trueHD): true
        case (.dtsX?, let format): format.isDTS
        default: false
        }
    }

    /// Whether a stream of `format` can carry `spatial`, as the name says it does.
    private static func canCarry(_ format: AudioFormat?, _ spatial: SpatialAudio) -> Bool {
        guard let format else { return true }
        return switch spatial {
        case .atmos: format == .trueHD || format == .ddPlus
        case .dtsX: format.isDTS
        }
    }

    /// "Stereo", "5.1", for a layout as FFmpeg writes it, "5.1(side)"; nil for one it has no
    /// common name for.
    static func layoutName(_ layout: String) -> String? {
        let base = layout.lowercased().split(separator: "(").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        switch base {
        case "mono", "1.0": return "Mono"
        case "stereo", "2.0": return "Stereo"
        case "2.1", "4.0", "5.0", "5.1", "6.1", "7.1": return base
        default: return nil
        }
    }

    /// "Stereo", "5.1", for a count of channels.
    static func channelsName(_ channels: Int) -> String? {
        switch channels {
        case ...0: nil
        case 1: "Mono"
        case 2: "Stereo"
        case 3: "2.1"
        case 4: "4.0"
        case 5: "5.0"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
    }

    /// "Stereo" or "Mono" as a track's title says it.
    private static func layoutWord(in name: String?) -> String? {
        let words = Set((name ?? "").lowercased().split { !$0.isLetter })
        if words.contains("stereo") { return "Stereo" }
        if words.contains("mono") { return "Mono" }
        return nil
    }

    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Words of a track's title the rest doesn't say already: what's left once the language, the
    /// formats and channels, an audio description's phrases, and filler such as "Surround" or
    /// "Main" are gone. Nil when nothing is.
    private static func leftover(of name: String?, language: String?, languageName: String?) -> String? {
        guard var text = name, !text.isEmpty else { return nil }
        var patterns = ReleaseName.rules.filter {
            if case .spatial = $0.term { return true }
            if case .audio = $0.term { return true }
            return false
        }.map(\.pattern)
        patterns += Self.filler
        if let languageName {
            patterns.append(ReleaseName.regex("(?<![a-z0-9])\(NSRegularExpression.escapedPattern(for: languageName))(?![a-z0-9])"))
        }
        for pattern in patterns {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        let separators = CharacterSet(charactersIn: " -–—|/\\,:;()[]{}_.")
        // The language's code too, "EN" or "ENG", in any case.
        let tidy = text.components(separatedBy: separators)
            .filter { !$0.isEmpty && !($0.count <= 3 && AppSettings.sameLanguage($0, language)) }
            .joined(separator: " ")
        return tidy.isEmpty || tidy.allSatisfy({ !$0.isLetter }) ? nil : tidy
    }

    /// What a track's title says that tells nothing: the channels, bitrates and sample rates, an
    /// audio description's phrases (`AccessibleMedia`), which the title says its own way, and
    /// words such as "Surround" and "Main".
    private static let filler: [NSRegularExpression] = [
        "[0-9]+(?:[.,][0-9]+)?[ ]?(?:kbps|kb/s|kbit/s|mbps|khz|hz|bits?)",
        "[0-9][ .][0-9][ ]?(?:ch(?:annels?)?)?",
        "[0-9]+[ ]?ch(?:annels?)?",
        "audio[ -]?descri(?:ption|bed)|descriptive[ -]?(?:audio|video)|described[ -]?video|video[ -]?description|ad|dvs",
        "surround|stereo|mono|main|default|audio|track|sound|lossless|core|original|dolby|digital|plus|lc|he[ -]?aac(?:v2)?",
    ].map { ReleaseName.regex("(?<![a-z0-9])(?:\($0))(?![a-z0-9])") }
}
