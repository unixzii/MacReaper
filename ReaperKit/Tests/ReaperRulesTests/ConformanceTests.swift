import ReaperEngine
import ReaperRules
import Testing

@Suite("Conformance corpus")
struct ConformanceTests {

    @Test("Case", arguments: ConformanceCase.names)
    func conformanceCase(_ name: String) throws {
        let testCase = try ConformanceCase.load(name)
        let result = Result { () throws(RuleDiagnostics) in try RuleLoader.load(testCase.sources) }

        switch (testCase.expect, result) {
        case (.valid, .success):
            break
        case (.valid, .failure(let diagnostics)):
            Issue.record("\(testCase.description)\nExpected no diagnostics, got:\n\(diagnostics)")
        case (.rejected(let code, let file, _), .success):
            Issue.record("\(testCase.description)\nExpected \(code) in \(file), but everything loaded")
        case (.rejected(let code, let file, let line), .failure(let diagnostics)):
            let match = diagnostics.diagnostics.contains { diagnostic in
                diagnostic.code.rawValue == code
                    && diagnostic.location.file == file
                    && (line == nil || diagnostic.location.line == line)
            }
            #expect(match, "\(testCase.description)\nExpected \(code) at \(file):\(line.map(String.init) ?? "?"), got:\n\(diagnostics)")
        }
    }

    @Test("Every diagnostic code has a case")
    func everyCodeIsCovered() throws {
        let names = ConformanceCase.names
        #expect(!names.isEmpty, "No cases found in \(ConformanceCase.directory.path(percentEncoded: false))")

        var covered: Set<String> = []
        for name in names {
            if case .rejected(let code, _, _) = try ConformanceCase.load(name).expect {
                covered.insert(code)
            }
        }
        let expected = Set(DiagnosticCode.allCases.map(\.rawValue))
        #expect(expected.subtracting(covered).isEmpty, "Codes without a case: \(expected.subtracting(covered).sorted())")
        #expect(covered.subtracting(expected).isEmpty, "Cases with unknown codes: \(covered.subtracting(expected).sorted())")
    }
}
