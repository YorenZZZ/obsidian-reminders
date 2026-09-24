#!/usr/bin/env node
// Installs the bundled "Obsidian Reminders.app" into /Applications (or
// ~/Applications) so it can be opened like any other Mac app.
//
//   npm install -g obsidian-reminders     (runs "install" automatically)
//   obsidian-reminders [install|open|uninstall|version]
'use strict';

const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const APP_NAME = 'Obsidian Reminders';
const BUNDLE = `${APP_NAME}.app`;
const PKG = require('../package.json');
const REPO = 'YorenZZZ/obsidian-reminders';
const ZIP_URL = `https://github.com/${REPO}/releases/download/v${PKG.version}/Obsidian-Reminders.zip`;
// SHA-256 of that release asset, written by scripts/npm-prepack.sh.
const SHA_FILE = path.join(__dirname, 'app.sha256');
const LSREGISTER =
  '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';

const isRoot = typeof process.getuid === 'function' && process.getuid() === 0;
const home = isRoot && process.env.SUDO_USER ? path.join('/Users', process.env.SUDO_USER) : os.homedir();
const candidates = ['/Applications', path.join(home, 'Applications')];

function log(msg) {
  console.log(`==> ${msg}`);
}

function fail(msg) {
  console.error(`obsidian-reminders: ${msg}`);
  process.exit(1);
}

function run(cmd, args) {
  execFileSync(cmd, args, { stdio: ['ignore', 'ignore', 'inherit'] });
}

function checkPlatform() {
  if (process.platform !== 'darwin') fail('this app only runs on macOS.');
  const version = execFileSync('sw_vers', ['-productVersion']).toString().trim();
  const [major, minor = 0] = version.split('.').map(Number);
  if (major < 12 || (major === 12 && minor < 3)) {
    fail(`needs macOS 12.3 (Monterey) or later. This Mac runs ${version}.`);
  }
}

function installedApp() {
  return candidates.map((dir) => path.join(dir, BUNDLE)).find((p) => fs.existsSync(p));
}

function installedVersion(app) {
  try {
    return execFileSync('/usr/bin/defaults', ['read', path.join(app, 'Contents', 'Info'), 'CFBundleShortVersionString'])
      .toString()
      .trim();
  } catch {
    return null;
  }
}

function writable(dir) {
  try {
    fs.accessSync(dir, fs.constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

function quit() {
  spawnSync('osascript', ['-e', `tell application "${APP_NAME}" to quit`], { stdio: 'ignore' });
}

function download(dir) {
  const zip = path.join(dir, 'app.zip');
  log(`Downloading ${ZIP_URL}`);
  // curl follows GitHub's redirect and honours the usual proxy variables.
  const res = spawnSync('/usr/bin/curl', ['-fL', '--retry', '3', '--progress-bar', ZIP_URL, '-o', zip], {
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  if (res.status !== 0) fail(`download failed. Check your network and run: obsidian-reminders install`);

  const expected = fs.readFileSync(SHA_FILE, 'utf8').trim();
  const actual = execFileSync('/usr/bin/shasum', ['-a', '256', zip]).toString().split(' ')[0];
  if (actual !== expected) fail(`download is corrupted (sha256 ${actual}, expected ${expected}). Try again.`);
  return zip;
}

function install() {
  checkPlatform();

  const existing = installedApp();
  if (existing && installedVersion(existing) === PKG.version && !process.argv.includes('--force')) {
    log(`${APP_NAME} ${PKG.version} is already installed: ${existing}`);
    return existing;
  }

  let dir = existing ? path.dirname(existing) : candidates.find((d) => fs.existsSync(d) && writable(d));
  if (!dir || !writable(dir)) {
    dir = candidates[1];
    fs.mkdirSync(dir, { recursive: true });
  }
  const dest = path.join(dir, BUNDLE);

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'obsidian-reminders-'));
  try {
    const zip = download(tmp);
    log(`Unpacking ${APP_NAME} ${PKG.version}`);
    run('/usr/bin/ditto', ['-x', '-k', zip, tmp]);

    log(`Installing to ${dir}`);
    quit();
    fs.rmSync(dest, { recursive: true, force: true });
    run('/usr/bin/ditto', [path.join(tmp, BUNDLE), dest]);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  // Not notarized: make sure no download flag makes Gatekeeper block it.
  spawnSync('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', dest], { stdio: 'ignore' });
  if (isRoot && process.env.SUDO_USER) {
    spawnSync('/usr/sbin/chown', ['-R', `${process.env.SUDO_USER}:staff`, dest], { stdio: 'ignore' });
  }
  // Register with Launch Services so Spotlight, Launchpad and Finder see it now.
  spawnSync(LSREGISTER, ['-f', dest], { stdio: 'ignore' });
  log(`Installed: ${dest}`);
  return dest;
}

function open(app) {
  app = app || installedApp();
  if (!app) fail('the app is not installed. Run: obsidian-reminders install');
  if (isRoot && process.env.SUDO_USER) {
    spawnSync('/usr/bin/sudo', ['-u', process.env.SUDO_USER, '/usr/bin/open', app], { stdio: 'inherit' });
  } else {
    spawnSync('/usr/bin/open', [app], { stdio: 'inherit' });
  }
  log(`Opened ${APP_NAME}`);
}

function uninstall() {
  const app = installedApp();
  if (!app) {
    log(`${APP_NAME} is not installed.`);
    return;
  }
  quit();
  fs.rmSync(app, { recursive: true, force: true });
  log(`Removed ${app}`);
  console.log('Settings and logs are kept. To remove them too:');
  console.log(`  rm -rf ~/Library/Application\\ Support/ObsidianReminders ~/Library/Logs/ObsidianReminders`);
  console.log('Then: npm uninstall -g obsidian-reminders');
}

function shouldAutoOpen() {
  return !process.env.CI && !process.env.OBSIDIAN_REMINDERS_NO_OPEN;
}

function done() {
  console.log();
  console.log(`Done. ${APP_NAME} is in your Applications folder — open it from Launchpad or Spotlight any time.`);
  console.log('Click "OK"/"Allow" when macOS asks for access to Reminders (and to your documents folder).');
  console.log('完成。应用已在「应用程序」文件夹，可从启动台或聚焦搜索打开。');
  console.log('macOS 询问「提醒事项」（以及文稿文件夹）访问权限时，请点「好」/「允许」。');
}

const cmd = process.argv[2] || 'install';
switch (cmd) {
  case 'install':
  case 'postinstall': {
    const app = install();
    if (shouldAutoOpen()) open(app);
    done();
    break;
  }
  case 'open':
    open();
    break;
  case 'uninstall':
    uninstall();
    break;
  case 'version':
  case '--version':
  case '-v':
    console.log(PKG.version);
    break;
  case 'help':
  case '--help':
  case '-h':
    console.log(`Usage: obsidian-reminders [command]

  install     Install (or update) the app into Applications and open it (default)
  open        Open the installed app
  uninstall   Remove the app from Applications
  version     Print the bundled app version

Options: --force reinstalls even if the same version is present.
Set OBSIDIAN_REMINDERS_NO_OPEN=1 to install without opening.`);
    break;
  default:
    fail(`unknown command "${cmd}". Try: obsidian-reminders --help`);
}
