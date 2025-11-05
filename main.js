// main.js

const { app, BrowserWindow } = require('electron');
const path = require('path');

// This function creates the main application window.
function createWindow() {
  const mainWindow = new BrowserWindow({
    width: 900,
    height: 750,
    // --- START: Added for macOS transparent title bar ---
    titleBarStyle: 'hiddenInset',
    transparent: true,
    // --- END: Added for macOS transparent title bar ---
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: true,
      contextIsolation: false
    }
  });

  // Load your game's HTML file into the window.
  mainWindow.loadFile('index.html');

  // Optional: Open the DevTools for debugging during development.
  // mainWindow.webContents.openDevTools();
}

// This method is called when Electron has finished initialization.
app.whenReady().then(() => {
  createWindow();

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

// Quit when all windows are closed, except on macOS.
app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});