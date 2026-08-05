import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const backendVersionPath = path.join(repositoryRoot, 'backend', 'cmd', 'server', 'VERSION')
const frontendPackagePath = path.join(repositoryRoot, 'frontend', 'package.json')
const checkOnly = process.argv.includes('--check')

const backendVersion = fs.readFileSync(backendVersionPath, 'utf8').trim()
if (!/^\d+\.\d+\.\d+$/.test(backendVersion)) {
  throw new Error(`Invalid backend version: ${backendVersion || '<empty>'}`)
}

const packageJson = JSON.parse(fs.readFileSync(frontendPackagePath, 'utf8'))
if (packageJson.version === backendVersion) {
  process.stdout.write(`${backendVersion}\n`)
  process.exit(0)
}

if (checkOnly) {
  throw new Error(
    `Frontend version ${packageJson.version || '<missing>'} does not match backend version ${backendVersion}`,
  )
}

packageJson.version = backendVersion
fs.writeFileSync(frontendPackagePath, `${JSON.stringify(packageJson, null, 2)}\n`)
process.stdout.write(`${backendVersion}\n`)
