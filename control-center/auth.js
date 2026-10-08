import { initializeApp } from 'firebase/app';
import { getAuth, GoogleAuthProvider, signInWithPopup, inMemoryPersistence, setPersistence, signOut } from 'firebase/auth';
import { firebaseConfig } from './firebase-config.js';
const nonce = location.hash.slice(1); history.replaceState(null, '', '/login');
const button = document.querySelector('button'), status = document.querySelector('p');
const auth = getAuth(initializeApp(firebaseConfig));
await setPersistence(auth, inMemoryPersistence);
button.addEventListener('click', async () => {
  button.disabled = true;
  try {
    const result = await signInWithPopup(auth, new GoogleAuthProvider());
    const response = await fetch('/session', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Control-Nonce': nonce },
      body: JSON.stringify({ idToken: await result.user.getIdToken(), refreshToken: result.user.refreshToken }) });
    if (!response.ok) throw new Error((await response.text()).trim() || 'Connection failed. Close this tab and connect again from Control Center.');
    await signOut(auth); status.textContent = 'Connected. Return to CapyFlow Control Center. You can close this tab.';
  } catch (error) { status.textContent = error.message; button.disabled = false; }
});
