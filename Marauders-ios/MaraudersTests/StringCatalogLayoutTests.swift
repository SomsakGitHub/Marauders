//
//  StringCatalogLayoutTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// What the layout guard says about a catalog's text, on small catalogs written here. The real catalogs are checked in
/// `LocalizationCatalogTests`.
struct StringCatalogLayoutTests {
    private let xcode = """
        {
          "sourceLanguage" : "en",
          "strings" : {
            "Feed" : {
              "localizations" : {
                "th" : {
                  "stringUnit" : {
                    "state" : "translated",
                    "value" : "ฟีด"
                  }
                }
              }
            },
            "Map" : {
              "shouldTranslate" : false
            }
          },
          "version" : "1.0"
        }
        """

    private func problem(_ text: String) -> String? {
        StringCatalogLayout.problem(in: Data(text.utf8))
    }

    @Test func aCatalogInXcodesLayoutHasNoProblem() {
        #expect(problem(xcode) == nil)
    }

    @Test func aPlainJSONDumpIsReportedAtItsFirstLine() throws {
        let plain = xcode.replacingOccurrences(of: " : ", with: ": ")

        let problem = try #require(problem(plain))

        #expect(problem.hasPrefix("line 2 "), Testing.Comment(rawValue: problem))
    }

    @Test func keysOutOfOrderAreReported() throws {
        let unsorted = """
            {
              "sourceLanguage" : "en",
              "strings" : {
                "b" : {
                  "shouldTranslate" : false
                },
                "a" : {
                  "shouldTranslate" : false
                }
              },
              "version" : "1.0"
            }
            """

        let problem = try #require(problem(unsorted))

        #expect(problem.hasPrefix("line 4 "), Testing.Comment(rawValue: problem))
    }

    /// A catalog with these keys, written in Xcode's layout in the order given.
    private func catalog(keys: [String]) -> String {
        let entries = keys.map { "    \"\($0)\" : {\n      \"shouldTranslate\" : false\n    }" }
        return "{\n  \"sourceLanguage\" : \"en\",\n  \"strings\" : {\n" + entries.joined(separator: ",\n")
            + "\n  },\n  \"version\" : \"1.0\"\n}"
    }

    /// Xcode's own catalog editor writes the keys in the order Finder lists names in (case ignored, "@" before "%"),
    /// and it rewrote the catalogs that way on 2026-11-18 when the owner ran the app. `xcrun xcstringstool sync` writes
    /// code point order. A catalog saved by either one is in Xcode's layout.
    @Test func aCatalogInTheOrderTheXcodeEditorWritesHasNoProblem() {
        let keys = ["@handle", "%@ km away", "Change listening language…", "Change Video"]

        #expect(problem(catalog(keys: keys)) == nil)
    }

    @Test func aCatalogInTheOrderTheToolWritesHasNoProblem() {
        // Code point order: "%" (0x25) before "@" (0x40), and "V" (0x56) before "l" (0x6C).
        let keys = ["%@ km away", "@handle", "Change Video", "Change listening language…"]

        #expect(problem(catalog(keys: keys)) == nil)
    }

    /// The project's catalog holds "Clip location" and "Clip Location". The Xcode editor puts the lowercase one first,
    /// the opposite of code point order.
    @Test func keysThatDifferOnlyInCaseHaveTheLowercaseOneFirstInTheEditorOrder() {
        #expect(problem(catalog(keys: ["Clip location", "Clip Location"])) == nil)
    }

    @Test func keysInNeitherOrderAreReported() throws {
        let keys = ["Change Video", "@handle", "%@ km away", "Change listening language…"]

        let problem = try #require(problem(catalog(keys: keys)))

        #expect(problem.hasPrefix("line 4 "), Testing.Comment(rawValue: problem))
    }

    @Test func aNewlineAtTheEndIsReported() {
        #expect(problem(xcode + "\n") == "the file ends with a newline, Xcode writes none")
    }

    @Test func anEmptyEntryHasABlankLineInsideItsBraces() throws {
        let tool = """
            {
              "sourceLanguage" : "en",
              "strings" : {
                "Retry" : {

                }
              },
              "version" : "1.0"
            }
            """

        #expect(problem(tool) == nil)
        #expect(problem(tool.replacingOccurrences(of: "{\n\n    }", with: "{}")) != nil)
    }

    @Test func textIsKeptAsItIsExceptQuotesAndBackslashes() {
        let text = #"""
            {
              "sourceLanguage" : "en",
              "strings" : {
                "Say \"hi\" at C:\\temp/a ไทย" : {
                  "shouldTranslate" : false
                }
              },
              "version" : "1.0"
            }
            """#

        #expect(problem(text) == nil)
    }

    @Test func anEscapedSlashIsReported() {
        let text = #"""
            {
              "sourceLanguage" : "en",
              "strings" : {
                "a\/b" : {
                  "shouldTranslate" : false
                }
              },
              "version" : "1.0"
            }
            """#

        #expect(problem(text) != nil)
    }

    @Test func aFileThatIsNotJSONIsReported() {
        #expect(problem("not a catalog") == "the file is not JSON")
    }
}
