#!/usr/bin/env bun
// Build signed device runners, or inspect prerequisites without changing phones.
import { $ } from "bun";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";

const root = new URL("..", import.meta.url).pathname;
$.cwd(root);
const checkOnly = process.argv.includes("--check");
const products = `${root}.build/runner/Build/Products/Debug-iphoneos`;
const names = ["ShortReelRunner.app", "ShortReelRunnerUITests-Runner.app"];
let ready = true;
const report = (ok: boolean, message: string) => {
  console.log(`${ok ? "✓" : "✗"} ${message}`);
  if (!ok) ready = false;
};

const ios = Bun.which("ios") ?? `${homedir()}/.bun/bin/ios`;
if (!existsSync(ios)) {
  console.error("go-ios is missing. Run bun run shortreel to install it.");
  process.exit(1);
}
const version = await $`${ios} version`.quiet().nothrow();
report(version.exitCode === 0, `go-ios: ${version.stdout.toString().trim()}`);

if (!checkOnly) {
  const team = process.env.SHORTREEL_DEVELOPMENT_TEAM;
  if (!team || !/^[A-Z0-9]{10}$/.test(team)) {
    console.error("Set SHORTREEL_DEVELOPMENT_TEAM to your 10-character Apple development team ID. Sign in to that team in Xcode → Settings → Accounts first.");
    process.exit(1);
  }
  await $`xcodegen generate`.quiet();
  const result = await $`xcodebuild -project ShortReel.xcodeproj -scheme ShortReelRunner -configuration Debug -destination generic/platform=iOS -derivedDataPath .build/runner CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=${team} -allowProvisioningUpdates -allowProvisioningDeviceRegistration build-for-testing`.quiet().nothrow();
  await Bun.write(`${root}.build/runner/build.log`, result.stdout.toString() + result.stderr.toString());
  if (result.exitCode !== 0) {
    console.error((result.stdout.toString() + result.stderr.toString()).split("\n").filter(line => /error:|FAILED/.test(line)).join("\n"));
    console.error("Full build log: .build/runner/build.log");
    process.exit(result.exitCode);
  }
}

for (const name of names) {
  const app = `${products}/${name}`;
  const signed = existsSync(`${app}/embedded.mobileprovision`)
    && (await $`codesign --verify --deep --strict ${app}`.quiet().nothrow()).exitCode === 0;
  report(signed, `${name}: ${signed ? "signed and provisioned" : "needs a signed build"}`);
}

const config = `${homedir()}/.ui-tars-cli.json`;
try {
  const parsed = JSON.parse(readFileSync(config, "utf8"));
  const endpoint = new URL(parsed.baseURL);
  const configured = ["http:", "https:"].includes(endpoint.protocol)
    && typeof parsed.apiKey === "string" && parsed.apiKey.trim().length > 0
    && typeof parsed.model === "string" && parsed.model.trim().length > 0;
  // Never print configuration contents or credentials.
  report(configured, `UI-TARS model configuration: ${configured ? "present (inference not tested)" : "incomplete"}`);
} catch {
  report(false, "UI-TARS model configuration missing or invalid. Complete npx @ui-tars/cli start.");
}

const listed = await $`${ios} list`.quiet().nothrow();
let phones: string[] = [];
try { phones = JSON.parse(listed.stdout.toString()).deviceList ?? []; } catch {}
report(phones.length > 0, `${phones.length} USB device(s) detected`);
for (const udid of phones) {
  const result = await $`${ios} devmode get --udid ${udid}`.quiet().nothrow();
  let enabled = false;
  try { enabled = JSON.parse(result.stdout.toString()).DeveloperModeEnabled === true; } catch {}
  report(enabled, `${udid}: Developer Mode ${enabled ? "enabled" : "off or device unavailable; unlock, enable it, restart, and confirm"}`);
}

if (!checkOnly) console.log("Runner build complete. Run bun run shortreel to package and launch it; trusted USB phones start automatically.");
process.exitCode = ready ? 0 : 1;
