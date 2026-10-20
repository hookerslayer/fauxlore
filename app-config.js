// Local FastAPI remains available on localhost; public static hosting uses Apps Script.
// The Apps Script URL is public API routing information, not a credential.
const localPostgresHost = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
window.FAUXLORE_CONFIG = localPostgresHost
  ? { backend: 'postgresql' }
  : {
      backend: 'apps-script',
      appsScriptUrl: 'https://script.google.com/macros/s/AKfycbxtj79njbMmtno-mv87mWNBTz_1P0liScB24orSJQoOt6mk10ciqq7alZxGLRGi9axX/exec',
    };
