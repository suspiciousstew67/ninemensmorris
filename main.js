// main.js

const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
// Import the autoUpdater
const { autoUpdater } = require('electron-updater');

// Keep a global reference to the window object, if you don't, the window will
// be closed automatically when the JavaScript object is garbage collected.
let mainWindow;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 900,
    height: 750,
    titleBarStyle: 'hidden',
    backgroundColor: '#2e3440',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      // Keep these for ipcRenderer to work
      nodeIntegration: false,
      contextIsolation: true,
    }
  });

  mainWindow.loadFile('index.html');

  // --- AUTO-UPDATE LOGIC ---
  // This will immediately check for an update and notify the user if one is available.
  mainWindow.once('ready-to-show', () => {
    autoUpdater.checkForUpdatesAndNotify();
  });
}

app.whenReady().then(() => {
  createWindow();

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

// --- AUTO-UPDATE EVENT LISTENERS (for more detailed UI feedback) ---

// This event is emitted when a new update is found.
autoUpdater.on('update-available', () => {
  mainWindow.webContents.send('update_available');
});

// This event is emitted when an update has been downloaded.
autoUpdater.on('update-downloaded', () => {
  mainWindow.webContents.send('update_downloaded');
});

// When the user clicks "Restart" in the renderer process, this event is triggered.
ipcMain.on('restart_app', () => {
  autoUpdater.quitAndInstall();
});