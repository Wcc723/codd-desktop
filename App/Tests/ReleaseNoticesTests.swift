import Foundation
import Testing
@testable import CODD

// Open-source release (pre-publication audit LIC-2 / LIC-3): the built app carries the license of
// everything it ships. Reads the test host's own bundle only.

@Suite("Release notices")
struct ReleaseNoticesTests {
    /// Contents/Resources/THIRD-PARTY-NOTICES.md (what 關於 › 第三方元件授權 opens) has a section per
    /// component, and the OFL texts sit next to the fonts in Contents/Resources/Fonts.
    @Test func theAppBundleCarriesTheNoticesAndTheFontLicenses() throws {
        // The test host is the built CODD.app.
        let notices = try #require(Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"))
        let text = try String(contentsOf: notices, encoding: .utf8)
        for name in ["libghostty-spm", "Ghostty", "DisplayLink", "GRDB.swift", "Oniguruma", "simdutf", "Highway", "Wuffs",
                     "libxev", "libvaxis", "z2d", "zig-objc", "zf", "uucode", "Zig standard library", "GNU libintl",
                     "JetBrains Mono", "Space Mono", "Symbols Nerd Font"] {
            #expect(text.contains("\n## \(name)") || text.contains("\n### \(name)"), "no section for \(name)")
        }
        #expect(text.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
        // Review RV-1 / RV-2: z2d's MPL text and the Unicode license ship too, and the copyleft sources are offered.
        #expect(text.contains("Mozilla Public License Version 2.0") && text.contains("UNICODE LICENSE V3"))
        #expect(text.contains("\n## Source of the MPL-2.0 and LGPL-2.1 parts") && text.contains("gettext-0.24.tar.gz"))
        #expect(text.contains("CODD 是個人開發的非官方工具，與 Anthropic 無關"))
        let fonts = try #require(Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true))
        for (file, copyright) in [("OFL-JetBrainsMono.txt", "Copyright 2020 The JetBrains Mono Project Authors"),
                                  ("OFL-SpaceMono.txt", "Copyright 2016 Google Inc.")] {
            let license = try String(contentsOf: fonts.appendingPathComponent(file), encoding: .utf8)
            #expect(license.hasPrefix(copyright), "\(file)")
            #expect(license.contains("SIL OPEN FONT LICENSE Version 1.1"), "\(file)")
        }
    }
}
