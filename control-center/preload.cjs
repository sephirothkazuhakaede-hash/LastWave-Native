const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('control', {
  call: (action, value) => ipcRenderer.invoke('control', action, value),
  onConnected: callback => ipcRenderer.on('connected', () => callback()),
});
