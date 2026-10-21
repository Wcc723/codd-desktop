import Foundation
import Testing
@testable import CoddMCP

@Suite("tools/list")
struct ToolsListTests {
    func tools(writeEnabled: Bool, version: String? = "2025-11-25") async throws -> [JSON] {
        var canned = FakeBackend.Canned()
        canned.writeEnabled = writeEnabled
        let reply = try await Fixture.server(FakeBackend(canned)).reply(Wire.rpc("tools/list"), version: version)
        #expect(reply["result"]?["nextCursor"] == nil)
        return try #require(reply["result"]?["tools"]?.array)
    }

    func tool(_ tools: [JSON], _ name: String) throws -> JSON {
        try #require(tools.first { $0["name"]?.string == name }, "\(name) missing")
    }

    @Test func notesWriteFollowsTheCapability() async throws {
        let off = try await tools(writeEnabled: false).compactMap { $0["name"]?.string }
        #expect(off == ["notes_search", "notes_list", "notes_read", "notes_append", "notes_create"])
        let on = try await tools(writeEnabled: true).compactMap { $0["name"]?.string }
        #expect(on == ["notes_search", "notes_list", "notes_read", "notes_append", "notes_create", "notes_write"])
    }

    @Test func annotationsAndMeta() async throws {
        let tools = try await tools(writeEnabled: true)
        for name in ["notes_search", "notes_list", "notes_read"] {
            let annotations = try tool(tools, name)["annotations"]
            #expect(annotations?["readOnlyHint"] == true, "\(name)")
            #expect(annotations?["destructiveHint"] == false, "\(name)")
            #expect(annotations?["openWorldHint"] == false, "\(name)")
        }
        #expect(try tool(tools, "notes_search")["_meta"] == ["anthropic/alwaysLoad": true])
        #expect(try tool(tools, "notes_read")["_meta"] == ["anthropic/alwaysLoad": true,
                                                           "anthropic/maxResultSizeChars": 200_000])
        #expect(try tool(tools, "notes_list")["_meta"] == nil)
        #expect(try tool(tools, "notes_append")["_meta"] == nil)
        // notes_create keeps Claude's normal permission prompt (the user may always-allow it).
        let create = try tool(tools, "notes_create")
        #expect(create["_meta"] == nil)
        #expect(create["annotations"]?["readOnlyHint"] == false && create["annotations"]?["destructiveHint"] == false)
        #expect(create["annotations"]?["idempotentHint"] == false)
        let append = try tool(tools, "notes_append")["annotations"]
        #expect(append?["readOnlyHint"] == false && append?["destructiveHint"] == false)
        let write = try tool(tools, "notes_write")
        #expect(write["annotations"]?["destructiveHint"] == true)
        #expect(write["annotations"]?["readOnlyHint"] == false)
        #expect(write["_meta"] == ["anthropic/requiresUserInteraction": true])
    }

    /// Every schema is a JSON Schema object shape: `type: object`, `properties` of typed members,
    /// `required` naming existing properties, defaults inside their bounds.
    @Test func inputSchemasAreWellFormed() async throws {
        for version in ["2025-03-26", "2025-06-18", "2025-11-25"] {
            for tool in try await tools(writeEnabled: true, version: version) {
                let name = tool["name"]?.string ?? "?"
                #expect((tool["description"]?.string?.count ?? 0) > 40, "\(name)")
                #expect((tool["description"]?.string?.count ?? 5000) < 1000, "\(name)")
                for key in ["inputSchema"] + (tool["outputSchema"] == nil ? [] : ["outputSchema"]) {
                    let schema = try #require(tool[key], "\(name) \(key)")
                    try checkSchema(schema, path: "\(name).\(key)")
                    #expect(schema["type"] == "object")
                }
            }
        }
    }

    func checkSchema(_ schema: JSON, path: String) throws {
        let types: Set<String> = ["object", "array", "string", "integer", "number", "boolean"]
        let type = try #require(schema["type"]?.string, "\(path) has no type")
        #expect(types.contains(type), "\(path) type \(type)")
        if type == "object" {
            let properties = try #require(schema["properties"]?.object, "\(path) has no properties")
            for member in properties.members { try checkSchema(member.value, path: path + "." + member.key) }
            for required in schema["required"]?.array ?? [] {
                let name = try #require(required.string)
                #expect(properties[name] != nil, "\(path) requires missing \(name)")
            }
        }
        if type == "array" { try checkSchema(try #require(schema["items"], "\(path) has no items"), path: path + "[]") }
        if type == "integer", let def = schema["default"]?.int {
            if let min = schema["minimum"]?.int { #expect(def >= min, "\(path)") }
            if let max = schema["maximum"]?.int { #expect(def <= max, "\(path)") }
        }
        if let values = schema["enum"]?.array, let def = schema["default"] { #expect(values.contains(def), "\(path)") }
        for key in schema.object?.keys ?? [] {
            #expect(["type", "properties", "required", "items", "description", "enum", "default", "minimum",
                     "maximum", "minLength", "maxLength"].contains(key), "\(path) uses \(key)")
        }
    }

    @Test func documentedLimitsAppearInSchemas() async throws {
        let tools = try await tools(writeEnabled: true)
        let read = try tool(tools, "notes_read")["inputSchema"]?["properties"]
        #expect(read?["max_chars"]?["minimum"]?.int == 1000)
        #expect(read?["max_chars"]?["maximum"]?.int == 50000)
        #expect(read?["max_chars"]?["default"]?.int == 12000)
        #expect(read?["include_images"]?["default"] == true)
        let search = try tool(tools, "notes_search")["inputSchema"]?["properties"]
        #expect(search?["scope"]?["default"] == "all")
        #expect(search?["scope"]?["enum"] == ["all", "project"])
        #expect(search?["limit"]?["maximum"]?.int == 20 && search?["limit"]?["default"]?.int == 10)
        let list = try tool(tools, "notes_list")["inputSchema"]?["properties"]
        #expect(list?["limit"]?["maximum"]?.int == 50 && list?["limit"]?["default"]?.int == 20)
        #expect(list?["days"]?["default"] == nil)
        let append = try tool(tools, "notes_append")["inputSchema"]
        #expect(append?["properties"]?["markdown"]?["maxLength"]?.int == 20000)
        #expect(append?["required"] == ["ref", "markdown"])
        #expect(try tool(tools, "notes_read")["inputSchema"]?["required"] == ["ref"])
        #expect(try tool(tools, "notes_search")["inputSchema"]?["required"] == ["query"])
        let create = try tool(tools, "notes_create")["inputSchema"]
        #expect(create?["required"] == ["title", "body"])
        #expect(create?["properties"]?["title"]?["maxLength"]?.int == 200)
        #expect(create?["properties"]?["kind"]?["enum"] == ["note", "prompt"])
        #expect(create?["properties"]?["kind"]?["default"] == "note")
    }

    @Test func descriptionsMentionTraditionalChinese() async throws {
        let tools = try await tools(writeEnabled: false)
        for name in ["notes_search", "notes_read"] {
            #expect(try tool(tools, name)["description"]?.string?.contains("繁體中文") == true)
        }
    }

    @Test func outputSchemaOnlyForSearchAndListFrom20250618() async throws {
        let modern = try await tools(writeEnabled: true, version: "2025-06-18")
        #expect(modern.filter { $0["outputSchema"] != nil }.compactMap { $0["name"]?.string } == ["notes_search", "notes_list"])
        #expect(modern.allSatisfy { $0["title"]?.string != nil })
        let legacy = try await tools(writeEnabled: true, version: "2025-03-26")
        #expect(legacy.allSatisfy { $0["outputSchema"] == nil && $0["title"] == nil })
        #expect(legacy.allSatisfy { $0["annotations"]?["title"]?.string != nil })
    }
}
