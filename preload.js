// preload.js
const { contextBridge, ipcRenderer } = require('electron');

// Expose protected methods that allow the renderer process to use
// the ipcRenderer without exposing the entire object.
contextBridge.exposeInMainWorld('ipcRenderer', {
  // Expose a function to listen for messages from the main process
  on: (channel, func) => {
    const validChannels = ['update_available', 'update_downloaded'];
    if (validChannels.includes(channel)) {
      // Deliberately strip event as it includes `sender`
      ipcRenderer.on(channel, (event, ...args) => func(...args));
    }
  },
  // Expose a function to send a message to the main process
  send: (channel) => {
    const validChannels = ['restart_app'];
    if (validChannels.includes(channel)) {
      ipcRenderer.send(channel);
    }
  }
});