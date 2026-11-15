import Foundation
import Testing
@testable import vinnyfin

/// A version by its name alone, as a remote stream is before it's opened, or with what the
/// server measured of its file.
private func version(_ name: String?, id: String = UUID().uuidString, path: String? = nil, width: Int? = nil, height: Int? = nil,
                     range: String? = nil, videoRange: String? = nil, codec: String? = nil,
                     audio: [MediaStream] = []) -> MediaSource {
    var source = MediaSource(id: id, name: name)
    source.path = path
    var streams = audio
    if width != nil || range != nil || videoRange != nil || codec != nil {
        var video = MediaStream(type: "Video")
        video.width = width
        video.height = height
        video.videoRangeType = range
        video.videoRange = videoRange
        video.codec = codec
        streams.insert(video, at: 0)
    }
    source.mediaStreams = streams.isEmpty ? nil : streams
    return source
}

private func label(_ name: String) -> VersionLabel {
    VersionLabel(version(name))
}

/// Release names as Radarr and Sonarr leave them, read by the rules alone.
struct ReleaseNameTests {
    @Test func turnsTheMessOfARemuxIntoItsSizeAndWhatItOffers() {
        let remux = label("4k dolby vision bluray REMUX HEVC-DV-HDR10+-10BIT [EN]")
        #expect(remux.title == "4K")
        // HEVC and 10-bit come with Dolby Vision; the language and the brackets say nothing.
        #expect(remux.tags == ["Dolby Vision", "HDR10+", "Remux"])
        #expect(remux.group == nil)
    }

    @Test func readsMovieReleases() {
        let matrix = label("The.Matrix.1999.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.7.1.Atmos-FraMeSToR")
        #expect(matrix.title == "4K")
        #expect(matrix.tags == ["Dolby Vision", "Remux"])
        #expect(matrix.audio == "Dolby Atmos · 7.1")
        #expect(matrix.group == "FraMeSToR")

        let dune = label("Dune.Part.Two.2024.2160p.AMZN.WEB-DL.DDP5.1.Atmos.DV.HDR10Plus.H.265-FLUX")
        #expect(dune.title == "4K")
        #expect(dune.tags == ["Dolby Vision", "HDR10+", "WEB-DL"])
        // Atmos in Dolby Digital Plus, as streaming services send it, says so.
        #expect(dune.audio == "Dolby Atmos · Dolby Digital Plus · 5.1")

        let bladeRunner = label("Blade.Runner.1982.The.Final.Cut.1080p.BluRay.x264.DTS-HD.MA.5.1-DON")
        #expect(bladeRunner.title == "1080p")
        #expect(bladeRunner.tags == ["Blu-ray", "Final Cut"])
        #expect(bladeRunner.audio == "DTS-HD Master Audio · 5.1")

        let aliens = label("Aliens.1986.Special.Edition.REMASTERED.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-FGT")
        #expect(aliens.tags == ["Remux", "Special Edition", "Remastered"])

        let oppenheimer = label("Oppenheimer.2023.IMAX.2160p.WEB-DL.DDP5.1.Atmos.HDR.H.265")
        #expect(oppenheimer.tags == ["HDR", "WEB-DL", "IMAX"])

        let rings = label("The.Lord.of.the.Rings.2001.Extended.Edition.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.DTS-X.7.1")
        #expect(rings.tags == ["Dolby Vision", "Remux", "Extended"])
        #expect(rings.audio == "DTS:X · 7.1")

        #expect(label("Gemini.Man.2019.2160p.HFR.UHD.BluRay.x265.HDR10").tags == ["HDR10", "Blu-ray", "HFR"])
        #expect(label("Avatar.The.Way.of.Water.2022.1080p.3D.HSBS.BluRay.x264").tags == ["Blu-ray", "3D"])
        #expect(label("Back.to.the.Future.1985.2160p.Upscaled.SDR.x265").tags == ["Upscaled"])
    }

    @Test func readsEpisodeReleases() {
        let office = label("The.Office.US.S05E14.Stress.Relief.Extended.720p.WEB-DL.DD5.1.H.264-NTb")
        #expect(office.title == "720p")
        #expect(office.tags == ["WEB-DL", "Extended"])
        #expect(office.audio == "Dolby Digital · 5.1")

        let severance = label("Severance.S02E01.1080p.ATVP.WEB-DL.DDP5.1.HEVC-NTb")
        // HEVC is worth saying at 1080p, where AVC is the usual.
        #expect(severance.tags == ["WEB-DL", "HEVC"])
        #expect(severance.audio == "Dolby Digital Plus · 5.1")

        let old = label("Some.Show.S01E01.SDTV.XviD")
        #expect(old.title == "SD")
        #expect(old.tags == ["HDTV"])

        let av1 = label("Show.S03E07.1080p.WEB-DL.AV1.Opus.5.1")
        #expect(av1.tags == ["WEB-DL", "AV1"])
        #expect(av1.audio == "Opus · 5.1")
    }

    @Test func leavesTheTitlesOwnWordsOut() {
        let gems = label("Uncut.Gems.2019.1080p.WEBRip.x264.AAC2.0-RARBG")
        #expect(gems.tags == ["WEBRip"])
        #expect(gems.audio == "AAC · Stereo")
        #expect(label("Charlotte's Web (2006) 1080p BluRay").tags == ["Blu-ray"])
        #expect(label("Step Up 3D (2010) 1080p BluRay").tags == ["Blu-ray"])
        #expect(label("Mr.Hollands.Opus.1995.1080p.BluRay.x264.DTS-HD.MA.5.1").audio == "DTS-HD Master Audio · 5.1")
    }

    @Test func readsJellyfinsOwnVersionNames() {
        #expect(label("2160p Remux").title == "4K")
        #expect(label("2160p Remux").tags == ["Remux"])
        #expect(label("{edition-Director's Cut} - 1080p").tags == ["Director's Cut"])
        #expect(ReleaseName("Movie (2020) {edition-IMAX Enhanced}").editions == ["IMAX Enhanced"])
        #expect(ReleaseName("Movie.1995.25th.Anniversary.Edition.1080p").editions == ["25th Anniversary Edition"])
        #expect(ReleaseName("Movie.2016.Ultimate.Cut.1080p").editions == ["Ultimate Cut"])
        // Nothing of the picture known: the edition, the server's word for it, or "Version".
        #expect(label("Director's Cut").title == "Director's Cut")
        #expect(label("Stream").title == "Stream")
        #expect(label("Default").title == "Version")
        #expect(VersionLabel(version(nil)).title == "Version")
    }

    @Test func readsTheFilesNameBesideTheVersions() {
        let named = version("1080p", path: "/media/Movies/Heat (1995)/Heat (1995) - 1080p.Directors.Cut.BluRay.mkv")
        #expect(VersionLabel(named).tags == ["Blu-ray", "Director's Cut"])
    }

    @Test func findsTheReleaseGroupButNotATermAtTheEnd() {
        #expect(ReleaseName("Movie.2020.1080p.WEB-DL.DDP5.1.H.264-NTb").group == "NTb")
        #expect(ReleaseName("Movie.2020.1080p.WEB-DL").group == nil)
        #expect(ReleaseName("Movie.2020.2160p.HEVC-10BIT [rarbg]").group == nil)
        #expect(ReleaseName("Spider-Man").group == nil)
    }

    @Test func readsTheSizeTheWayVersionsArePicked() {
        #expect(ReleaseName.resolution(in: ["[Remote] 4K HDR DV"]) == 2160)
        #expect(ReleaseName.resolution(in: ["Movie.1080p.WEB"]) == 1080)
        // A number says the picture's size ahead of a word for the source it came from.
        #expect(ReleaseName.resolution(in: ["Movie.2019.1080p.UHD.BluRay.x264"]) == 1080)
        #expect(ReleaseName.resolution(in: ["Movie_720p_HDTV"]) == 720)
        #expect(ReleaseName.resolution(in: ["DVDRip"]) == 480)
        #expect(ReleaseName.resolution(in: ["Director's Cut"]) == nil)
    }
}

/// What the server measured of a file comes before what its name says.
struct VersionLabelTests {
    @Test func takesTheMeasuredPictureOverTheName() {
        let mislabeled = version("Movie.2020.2160p.HDR10.WEB-DL", width: 1920, height: 1080, range: "SDR", codec: "h264")
        #expect(VersionLabel(mislabeled).title == "1080p")
        #expect(VersionLabel(mislabeled).tags == ["WEB-DL"])

        let both = version("2160p", width: 3840, height: 2160, range: "DOVIWithHDR10Plus", codec: "hevc")
        #expect(VersionLabel(both).tags == ["Dolby Vision", "HDR10+"])
        // The HDR10 every Dolby Vision version falls back to goes unsaid.
        #expect(VersionLabel(version("Remux", width: 3840, height: 2160, range: "DOVIWithHDR10")).tags == ["Dolby Vision", "Remux"])
        #expect(VersionLabel(version(nil, width: 1920, height: 800, range: "HDR10")).title == "1080p")
        #expect(VersionLabel(version(nil, width: 1920, height: 800, range: "HDR10")).tags == ["HDR10"])
    }

    @Test func letsTheNameSayWhichHDRAnOlderServerOnlyCallsHDR() {
        #expect(VersionLabel(version("HDR10+", width: 3840, height: 2160, videoRange: "HDR")).tags == ["HDR10+"])
        #expect(VersionLabel(version(nil, width: 3840, height: 2160, videoRange: "HDR")).tags == ["HDR"])
        #expect(VersionLabel(version("Movie.DV", width: 3840, height: 2160, videoRange: "SDR")).tags.isEmpty)
    }

    @Test func namesTheCodecOnlyWhenItSaysSomething() {
        #expect(VersionLabel(version(nil, width: 1920, height: 1080, range: "SDR", codec: "hevc")).tags == ["HEVC"])
        #expect(VersionLabel(version(nil, width: 3840, height: 2160, range: "SDR", codec: "hevc")).tags.isEmpty)
        #expect(VersionLabel(version(nil, width: 3840, height: 2160, range: "HDR10", codec: "av1")).tags == ["HDR10", "AV1"])
        #expect(VersionLabel(version(nil, width: 1280, height: 720, codec: "h264")).tags.isEmpty)
        #expect(VersionLabel(version(nil, width: 720, height: 576)).title == "SD")
    }

    @Test func takesTheMainAudioFromTheStreams() {
        var atmos = MediaStream(type: "Audio")
        atmos.index = 1
        atmos.codec = "truehd"
        atmos.channels = 8
        atmos.audioSpatialFormat = "DolbyAtmos"
        var commentary = MediaStream(type: "Audio")
        commentary.index = 2
        commentary.codec = "ac3"
        commentary.channels = 2
        var source = version("Movie.2020.1080p.BluRay.DTS", width: 1920, height: 1080, audio: [atmos, commentary])
        #expect(VersionLabel(source).audio == "Dolby Atmos · 7.1")
        source.defaultAudioStreamIndex = 2
        #expect(VersionLabel(source).audio == "Dolby Digital · Stereo")
    }
}

/// Versions are told apart by what sets them apart, however alike their sizes.
struct VersionNamesTests {
    @Test func namesEachByAsFewTagsAsTellItApart() {
        let sources = [
            version("UHD Remux", id: "a", width: 3840, height: 2160, range: "DOVIWithHDR10"),
            version("Movie.2020.2160p.WEB-DL", id: "b", width: 3840, height: 2160, range: "HDR10"),
            version("Movie.2020.1080p.WEB-DL", id: "c", width: 1920, height: 1080, range: "SDR"),
        ]
        let names = VersionNames(sources)
        #expect(sources.map(names.name) == ["4K · Dolby Vision", "4K · HDR10", "1080p"])
        // The rows show every tag.
        #expect(names.label(sources[0]).tags == ["Dolby Vision", "Remux"])
    }

    @Test func tellsApartReleasesAlikeInAllButTheirGroupWhenNothingSaysTheirBitrates() {
        var sources = [version("Show.S01E01.1080p.WEB-DL.DDP5.1.H.264-NTb", id: "a"),
                       version("Show.S01E01.1080p.WEB-DL.DDP5.1.H.264-FLUX", id: "b")]
        let names = VersionNames(sources)
        #expect(names.label(sources[0]).tags == ["WEB-DL", "NTb"])
        #expect(sources.map(names.name) == ["1080p · NTb", "1080p · FLUX"])
        // Their bitrates, which every row shows, tell them apart without the group.
        sources[0].bitrate = 6_000_000
        sources[1].bitrate = 9_000_000
        let measured = VersionNames(sources)
        #expect(measured.label(sources[0]).tags == ["WEB-DL"])
        #expect(sources.map(measured.name) == ["1080p · 6 Mbps", "1080p · 9 Mbps"])
    }

    @Test func tellsApartIdenticalFilesByTheirBitrate() {
        var lighter = version("Movie.2020.1080p.WEB-DL", id: "a", width: 1920, height: 1080)
        lighter.bitrate = 8_261_500
        // No bitrate from the server: the file's size over its length, 3 GB over 40 minutes.
        var heavier = version("Movie.2020.1080p.WEB-DL", id: "b", width: 1920, height: 1080)
        heavier.size = 3_000_000_000
        heavier.runTimeTicks = 40 * 60 * 10_000_000
        let names = VersionNames([lighter, heavier])
        #expect(names.label(lighter).tags == ["WEB-DL"])
        #expect(names.label(heavier).bitrateText == "10 Mbps")
        #expect([lighter, heavier].map(names.name) == ["1080p · 8.3 Mbps", "1080p · 10 Mbps"])
        #expect(names.label(lighter).details == "WEB-DL · 8.3 Mbps")
        #expect(names.label(heavier).caption(size: heavier.plausibleSize) == "10 Mbps · \(Int64(3_000_000_000).formatted(.byteCount(style: .file)))")
        // Without a size and a length, nothing says.
        #expect(VersionLabel(version("1080p", width: 1920, height: 1080)).bitrate == nil)
    }

    @Test func tellsApartVersionsAlikeInEverythingByTheirPlace() {
        let sources = [version(nil, id: "a", width: 1920, height: 1080), version(nil, id: "b", width: 1920, height: 1080)]
        let names = VersionNames(sources)
        #expect(sources.map(names.name) == ["1080p · Version 1", "1080p · Version 2"])
    }

    @Test func titlesTheMenuWithTheSizeAndDetailsTheRest() {
        var source = version("Movie.2020.2160p.BluRay.REMUX.TrueHD.Atmos.7.1", id: "a", width: 3840, height: 2160, range: "DOVIWithHDR10")
        source.size = 40_451_055
        let names = VersionNames([source])
        #expect(names.title(of: source) == "4K · \(Int64(40_451_055).formatted(.byteCount(style: .file)))")
        #expect(names.label(source).details == "Dolby Vision · Remux · Dolby Atmos · 7.1")
        #expect(names.label(source).caption(size: nil) == "Dolby Atmos · 7.1")
    }
}

/// Audio tracks as the player lists them: the language, with tags for how it sounds.
struct AudioLabelTests {
    private func audio(_ language: String?, _ name: String?, codec: String?, profile: String? = nil, channels: Int? = nil,
                       spatial: SpatialAudio? = nil, commentary: Bool = false) -> AudioLabel {
        AudioLabel(language: language, name: name, codec: codec, profile: profile, channels: channels, layout: nil, spatial: spatial,
                   isCommentary: commentary, describesVideo: false, fallback: "Track 2")
    }

    @Test func saysTheLanguageThenHowItSounds() {
        let atmos = audio("eng", nil, codec: "truehd", profile: "Dolby TrueHD + Dolby Atmos", channels: 8)
        #expect(atmos.line == "English · Dolby Atmos · 7.1")
        let streamed = audio("eng", "English - DD+ 5.1 Atmos", codec: "eac3", channels: 6, spatial: .atmos)
        #expect(streamed.title == "English")
        #expect(streamed.tags == ["Dolby Atmos", "Dolby Digital Plus", "5.1"])
        #expect(audio("eng", nil, codec: "dts", profile: "DTS-HD MA + DTS:X", channels: 8).tags == ["DTS:X", "7.1"])
        #expect(audio("eng", nil, codec: "pcm_s24le", channels: 2).tags == ["PCM", "Stereo"])
    }

    @Test func letsTheTitleTellTheKindOfDTS() {
        let master = audio("eng", "DTS-HD MA 5.1", codec: "dts", channels: 6)
        #expect(master.line == "English · DTS-HD Master Audio · 5.1")
    }

    @Test func takesTheMeasuredFormatOverTheTitle() {
        #expect(audio("eng", "DTS-HD MA 5.1", codec: "aac", channels: 2).line == "English · AAC · Stereo")
        #expect(audio("eng", "Atmos", codec: "aac", channels: 2).tags == ["AAC", "Stereo"])
    }

    @Test func keepsWhatTheTitleSaysBeyondTheFormat() {
        let commentary = audio("eng", "Commentary by Ridley Scott", codec: "ac3", channels: 2, commentary: true)
        #expect(commentary.title == "English · Commentary by Ridley Scott")
        #expect(commentary.tags == ["Dolby Digital", "Stereo"])
        #expect(audio("eng", "English Commentary", codec: "ac3", channels: 2).title == "English · Commentary")
        #expect(audio("eng", nil, codec: "ac3", channels: 2, commentary: true).title == "English · Commentary")
        #expect(audio("spa", "Latin American Spanish", codec: "eac3", channels: 6).title == "Spanish · Latin American")
        #expect(audio("eng", "ENG - AC3 2.0", codec: "ac3", channels: 2).line == "English · Dolby Digital · Stereo")
        #expect(audio("eng", "Surround 7.1", codec: "truehd", channels: 8).title == "English")
    }

    @Test func callsAnAudioDescriptionOne() {
        #expect(audio("eng", "Descriptive Audio", codec: "aac", channels: 2).line == "English · Audio Description · AAC · Stereo")
    }

    @Test func readsAnUntaggedTrackByItsTitle() {
        let untagged = audio(nil, "TrueHD Atmos 7.1", codec: nil)
        #expect(untagged.title == "Track 2")
        #expect(untagged.tags == ["Dolby Atmos", "7.1"])
    }

    @Test func readsTheServersStreams() {
        var stream = MediaStream(type: "Audio")
        stream.language = "jpn"
        stream.title = "Japanese"
        stream.codec = "truehd"
        stream.channels = 8
        stream.audioSpatialFormat = "DolbyAtmos"
        #expect(AudioLabel(stream).line == "Japanese · Dolby Atmos · 7.1")
    }
}

/// The Quality panel's choices while a title has a download.
struct DownloadQualityTests {
    @Test func offersTheDownloadInAutosPlace() {
        let uhd = version("2160p", id: "uhd", width: 3840, height: 2160)
        let fullHD = version("1080p", id: "1080", width: 1920, height: 1080)
        #expect(QualityOption.all(sources: [uhd, fullHD], playing: uhd, download: true)
            == [.download, .version(uhd), .version(fullHD), .converted(.fullHD), .converted(.hd), .converted(.sd)])
    }

    @Test func carriesTheVeryStreamsOnlyBetweenCopiesNumberedAlike() {
        var english = MediaStream(type: "Audio")
        english.index = 1
        english.codec = "truehd"
        english.language = "eng"
        var server = MediaSource(id: "v")
        server.mediaStreams = [MediaStream(type: "Video"), english]
        // A download the server converted numbers the same audio its own way, as AAC.
        var converted = server
        var aac = english
        aac.codec = "aac"
        converted.mediaStreams = [MediaStream(type: "Video"), aac]
        let chosen = TrackSelection(audio: TrackChooser.Candidate(english), subtitle: nil,
                                    streams: .init(mediaSourceId: "v", audio: 1, subtitle: nil))
        #expect(chosen.carried(from: server, to: server).exactAudioIndex(in: server) == 1)
        #expect(chosen.carried(from: converted, to: server).exactAudioIndex(in: server) == nil)
        #expect(chosen.carried(from: converted, to: server).audio == chosen.audio)
    }

    @MainActor
    @Test func goesBackToTheDownloadFromWhereTheStreamIs() throws {
        let defaults = try #require(UserDefaults(suiteName: "DownloadQualityTests-\(UUID().uuidString)"))
        let history = WatchHistory(file: FileManager.default.temporaryDirectory.appending(path: "Quality-\(UUID().uuidString).json"))
        var movie = JellyfinItem(id: "m", name: "Heat", type: "Movie")
        let downloaded = version("1080p", id: "m", width: 1920, height: 1080)
        movie.mediaSources = [downloaded]
        movie.userData = UserItemData(playbackPositionTicks: 600 * 10_000_000)
        let file = URL(filePath: "/tmp/heat.mkv")
        let resolver = PlaybackResolver(accounts: AccountStore(defaults: defaults), settings: AppSettings(defaults: defaults),
                                        history: history) { id, _ in
            id == "m" ? PlaybackResolver.DownloadedCopy(url: file, item: movie, segments: []) : nil
        }
        #expect(resolver.downloadedVersion(of: "m") == downloaded)
        #expect(resolver.downloadedVersion(of: "other") == nil)
        let resolved = try #require(resolver.download(of: "m", title: "Heat", from: 1234))
        #expect(resolved.isDownload)
        #expect(resolved.url == file)
        // Where the stream had got to, not where the title was last left.
        #expect(resolved.startPosition == 1234)
        #expect(!resolved.resumesSavedPosition)
    }
}
