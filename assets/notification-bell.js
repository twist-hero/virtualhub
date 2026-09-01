// Notification Bell - injects into the dashboard header safely
(function() {
  const SUPABASE_URL = 'https://buvpkpjgctdmynwtqwta.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_irh-8VOxfVpABFp5LZJ3iA_cMdxsYKa';
  
  let bellEl = null, dropdownEl = null, unreadCount = 0, allNotifications = [], injected = false;
  
  function createBell() {
    if (bellEl) return bellEl;
    bellEl = document.createElement('button');
    bellEl.type = 'button';
    bellEl.setAttribute('aria-label', 'Notifications');
    bellEl.style.cssText = 'position:relative;grid;height:40px;width:40px;flex-shrink:0;display:grid;place-items:center;border-radius:9999px;border:1px solid rgba(255,255,255,0.08);background:rgba(255,255,255,0.05);color:rgba(255,255,255,0.5);transition:all 0.2s;cursor:pointer;';
    bellEl.onmouseenter = function(){ this.style.background='rgba(255,255,255,0.1)'; this.style.color='#fff'; };
    bellEl.onmouseleave = function(){ this.style.background='rgba(255,255,255,0.05)'; this.style.color='rgba(255,255,255,0.5)'; };
    bellEl.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></svg>';
    bellEl.onclick = function(e) { e.stopPropagation(); toggleDropdown(); };
    return bellEl;
  }
  
  function createDropdown() {
    if (dropdownEl) return;
    dropdownEl = document.createElement('div');
    dropdownEl.style.cssText = 'display:none;position:fixed;top:60px;right:16px;width:320px;max-height:384px;overflow-y:auto;border-radius:16px;border:1px solid rgba(255,255,255,0.1);background:#1a1a2e;box-shadow:0 20px 60px rgba(0,0,0,0.5);z-index:9999;';
    document.body.appendChild(dropdownEl);
  }
  
  function toggleDropdown() {
    if (!dropdownEl) createDropdown();
    var visible = dropdownEl.style.display !== 'none';
    if (visible) {
      dropdownEl.style.display = 'none';
    } else {
      renderDropdown();
      dropdownEl.style.display = 'block';
    }
  }
  
  function renderDropdown() {
    if (!dropdownEl) return;
    var html = '<div style="display:flex;align-items:center;justify-content:space-between;padding:12px 16px;border-bottom:1px solid rgba(255,255,255,0.1)">';
    html += '<h3 style="font-size:13px;font-weight:900;color:#fff;margin:0">Notifications</h3>';
    if (unreadCount > 0) {
      html += '<button onclick="window._notifMarkAllRead()" style="background:none;border:none;color:#10b981;font-size:11px;font-weight:700;cursor:pointer">Mark all read</button>';
    }
    html += '</div>';
    
    if (allNotifications.length === 0) {
      html += '<p style="padding:32px 16px;text-align:center;font-size:13px;color:rgba(255,255,255,0.4)">No notifications yet</p>';
    } else {
      html += '<div>';
      allNotifications.slice(0, 20).forEach(function(n) {
        var icon = n.kind === 'success' ? '&#10004;' : n.kind === 'error' ? '&#10006;' : '&#128276;';
        var titleColor = n.read_at ? 'rgba(255,255,255,0.4)' : '#fff';
        var bg = n.read_at ? '' : 'rgba(16,185,129,0.05)';
        html += '<div onclick="window._notifMarkRead(\'' + n.id + '\')" style="display:flex;gap:12px;padding:12px 16px;background:' + bg + ';cursor:pointer;transition:background 0.2s;border-bottom:1px solid rgba(255,255,255,0.05)" onmouseover="this.style.background=\'rgba(255,255,255,0.05)\'" onmouseout="this.style.background=\'' + bg + '\'">';
        html += '<span style="margin-top:2px;font-size:16px;flex-shrink:0">' + icon + '</span>';
        html += '<div style="min-width:0;flex:1">';
        html += '<p style="font-size:13px;font-weight:700;color:' + titleColor + ';margin:0">' + escapeHtml(n.title) + '</p>';
        html += '<p style="font-size:12px;color:rgba(255,255,255,0.4);margin:4px 0 0;overflow:hidden;text-overflow:ellipsis;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical">' + escapeHtml(n.body) + '</p>';
        html += '<p style="font-size:10px;font-weight:700;color:rgba(255,255,255,0.3);margin:4px 0 0">' + getTimeAgo(n.created_at) + '</p>';
        html += '</div></div>';
      });
      html += '</div>';
    }
    dropdownEl.innerHTML = html;
  }
  
  function escapeHtml(str) {
    if (!str) return '';
    return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }
  
  function getTimeAgo(dateStr) {
    var diff = Date.now() - new Date(dateStr).getTime();
    if (diff < 60000) return 'Just now';
    if (diff < 3600000) return Math.floor(diff/60000) + 'm ago';
    if (diff < 86400000) return Math.floor(diff/3600000) + 'h ago';
    return Math.floor(diff/86400000) + 'd ago';
  }
  
  function updateBadge() {
    if (!bellEl) return;
    var existing = bellEl.querySelector('.notif-badge');
    if (existing) existing.remove();
    if (unreadCount > 0) {
      var badge = document.createElement('span');
      badge.className = 'notif-badge';
      badge.style.cssText = 'position:absolute;top:-4px;right:-4px;min-width:20px;height:20px;display:grid;place-items:center;border-radius:9999px;background:#10b981;padding:0 4px;font-size:10px;font-weight:900;color:#fff;animation:vh-pulse 2s infinite';
      badge.textContent = unreadCount;
      bellEl.appendChild(badge);
    }
  }
  
  function getToken() {
    try {
      var keys = Object.keys(localStorage).filter(function(k) { return k.indexOf('supabase') !== -1 && k.indexOf('auth') !== -1; });
      for (var i = 0; i < keys.length; i++) {
        var session = JSON.parse(localStorage.getItem(keys[i]) || '{}');
        if (session.access_token) return session.access_token;
      }
    } catch(e) {}
    return null;
  }
  
  async function fetchNotifications() {
    try {
      var token = getToken();
      if (!token) return;
      var res = await fetch(SUPABASE_URL + '/rest/v1/notifications?order=created_at.desc&limit=20', {
        headers: { 'Authorization': 'Bearer ' + token, 'apikey': SUPABASE_KEY }
      });
      if (!res.ok) return;
      var data = await res.json();
      allNotifications = data;
      unreadCount = data.filter(function(n) { return !n.read_at; }).length;
      updateBadge();
    } catch(e) { /* silent */ }
  }
  
  window._notifMarkRead = async function(id) {
    try {
      var token = getToken();
      if (!token) return;
      await fetch(SUPABASE_URL + '/rest/v1/notifications?read_at=is.null&id=eq.' + id, {
        method: 'PATCH',
        headers: { 'Authorization': 'Bearer ' + token, 'apikey': SUPABASE_KEY, 'Content-Type': 'application/json', 'Prefer': 'return=minimal' },
        body: JSON.stringify({ read_at: new Date().toISOString() })
      });
      fetchNotifications();
      if (dropdownEl) renderDropdown();
    } catch(e) {}
  };
  
  window._notifMarkAllRead = async function() {
    try {
      var token = getToken();
      if (!token) return;
      await fetch(SUPABASE_URL + '/rest/v1/notifications?read_at=is.null', {
        method: 'PATCH',
        headers: { 'Authorization': 'Bearer ' + token, 'apikey': SUPABASE_KEY, 'Content-Type': 'application/json', 'Prefer': 'return=minimal' },
        body: JSON.stringify({ read_at: new Date().toISOString() })
      });
      fetchNotifications();
      if (dropdownEl) renderDropdown();
    } catch(e) {}
  };
  
  // Close dropdown on outside click
  document.addEventListener('click', function() { if (dropdownEl) dropdownEl.style.display = 'none'; });
  
  // Safe injection using MutationObserver - waits for React to render header
  function tryInject() {
    if (injected) return;
    // Find any header element
    var header = document.querySelector('header');
    if (!header) return;
    // Find the container with the avatar and links
    var container = header.querySelector('.flex.items-center');
    if (!container) return;
    // Check if bell already exists
    if (container.querySelector('[aria-label="Notifications"]')) { injected = true; return; }
    
    createBell();
    createDropdown();
    
    // Find the avatar link (the one with the user initial letter) and insert before it
    var avatarLink = container.querySelector('a[aria-label*="account"], a[href="/account"]');
    if (avatarLink && avatarLink.parentNode === container) {
      container.insertBefore(bellEl, avatarLink);
    } else {
      // Just append at the end
      container.appendChild(bellEl);
    }
    injected = true;
    fetchNotifications();
    setInterval(fetchNotifications, 15000);
  }
  
  // Use MutationObserver to detect when React renders the header
  var observer = new MutationObserver(function() {
    if (!injected) tryInject();
  });
  
  if (document.body) {
    observer.observe(document.body, { childList: true, subtree: true });
  }
  
  // Also try immediately and periodically
  tryInject();
  setTimeout(tryInject, 500);
  setTimeout(tryInject, 1500);
  setTimeout(tryInject, 3000);
})();
