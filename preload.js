// preload.js
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('ipcRenderer', {
  on: (channel, func) => {
    // Only expose the channel needed for update notifications
    const validChannels = ['update-info-available'];
    if (validChannels.includes(channel)) {
      ipcRenderer.on(channel, (event, ...args) => func(...args));
    }
  },

  send: (channel, data) => {
    // Only expose the channel needed to open the download page
    const validChannels = ['open-download-page'];
    if (validChannels.includes(channel)) {
      ipcRenderer.send(channel, data);
    }
  }
});