// Validate opencode.json against the JSON Schema its own $schema points at.
//
// Issue #11 version-controls the opencode permission policy so agents get the
// same rules on every machine. The rules themselves are a human decision (see
// AGENTS.md), so nothing about them is asserted here - a test that pinned them
// would only produce merge conflicts and false failures. This check does one
// thing: prove that opencode.json is valid JSON and conforms to the schema it
// declares. Ajv does the validating, so a schema change (new tools, renamed
// keys, different actions) is picked up automatically and there is no
// hand-written validation logic to review against the schema.
//
// The schema lives at https://opencode.ai/config.json. It is fetched at run
// time and cached under .cache/schema, so repeat runs work offline. Override
// the source with OPENCODE_CONFIG_SCHEMA (a URL or a local file path).
//
// Run: node test/opencode-config.js   (or: npm run test:config)
"use strict"

const fs = require("node:fs")
const path = require("node:path")
const Ajv2020 = require("ajv/dist/2020").default

const repoRoot = path.join(__dirname, "..")
const configPath = path.join(repoRoot, "opencode.json")
const cacheDir = path.join(repoRoot, ".cache", "schema")

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

function cacheFile(uri) {
  return path.join(cacheDir, uri.replace(/[^\w.-]+/g, "_"))
}

// A schema document from a URL or a local path. Remote documents are cached
// under .cache/schema; if the network is down the cached copy is used so the
// check still runs.
async function loadSchema(uri) {
  if (!/^https?:\/\//i.test(uri)) return readJsonFile(path.resolve(repoRoot, uri), uri)

  const cached = cacheFile(uri)
  let body
  try {
    if (typeof fetch !== "function") throw new Error("node 18 or newer is required to fetch the schema")
    const res = await fetch(uri)
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    body = await res.text()
  } catch (err) {
    if (!fs.existsSync(cached)) fail(`cannot load ${uri}: ${err.message} (no cached copy under ${cacheDir})`)
    console.warn(`warning: cannot load ${uri} (${err.message}); using the cached copy`)
    return readJsonFile(cached, uri)
  }

  try {
    JSON.parse(body)
  } catch (err) {
    fail(`${uri} did not return JSON: ${err.message}`)
  }
  fs.mkdirSync(cacheDir, { recursive: true })
  fs.writeFileSync(cached, body)
  return JSON.parse(body)
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

  const schema = await loadSchema(schemaUri)
  // strict: false - the published schema carries opencode's own annotations
  // (allowComments, allowTrailingCommas) that are not JSON Schema keywords.
  // loadSchema resolves the remote $refs it does contain, on demand.
  const ajv = new Ajv2020({ strict: false, loadSchema })
  let validate
  try {
    validate = await ajv.compileAsync(schema)
  } catch (err) {
    fail(`${schemaUri} could not be used as a JSON Schema: ${err.message}`)
  }

  if (!validate(config)) {
    console.error(`opencode.json does not conform to ${schemaUri}:`)
    for (const err of specificErrors(validate.errors)) {
      console.error(`  ${err.instancePath || "/"}: ${err.message}`)
    }
    process.exit(1)
  }
  console.log(`opencode.json conforms to ${schemaUri}`)
}

main().catch((err) => fail(err && err.stack ? err.stack : String(err)))