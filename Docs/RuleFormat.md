# MacReaper Rule Format 1.0

Status: draft standard. This document is normative. The key words MUST, MUST NOT,
SHOULD and MAY are used as in RFC 2119. Anything marked *Note* is informative.

The format describes how MacReaper finds cleanup candidates. A single top-down walk
visits file-system entries; **rules** look at each entry and the **scopes** it
inherited from its ancestors, and may push new scopes, **claim** the entry as a
candidate, or **skip** it. Rules are grouped into **rule sets**. A **profile** says
where to walk and which rule sets to use.

---

## 1. Documents

### 1.1 Encoding

- Documents are YAML 1.2, UTF-8, one document per file.
- Rule sets live at `rule-sets/<id>.yaml`, profiles at `profiles/<id>.yaml`. Both
  declare their id in the top-level `id` field, and the file name MUST equal it.
- Every document MUST start with `format: 1`. Loaders MUST reject unknown major formats.
- Unknown keys anywhere are errors. Keys are camelCase.
- Files SHOULD begin with a schema comment so editors validate them:
  `# yaml-language-server: $schema=../schema/rule-set.schema.json`

### 1.2 Identifiers and namespaces

An **id** matches `^[a-z0-9]+(-[a-z0-9]+)*$` (kebab-case, no dots).

There are four namespaces:

| Namespace | Declared by | Qualified form |
|---|---|---|
| Rules | `rules[].id` | `<rule-set>.<id>` (always written qualified) |
| Categories | `categories` keys | `<rule-set>.<id>` |
| Scopes | `pushScope.name` | `<rule-set>.<id>` |
| Checks | the engine (§6) | `<domain>.<id>`; not declared by rule sets |

- A rule's `id` MUST be written qualified and MUST start with its own rule set's id.
- Category and scope references MAY be written bare (`target`), meaning the
  current rule set, or qualified (`node.project`), meaning another rule set.
- A rule set that references another rule set's category or scope MUST list that
  rule set in `requires`. A profile MUST load every rule set its rule sets require.
- *Note:* the same local id may appear in several namespaces. Rule `rust.target`
  claims category `rust.target`; this is intended.

---

## 2. Rule sets

```yaml
format: 1
id: rust                        # equals file name
title: Rust                     # short display name
description: Cargo build output.
requires: []                    # other rule set ids, optional
categories: { ... }             # §3, optional
rules: [ ... ]                  # §4, required (may be empty)
```

**Loading.** The engine loads every rule set the profile names, validates them
together (§9), and scans against that snapshot. Rule sets carry no version: a
change to any rule-set file takes effect only when the engine reloads, and a
reload validates everything again. A reload never affects a scan in progress.

---

## 3. Categories

```yaml
categories:
  target:
    title: Rust build output    # required, shown as the group heading
    detail: Cargo's target directory. Rebuilt on the next cargo build.   # optional
    safety: safe                # required: safe | review | dangerous
```

| Safety | Meaning |
|---|---|
| `safe` | Regenerable without user effort. May be preselected. |
| `review` | Probably fine, but the user should decide. Never preselected by default. |
| `dangerous` | May hold the only copy of data. MUST NOT be preselected; MUST require explicit confirmation. |

Safety is totally ordered: `safe < review < dangerous`.

---

## 4. Rules

```yaml
rules:
  - id: rust.target
    description: The target directory directly inside a crate or workspace root.
    when:
      name: target
      containsAny: [CACHEDIR.TAG, .rustc_info.json]
      scope: { name: project, distance: 1 }
    action:
      claim: target
```

`id`, `when` and `action` are required. `description` is optional but SHOULD be
present; it is shown in the rule debugger.

### 4.1 Conditions (`when`)

`when` is a flat map. It holds when **every** key in it holds. The entry under
evaluation is *E*.

| Key | Type | Holds when |
|---|---|---|
| `kind` | `dir` \| `file` | *E* is of that kind. Default `dir`. |
| `name` | glob \| [glob] | *E*'s name matches any glob (§5.1). |
| `path` | path-glob \| [path-glob] | *E*'s absolute path matches any path-glob (§5.1). |
| `capture` | regex | the regex (§5.2) finds a match in *E*'s name. Named groups become variables. |
| `contains` | child \| [child] | every listed child exists in *E*. |
| `containsAny` | [child] | at least one listed child exists in *E*. |
| `sibling` | template-glob | an entry matching it exists in *E*'s parent (§5.4). |
| `scope` | scope-ref | the scope test (§4.3) holds. |
| `olderThan` | duration | *E*'s content modification time is earlier than now minus the duration (§5.3). |
| `check` | check-call | the check (§6) succeeds and its facts satisfy `expect`. |

- **child**: a glob matched against the names of *E*'s children (files,
  directories and symlinks all count), or a relative path containing `/`, which is
  literal (no wildcards) and tested for existence without following a final symlink.
  `contains`/`containsAny` are false for files.
- There are no boolean combinators. AND is the map itself. For OR, use the list
  forms (`name`, `path`, `containsAny`) or write one rule per alternative: claims on
  the same entry merge (§7.1), so overlapping rules are harmless. There is no negation.

### 4.2 Indexability

Every `when` MUST contain at least one of `name`, `path`, `contains`,
`containsAny`, and each glob used there MUST contain at least one literal character
(`*` alone is rejected). A `kind: file` rule MUST have `name` or `path`. This lets
the engine select candidate rules per entry from an index rather than evaluating
every rule against every entry.

### 4.3 Scope tests

```yaml
scope: project                                    # any distance
scope: { name: node.project, distance: 1 }        # pushed by E's parent
scope: { name: project, maxDistance: 3 }
```

The test finds the **innermost** active scope instance with that qualified name
(the one pushed by the deepest ancestor). It fails if there is none. The
**distance** is `depth(E) - depth(pusher)`; the parent of *E* has distance 1.
`distance` requires equality; `maxDistance` requires `<=`. They are mutually
exclusive.

### 4.4 Actions (`action`)

An action has **exactly one** key.

| Key | Form | Effect |
|---|---|---|
| `pushScope` | `<id>` or `{ name, set }` | Starts a scope instance at *E*, visible to *E*'s descendants only. |
| `claim` | `<category-ref>` or `{ category, set, fallback }` | Makes *E* a candidate in that category. *E*'s descendants are never visited. `fallback` defaults to `false`. |
| `skip` | `true` | *E* is neither claimed nor descended into. |

- `pushScope.name` is a bare id; the scope is declared in the rule's own rule set.
- `set` maps variable names (camelCase) to templates (§5.4).
- A claimed entry is the unit of cleanup, so nothing inside it is evaluated, and
  candidates never nest.

**Well-known variables.** `project` (on a scope or a claim) is the display name
used to group candidates. The innermost source wins: claim, then nearest scope.

---

## 5. Value syntax

### 5.1 Globs

| Token | Matches |
|---|---|
| `*` | any run of characters except `/` |
| `?` | one character except `/` |
| `[abc]` `[a-z]` `[!abc]` | one character in / not in the class |
| `**` | any run of characters including `/` (path-globs only) |
| `\x` | the literal character `x` |

- Globs match the **whole** name or path. No brace expansion; use a list.
- Only `**` matches `/`. `?` and character classes, negated ones included, never do.
- Matching is case-sensitive and compares NFC-normalised strings.
- A path-glob MUST be absolute or start with `~/` (the user's home directory).
- *Note:* a bare `~` is YAML for null. Write the home folder as `"~"`.
- Name globs MUST NOT contain `/`.

### 5.2 Regular expressions

Swift `Regex` syntax. Named groups `(?<var>…)` define variables. The regex is
searched, not anchored; use `^…$` for a full match. It MUST compile at load time.

### 5.3 Durations

`^[0-9]+(s|m|h|d|w)$`, e.g. `90s`, `12h`, `30d`, `8w`.

### 5.4 Templates

A template is a string in which `{var}` is replaced by a variable's value and
`{{` / `}}` produce literal braces.

| Variable | Value |
|---|---|
| `name`, `path`, `parent` | *E*'s name, absolute path, parent path |
| `<group>` | a named group from `capture` |
| `check.<fact>` | a fact returned by the rule's `check` |
| `scope.<ref>.root` | path of the entry that pushed the scope |
| `scope.<ref>.<var>` | a variable the scope set |

Every variable a template uses MUST be provably available when the rule loads:
captures need `capture` in the rule's `when`, check facts need a `check` declaring
that fact, and scope variables need a `scope` condition naming that scope, and
every rule pushing that scope must `set` that variable. `sibling` is resolved
after `capture` and `check`.

---

## 6. Checks

Checks are predicates implemented by the engine. A check either fails (the
condition does not hold) or returns **facts**. `expect` lists facts that must
equal the given values; it MUST only name declared facts, with values of the
declared type. The engine evaluates a check at most once per (entry, name, args).

```yaml
check: cachedir.signature
check: { name: cmake.cache, expect: { valid: true, inSource: false } }
check: { name: version.superseded, args: { pattern: '…' } }
```

| Check | Args | Fails when | Facts |
|---|---|---|---|
| `cachedir.signature` | — | `E/CACHEDIR.TAG` does not start with the standard signature | — |
| `cmake.cache` | — | `E/CMakeCache.txt` unreadable or lacks `CMAKE_CACHEFILE_DIR` / `CMAKE_HOME_DIRECTORY` | `valid: bool` (cache dir resolves to *E*), `inSource: bool` (source dir resolves to *E*), `sourceDir: string`, `sourceExists: bool` (`sourceDir/CMakeLists.txt` exists), `project: string` |
| `xcode.derived-data` | — | `E/info.plist` unreadable or lacks `WorkspacePath` | `workspacePath: string`, `workspaceExists: bool` |
| `version.superseded` | `pattern`: regex with groups `group` and `version` (dot-separated integers) | *E*'s name does not match, or no sibling with the same `group` has a higher `version` | `supersededBy: string` |

New checks are added by later minor versions of this format.

---

## 7. Evaluation

### 7.1 The walk

For each root of the profile (expanded; roots inside other roots are dropped),
the engine visits the root at depth 0 with an empty scope stack. Visiting entry
*E* at depth *d* proceeds in this order:

1. If *E* is a symlink, it is not visited. Symlinks are never followed.
2. If *E* is on a different volume than its root, it is not visited.
3. If *E* matches the profile's `exclude`, it is not visited.
4. If *E* is a directory whose listing fails, a scan error is recorded and *E* is
   not visited further.
5. Candidate rules for *E* are taken from the index and evaluated. Rules whose
   `kind` differs from *E*'s are not evaluated.
6. If any rule that holds has `skip`, stop.
7. **Claims.** If any non-fallback claim holds, fallback claims are discarded. If
   any claim remains, they merge into one candidate (categories unioned, safety the
   strictest after profile overrides, `set` variables merged) and the visit stops.
8. **Scopes.** One scope instance per scope name is created at *E*. If several
   rules push the same name, their `set` maps are merged.
9. If *E* is a directory and *d* < `maxDepth`, visit each child at depth *d*+1
   with the extended scope stack.

Wherever values merge (steps 7 and 8), a conflict on the same variable is resolved
in favour of the rule whose qualified id sorts first.

### 7.2 Guarantees

- **Order independence.** Results MUST NOT depend on rule order, rule-set order or
  directory listing order.
- **Locality.** A rule sees *E*, its children's names, its siblings' names, paths
  read by checks, and inherited scopes. It never sees results from other subtrees,
  so sibling subtrees may be walked in parallel.
- **No nesting.** No candidate lies inside another candidate.
- **Read-only.** Evaluation never modifies the file system.
- **Provenance.** Each candidate records the claiming rule ids, and for every scope
  it inherited: scope name, pushing rule ids and pushing entry.

---

## 8. Profiles

```yaml
format: 1
id: developer
title: Developer projects
roots: ["~/Developer", "~/Projects"]   # "~", ~/…, or an absolute path other than /
exclude: ["~/Developer/archive/**"]   # optional path-globs; matching entries are not visited
maxDepth: 10                          # 1...64
ruleSets: [core, rust, node]
preselect: [safe]                     # subset of [safe, review]
categorySafety:                       # optional; may only make categories stricter
  node.modules: review
```

A root must have a parent directory: the walker lists the parent to learn the root's
own attributes and siblings. `/` is therefore not a valid root.

---

## 9. Validation

A loader MUST reject a document, naming the file and rule, when:

1. it violates the JSON Schema (`schema/*.schema.json`) or has the wrong file name;
   this includes an action with more than one key;
2. an id is duplicated within its namespace, or a rule id lacks its rule set prefix;
3. a category, scope or rule set reference does not resolve, or crosses rule sets
   without `requires`;
4. a check is unknown, gets unknown args, or `expect`s an undeclared fact or a
   value of the wrong type;
5. a regex does not compile, or a template uses a variable that is not provably
   available (§5.4);
6. a rule is not indexable (§4.2);
7. a profile lowers a category's safety, preselects `dangerous`, or omits a rule
   set that one of its rule sets requires.

---

## 10. Style

Rule sets shipped with MacReaper follow this style; user rule sets SHOULD.

- Top-level key order: `format`, `id`, `title`, `description`, `requires`,
  `categories`, `rules` (rule sets) and `format`, `id`, `title`, `roots`, `exclude`,
  `maxDepth`, `ruleSets`, `preselect`, `categorySafety` (profiles).
- Rule key order: `id`, `description`, `when`, `action`.
- Condition key order: `kind`, `name`, `path`, `capture`, `contains`,
  `containsAny`, `sibling`, `scope`, `olderThan`, `check`.
- Use the short forms (`claim: target`, `pushScope: project`) when nothing else is set.
- Rules are ordered: skips, then scope-pushing rules, then claims.
- YAML comments explain *why* a guard exists; `description` explains *what* the rule does.
- Project scopes are named `project` and set `project: "{name}"`.

---

## 11. Reserved for later versions

`action.run` (command-based cleanups such as `xcrun simctl delete unavailable`),
a `json.value` check, and automatic roots derived from `path` rules. Loaders MUST
reject these keys under `format: 1`.
