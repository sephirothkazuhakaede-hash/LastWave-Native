const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('control', {
  call: (action, value) => ipcRenderer.invoke('control', action, value),
  onConnected: callback => ipcRenderer.on('connected', () => callback()),
  onBackendAddress: callback => ipcRenderer.on('backend-address', (_event, address) => callback(address)),
});
