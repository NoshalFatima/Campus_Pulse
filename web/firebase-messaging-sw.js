// web/firebase-messaging-sw.js
// ─────────────────────────────────────────────────────────────────────────────
// FCM Service Worker — handles background notifications on web
// Ye file web/ folder mein rakho (index.html ke saath)
// ─────────────────────────────────────────────────────────────────────────────

importScripts("https://www.gstatic.com/firebasejs/10.12.0/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.12.0/firebase-messaging-compat.js");

// ✅ Apni Firebase web config yahan daalo (.env se same values)
firebase.initializeApp({
  apiKey:            "AIzaSyDIcg6cD6_C_6NgrH59r3VPKyg4OyHXwpg",
  authDomain:        "campus-pulse-bc863.firebaseapp.com",
  databaseURL:       "https://campus-pulse-bc863-default-rtdb.firebaseio.comL",
  projectId:         "campus-pulse-bc863",
  storageBucket:     "campus-pulse-bc863.firebasestorage.app",
  messagingSenderId: "786482560131",
  appId:             "1:786482560131:web:9d9941573bafd0f24eefb6",
});

const messaging = firebase.messaging();

// ─────────────────────────────────────────────────────────────────────────────
// BACKGROUND MESSAGE HANDLER
// App band ho ya background mein ho tab ye fire hota hai
// ─────────────────────────────────────────────────────────────────────────────
messaging.onBackgroundMessage((payload) => {
  console.log("📩 Background FCM received:", payload);

  const title = payload.notification?.title ?? "Campus Pulse";
  const body  = payload.notification?.body  ?? "";
  const icon  = "/icons/Icon-192.png";

  self.registration.showNotification(title, {
    body,
    icon,
    badge: "/icons/Icon-192.png",
    data: payload.data ?? {},
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// NOTIFICATION CLICK — user ne notification pe click kiya
// ─────────────────────────────────────────────────────────────────────────────
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      if (clientList.length > 0) {
        return clientList[0].focus();
      }
      return clients.openWindow("/");
    })
  );
});