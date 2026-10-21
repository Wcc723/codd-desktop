import Foundation

/// The languages the code view highlights (D28). `plain` has no lexer.
public enum CodeLanguage: String, Sendable, CaseIterable {
    case vue, javascript, typescript, jsx, tsx, json, css, scss, html, xml, markdown, swift, python, shell, yaml, toml,
         go, rust, c, cpp, objc, java, kotlin, ruby, php, sql, plain

    /// The status bar's language item (the artboard's `Vue`); VS Code's names.
    public var displayName: String {
        switch self {
        case .vue: "Vue"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .jsx: "JavaScript JSX"
        case .tsx: "TypeScript JSX"
        case .json: "JSON"
        case .css: "CSS"
        case .scss: "SCSS"
        case .html: "HTML"
        case .xml: "XML"
        case .markdown: "Markdown"
        case .swift: "Swift"
        case .python: "Python"
        case .shell: "Shell Script"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .go: "Go"
        case .rust: "Rust"
        case .c: "C"
        case .cpp: "C++"
        case .objc: "Objective-C"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .sql: "SQL"
        case .plain: "Plain Text"
        }
    }
}

/// Picks a file's language from its name and first line: special names first (`Makefile`,
/// `Dockerfile`, `.zshrc`), then the extension, then a shebang or an XML / HTML / PHP prologue for
/// files without a known extension; `plain` otherwise. Names without a dedicated lexer map to the
/// closest one (Makefile and Dockerfile to `shell`, INI-style files to `toml`).
public enum CodeLanguageDetector {
    public static func language(fileName: String, firstLine: String?) -> CodeLanguage {
        let name = (fileName as NSString).lastPathComponent
        let lower = name.lowercased()
        if let special = specialNames[lower] { return special }
        if lower.hasPrefix(".env") || lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") { return .shell }
        if lower.hasPrefix("makefile") || lower == "gnumakefile" { return .shell }
        let ext = (lower as NSString).pathExtension
        if !ext.isEmpty, let known = extensions[ext] { return known }
        if let firstLine, let sniffed = sniff(firstLine) { return sniffed }
        return .plain
    }

    /// `#!/usr/bin/env node`, `#!/bin/zsh`, `#!/usr/bin/env -S deno run`, `<?xml`, `<!DOCTYPE html>`, `<?php`.
    static func sniff(_ line: String) -> CodeLanguage? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#!") {
            var words = trimmed.dropFirst(2).split(separator: " ").map(String.init)
            guard !words.isEmpty else { return nil }
            var program = (words.removeFirst() as NSString).lastPathComponent
            if program == "env" {
                // Skip env's own options (`-S`, `-i`, `VAR=value`).
                while let next = words.first, next.hasPrefix("-") || next.contains("=") { words.removeFirst() }
                guard let next = words.first else { return nil }
                program = (next as NSString).lastPathComponent
            }
            return interpreter(program)
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<?xml") { return .xml }
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") { return .html }
        if lower.hasPrefix("<?php") { return .php }
        return nil
    }

    private static func interpreter(_ program: String) -> CodeLanguage? {
        // `python3.12`, `ruby3.3`, `node18`: the name without its version.
        let base = String(program.prefix { !$0.isNumber && $0 != "." })
        switch base {
        case "sh", "bash", "zsh", "ksh", "dash", "fish", "ash", "mksh": return .shell
        case "python", "pypy": return .python
        case "node", "nodejs", "bun", "qjs": return .javascript
        case "deno", "ts-node", "tsx": return .typescript
        case "ruby", "jruby": return .ruby
        case "php": return .php
        case "swift": return .swift
        default: return nil
        }
    }

    private static let specialNames: [String: CodeLanguage] = [
        ".zshrc": .shell, ".zshenv": .shell, ".zprofile": .shell, ".zlogin": .shell, ".zlogout": .shell,
        ".bashrc": .shell, ".bash_profile": .shell, ".bash_login": .shell, ".bash_logout": .shell, ".profile": .shell,
        ".envrc": .shell, ".gitignore": .shell, ".dockerignore": .shell, ".npmignore": .shell, ".gitattributes": .shell,
        "pkgbuild": .shell, "apkbuild": .shell,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "fastfile": .ruby, "appfile": .ruby, "brewfile": .ruby,
        "vagrantfile": .ruby, "guardfile": .ruby, "dangerfile": .ruby, "gemfile.lock": .plain, "podfile.lock": .yaml,
        ".babelrc": .json, ".eslintrc": .json, ".prettierrc": .json, ".swcrc": .json, ".jshintrc": .json,
        "cargo.lock": .toml, "pipfile": .toml, "poetry.lock": .toml, "uv.lock": .toml,
        ".editorconfig": .toml, ".gitconfig": .toml, ".gitmodules": .toml, ".npmrc": .toml, ".yarnrc": .yaml,
        ".clang-format": .yaml, ".clang-tidy": .yaml, ".swiftlint.yml": .yaml,
        "cmakelists.txt": .plain, "license": .plain, "readme": .markdown,
    ]

    private static let extensions: [String: CodeLanguage] = [
        "vue": .vue,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript,
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "jsx": .jsx, "tsx": .tsx,
        "json": .json, "jsonc": .json, "json5": .json, "webmanifest": .json, "code-workspace": .json, "map": .json,
        "css": .css, "pcss": .css, "postcss": .css,
        "scss": .scss, "sass": .scss, "less": .scss,
        "html": .html, "htm": .html, "xhtml": .html, "shtml": .html,
        "xml": .xml, "plist": .xml, "svg": .xml, "xsd": .xml, "xsl": .xml, "xslt": .xml, "storyboard": .xml,
        "xib": .xml, "entitlements": .xml, "csproj": .xml, "xcscheme": .xml, "rss": .xml, "atom": .xml,
        "md": .markdown, "markdown": .markdown, "mdx": .markdown, "mkd": .markdown, "mdown": .markdown,
        "swift": .swift,
        "py": .python, "pyw": .python, "pyi": .python, "gyp": .python,
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell, "fish": .shell, "command": .shell,
        "env": .shell, "mk": .shell, "mak": .shell,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml, "ini": .toml, "cfg": .toml, "conf": .toml, "properties": .toml,
        "go": .go,
        "rs": .rust,
        "c": .c, "h": .c,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "c++": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp, "h++": .cpp,
        "ino": .cpp, "ipp": .cpp, "tpp": .cpp, "cu": .cpp, "metal": .cpp,
        "m": .objc, "mm": .objc,
        "java": .java,
        "kt": .kotlin, "kts": .kotlin,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby, "ru": .ruby, "podspec": .ruby, "jbuilder": .ruby,
        "php": .php, "phtml": .php, "php3": .php, "php4": .php, "php5": .php, "phps": .php,
        "sql": .sql, "psql": .sql, "ddl": .sql, "pgsql": .sql,
        "txt": .plain, "text": .plain, "log": .plain,
    ]
}
