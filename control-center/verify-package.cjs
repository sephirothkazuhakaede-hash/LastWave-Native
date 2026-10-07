const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
module.exports = async context => {
  const root = path.join(context.appOutDir, 'resources/backend');
  const backendRequire = createRequire(path.join(root, 'package.json'));
  for (const name of ['firebase-admin/app', 'firebase-admin/auth', 'firebase-admin/firestore', 'firebase-admin/messaging']) backendRequire(name);
  for (const privateName of ['.env', 'cache', 'data', 'state']) if (fs.existsSync(path.join(root, privateName))) throw Error('Mutable/private backend data must not be packaged: ' + privateName);
  console.log('Packaged Firebase dependencies verified; no backend environment or user data bundled.');
};
