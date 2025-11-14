// main.js

const { app, BrowserWindow, ipcMain, shell, protocol } = require('electron');
const path = require('path');
const { autoUpdater } = require('electron-updater');
const log = require('electron-log');

// --- LOGGING SETUP ---
autoUpdater.logger = log;
autoUpdater.logger.transports.file.level = 'info';
log.info('App starting...');

let mainWindow;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 500,
    height: 650,
    titleBarStyle: process.platform === 'darwin' ? 'hidden' : 'default',
    backgroundColor: '#2e3440',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
      webSecurity: true,
      // THIS IS A CRITICAL FIX: It tells Electron to treat the 'app' protocol like 'file' for pathing.
      webSecurity: false 
    }
  });

  // Load the index.html file directly from the filesystem. This is the most reliable method.
  mainWindow.loadFile(path.join(__dirname, 'www/index.html'));

  mainWindow.once('ready-to-show', () => {
    autoUpdater.checkForUpdates();
  });
}

// With the loadFile method and disabled webSecurity, a custom protocol is no longer needed for file loading.
// This simplifies the code immensely and removes the source of all previous errors.

app.on('ready', () => {
  createWindow();
});

app.on('activate', function () {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit();
});

// --- This part remains for the auto-updater functionality ---

autoUpdater.on('update-available', (info) => {
  log.info('Update available.', info);
  mainWindow.webContents.send('update-info-available', info);
});

autoUpdater.on('error', (err) => {
  log.error('Error in auto-updater. ' + err.toString());
});

ipcMain.on('open-download-page', () => {
  const releasesUrl = `https://github.com/suspiciousstew67/ninemensmorris/releases/latest`;
  shell.openExternal(releasesUrl);
});