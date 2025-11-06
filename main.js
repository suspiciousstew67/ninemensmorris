// main.js
const { app, BrowserWindow } = require('electron');
const path = require('path');

function createWindow() {
  const mainWindow = new BrowserWindow({
    width: 900,
    height: 750,
    // --- PERFORMANCE FIX: Transparent windows are extremely resource-intensive. ---
    // This is the primary cause of high GPU usage. It has been disabled.
    titleBarStyle: 'hidden',
    backgroundColor: '#2e3440', // A solid background is far more efficient.
    // --- END FIX ---
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: true,
      contextIsolation: false
    }
  });

  mainWindow.loadFile('index.html');
  // Uncomment for debugging:
  // mainWindow.webContents.openDevTools();
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});