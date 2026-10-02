// Validate opencode.json against the JSON Schema its own $schema points at.
//
// Issue #11 version-controls the opencode permission policy and installs it as
// the user-level config, so the same rules apply on every machine and in every
// repo the driver works on. The rules themselves are a human decision (see
// AGENTS.md), so nothing about them is asserted here - a test that pinned them
// would only produce merge conflicts and false failures. This check does one
// thing: prove that opencode.json is valid JSON and conforms to the schema it
// declares. Ajv does the validating, so a schema change (new tools, renamed
// keys, different actions) is picked up automatically and there is no
// hand-written validation logic to review against the schema.
//
// The schema lives at https://opencode.ai/config.json. It is fetched at run
// time and cached in .cache/schema/schemas.json, so a run without network still
// works. Override the root schema source with OPENCODE_CONFIG_SCHEMA (a URL).
//
// Two fixed paths are read and one is written: opencode.json and the cache
// file. A schema URL - which is data, not code: it comes from opencode.json or
// from an external $ref inside a downloaded schema - is only ever handed to
// fetch(), never spliced into a path, so neither a hostile $schema nor a
// hostile $ref can pick which file this script reads or writes.
//
// Run: node test/opencode-config.js   (or: npm run test:config)
"use strict"

const fs = require("node:fs")
const path = require("node:path")
const Ajv2020 = require("ajv/dist/2020").default

const repoRoot = path.join(__dirname, "..")
const configPath = path.join(repoRoot, "opencode.json")
const cacheDir = path.join(repoRoot, ".cache", "schema")
// One cache file for every schema this run needs: the root schema plus the
// $refs Ajv resolves while compiling it. Keys are URLs, values are documents.
const cachePath = path.join(cacheDir, "schemas.json")

function fail(message) {
  console.error(`opencode-config: ${message}`)
  process.exit(1)
}

function readJsonFile(file, what) {
  let raw
  try {
    raw = fs.readFileSync(file, "utf8")
  } catch (err) {
    fail(`cannot read ${what} (${file}): ${err.message}`)
  }
  try {
    return JSON.parse(raw)
  } catch (err) {
    fail(`${what} is not valid JSON: ${err.message}`)
  }
}

function readCache() {
  if (!fs.existsSync(cachePath)) return {}
  const cache = readJsonFile(cachePath, "the schema cache")
  if (!cache || typeof cache !== "object" || Array.isArray(cache)) {
    fail(`the schema cache (${cachePath}) is not a JSON object; delete it and rerun`)
  }
  return cache
}

function writeCache(cache) {
  fs.mkdirSync(cacheDir, { recursive: true })
  fs.writeFileSync(cachePath, `${JSON.stringify(cache, null, 2)}\n`)
}

// A schema document by URL, from the cache when it is there (so a run without
// network keeps working) and from the network otherwise. Anything downloaded
// is added to `cache` for the next run.
async function loadSchema(uri, cache) {
  if (Object.prototype.hasOwnProperty.call(cache, uri)) return cache[uri]
  let res
  try {
    if (typeof fetch !== "function") throw new Error("node 18 or newer is required to fetch the schema")
    res = await fetch(uri)
  } catch (err) {
    fail(`cannot fetch ${uri}: ${err.message} (no cached copy under ${cachePath})`)
  }
  if (!res.ok) fail(`cannot fetch ${uri}: HTTP ${res.status} (no cached copy under ${cachePath})`)
  let body
  try {
    body = await res.text()
  } catch (err) {
    fail(`cannot read ${uri}: ${err.message} (no cached copy under ${cachePath})`)
  }
  let schema
  try {
    schema = JSON.parse(body)
  } catch (err) {
    fail(`${uri} did not return JSON: ${err.message}`)
  }
  cache[uri] = schema
  return schema
}

// Ajv reports every failing `anyOf` branch. The opencode schema is full of
// them, so one typo produces lines like "/permission must be string" for a key
// that *is* an object, plus a "must match a schema in anyOf" summary. Drop the
// errors that merely sit on an ancestor of a more specific one and keep the
// rest, so the report names the actual mistake. This only touches how errors
// are printed - the verdict still comes from Ajv.
function specificErrors(errors) {
  const seen = new Set()
  const kept = []
  for (const err of errors) {
    const key = `${err.instancePath}\u0000${err.message}`
    if (seen.has(key)) continue
    seen.add(key)
    const wrapsMoreSpecific = errors.some((other) => other.instancePath.startsWith(`${err.instancePath}/`))
    if (!wrapsMoreSpecific) kept.push(err)
  }
  return kept
}

async function main() {
  const config = readJsonFile(configPath, "opencode.json")

  // $schema is how the check learns what "valid" means, so it must be there.
  const schemaUri = process.env.OPENCODE_CONFIG_SCHEMA || config.$schema
  if (typeof schemaUri !== "string" || schemaUri.length === 0) {
    fail('opencode.json needs a "$schema" URL (or set OPENCODE_CONFIG_SCHEMA to override the source)')
  }

  const cache = readCache()
  const cachedBefore = JSON.stringify(cache)
  const schema = await loadSchema(schemaUri, cache)
  // strict: false - the published schema carries opencode's own annotations
  // (allowComments, allowTrailingCommas) that are not JSON Schema keywords.
  // loadSchema resolves the remote $refs it does contain, on demand.
  const ajv = new Ajv2020({ strict: false, loadSchema: (uri) => loadSchema(uri, cache) })
  let validate
  try {
    validate = await ajv.compileAsync(schema)
  } catch (err) {
    fail(`${schemaUri} could not be used as a JSON Schema: ${err.message}`)
  }

  const conform = validate(config)
  if (JSON.stringify(cache) !== cachedBefore) writeCache(cache)
  if (!conform) {
    console.error(`opencode.json does not conform to ${schemaUri}:`)
    for (const err of specificErrors(validate.errors)) {
      console.error(`  ${err.instancePath || "/"}: ${err.message}`)
    }
    process.exit(1)
  }
  console.log(`opencode.json conforms to ${schemaUri}`)
}

main().catch((err) => fail(err && err.stack ? err.stack : String(err)))