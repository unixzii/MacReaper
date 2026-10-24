# Conformance corpus

Each `*.yaml` file here is one case for the validation rules in
[Docs/RuleFormat.md](../../../../Docs/RuleFormat.md). `ConformanceTests` runs every case, and
checks that every diagnostic code has at least one.

```yaml
description: "What the case is about."
expect:                  # or `expect: valid`
  code: unknown-category # a DiagnosticCode raw value
  file: rule-sets/t.yaml # the file the diagnostic points into
  line: 30               # optional; 1-based line of the offending value or key
files:                   # the rule sets to load, by path
  rule-sets/t.yaml: |
    ...
```

Every case loads all of its rule sets together. A rejecting case must produce a diagnostic with the
expected code in the expected file, and at the expected line when one is given; other
diagnostics may accompany it.
