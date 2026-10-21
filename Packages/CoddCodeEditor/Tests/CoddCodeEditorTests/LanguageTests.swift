import Foundation
import Testing
@testable import CoddCodeEditor

@Suite("Language detection")
struct LanguageDetectorTests {
    @Test(arguments: [
        ("punch.vue", CodeLanguage.vue), ("main.js", .javascript), ("vite.config.mjs", .javascript), ("api.ts", .typescript),
        ("types.d.ts", .typescript), ("App.jsx", .jsx), ("Card.tsx", .tsx), ("package.json", .json), ("tsconfig.jsonc", .json),
        ("style.css", .css), ("theme.scss", .scss), ("index.html", .html), ("Info.plist", .xml), ("icon.svg", .xml),
        ("README.md", .markdown), ("App.swift", .swift), ("export.py", .python), ("run.sh", .shell), ("setup.zsh", .shell),
        ("ci.yml", .yaml), ("docker-compose.yaml", .yaml), ("Cargo.toml", .toml), ("main.go", .go), ("lib.rs", .rust),
        ("x.c", .c), ("x.h", .c), ("x.cpp", .cpp), ("x.hpp", .cpp), ("View.m", .objc), ("View.mm", .objc),
        ("Main.java", .java), ("App.kt", .kotlin), ("build.gradle.kts", .kotlin), ("app.rb", .ruby), ("index.php", .php),
        ("schema.sql", .sql), ("notes.txt", .plain), ("unknown.zzz", .plain),
        ("Makefile", .shell), ("GNUmakefile", .shell), ("Dockerfile", .shell), ("Dockerfile.dev", .shell), (".zshrc", .shell),
        (".bashrc", .shell), (".env.local", .shell), ("Gemfile", .ruby), ("Podfile", .ruby), ("Cargo.lock", .toml),
        (".editorconfig", .toml), (".prettierrc", .json), ("src/pages/punch.vue", .vue), ("PUNCH.VUE", .vue),
    ])
    func byName(name: String, expected: CodeLanguage) {
        #expect(CodeLanguageDetector.language(fileName: name, firstLine: nil) == expected)
    }

    @Test(arguments: [
        ("#!/usr/bin/env node", CodeLanguage.javascript), ("#!/usr/bin/env python3", .python), ("#!/usr/bin/python3.12", .python),
        ("#!/bin/zsh", .shell), ("#!/bin/sh -e", .shell), ("#!/usr/bin/env -S deno run --allow-read", .typescript),
        ("#!/usr/bin/env ruby", .ruby), ("#!/usr/bin/env bash", .shell), ("<?xml version=\"1.0\"?>", .xml),
        ("<!DOCTYPE html>", .html), ("<?php", .php), ("#!/usr/bin/env perl", .plain), ("hello", .plain),
    ])
    func byFirstLine(line: String, expected: CodeLanguage) {
        #expect(CodeLanguageDetector.language(fileName: "script", firstLine: line) == expected)
    }

    @Test func extensionWinsOverShebang() {
        #expect(CodeLanguageDetector.language(fileName: "tool.py", firstLine: "#!/bin/sh") == .python)
    }

    @Test func displayNames() {
        #expect(CodeLanguage.vue.displayName == "Vue")
        #expect(CodeLanguage.javascript.displayName == "JavaScript")
        #expect(CodeLanguage.plain.displayName == "Plain Text")
        #expect(Set(CodeLanguage.allCases.map(\.displayName)).count == CodeLanguage.allCases.count)
    }
}
