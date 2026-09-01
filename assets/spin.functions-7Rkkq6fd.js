import { C as supabase } from "./index-sG8SpmM9.js";
import { o as makeIcon } from "./button-DS1rjqG5.js";
import { classifyError, showErrorToast, withRetry } from "./error-utils.js";

// OCR: Extract sender name from payment screenshot using Gemini Vision
async function callPaymentOCR(fileBase64, mime) {
  try {
    const { data: keyData } = await supabase.rpc('get_gemini_key').maybeSingle();
    const geminiKey = keyData?.gemini_api_key;
    if (!geminiKey || !fileBase64) return null;
    const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent?key=${geminiKey}`;
    const payload = { contents: [{ parts: [
      { text: 'This is a payment receipt or mobile money screenshot. Extract the SENDER NAME (the person who sent the money). Return ONLY the name as plain text. If undetectable, return NONE.' },
      { inlineData: { mimeType: mime || 'image/png', data: fileBase64 } }
    ] }] };
    const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    if (!res.ok) return null;
    const json = await res.json();
    const txt = json?.candidates?.[0]?.content?.parts?.[0]?.text?.trim() ?? '';
    if (!txt || txt.toUpperCase() === 'NONE') return null;
    return txt.replace(/["']/g, '').trim();
  } catch (_) { return null; }
}

// Coins icon component required by the page
export var i = makeIcon('coins', [
  ['path', { d: 'M13.744 17.736a6 6 0 1 1-7.48-7.48', key: 'bq4yh3' }],
  ['path', { d: 'M15 6h1v4', key: '11y1tn' }],
  ['path', { d: 'm6.134 14.768.866-.5 2 3.464', key: '17snzx' }],
  ['circle', { cx: '16', cy: '8', r: '6', key: '14bfc9' }]
]);

// GET: spin-home
export async function t() {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error("Unauthorized");

  const { data: profile } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', user.id)
    .single();

  const { data: settings } = await supabase
    .from('settings')
    .select('spin_cost')
    .eq('id', 'global_config')
    .maybeSingle();

  const { data: signals } = await supabase
    .from('spin_signals')
    .select('*')
    .eq('user_id', user.id)
    .order('created_at', { ascending: false });

  // Gold coin packages — fetched from DB so admin edits persist.
  // Falls back to safe defaults if RPC not yet deployed.
  const { data: pkgData } = await supabase.rpc('get_packages').maybeSingle();
  let packages = pkgData?.gold;
  if (!Array.isArray(packages) || packages.length === 0) {
    packages = [
      { id: 'gold-basic', name: 'Basic', coins: 2, ghs: 350, ngn: 35000, features: ['3 spin reveals','Standard signals','Email support'], example: 'Tomorrow 14:00 → Man City Win (78%)', popular: false, tone: 'emerald' },
      { id: 'gold-pro',   name: 'Pro',   coins: 3, ghs: 500, ngn: 50000, features: ['10 spin reveals','AI-powered signals','Priority processing','Score predictions'], example: 'Tomorrow 16:30 → Arsenal Win 2-1 (85%) + BTTS', popular: true, tone: 'gold' },
      { id: 'gold-elite', name: 'Elite', coins: 7, ghs: 850, ngn: 85000, features: ['Unlimited reveals','Full AI analysis','Instant processing','Detailed match notes','VIP support'], example: 'Liverpool vs Chelsea → Draw 2-2 (91%) + Over 2.5', popular: false, tone: 'ice' }
    ];
  }

  // User's gold coin orders
  const { data: orders } = await supabase
    .from('orders')
    .select('*')
    .eq('user_id', user.id)
    .order('created_at', { ascending: false });

  return {
    gold: profile?.gold ?? 0,
    cost: settings?.spin_cost ?? 50,
    packages,
    orders: orders || [],
    profile: {
      status: profile?.status ?? 'pending',
      country: profile?.country || null
    },
    signals: signals || []
  };
}

// POST: reveal spin signal (via database RPC)
export async function n() {
  const { data, error } = await supabase.rpc('reveal_spin_signal');
  if (error) throw new Error(error.message);
  return data;
}

// POST: submit gold coin order
export async function r(props) {
  const { packageId, packageName, coins, amount: amt, currency: cur, country, txnId, senderName, senderNumber, fileName, fileBase64 } = props?.data ?? {};
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error("Unauthorized");

  // Use package details from the UI (fetched from DB) — no more hardcoded packages
  let pkgCoins = Number(coins) || 0;
  let pkgName = packageName || packageId || 'Gold';
  let amount = Number(amt) || 0;
  let currency = cur || (country === 'ghana' ? 'GHS' : 'NGN');
  let method = country === 'ghana' ? 'Mobile Money' : 'Bank Transfer';

  // Fallback: if no amount provided, try fetching from DB
  if (!amount || !pkgCoins) {
    try {
      const { data: pkgData } = await supabase.rpc('get_packages').maybeSingle();
      const goldPkgs = pkgData?.gold || [];
      const fallback = goldPkgs.find(p => p.id === packageId);
      if (fallback) {
        pkgCoins = fallback.coins || fallback.gold || pkgCoins;
        pkgName = fallback.name + ' Gold';
        amount = country === 'ghana' ? fallback.ghs : fallback.ngn;
        currency = country === 'ghana' ? 'GHS' : 'NGN';
      }
    } catch (_) { /* use what we have */ }
  }

  const fileBytes = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
  const screenshotPath = `${user.id}/${Date.now()}-${fileName}`;

  // OCR: scan screenshot for real sender name
  let ocrName = null;
  try { ocrName = await callPaymentOCR(fileBase64, 'image/png'); } catch (_) {}

  // Upload screenshot (non-blocking: order always saved)
  let uploadFailed = false;
  try {
    const { error: uploadErr } = await withRetry(() =>
      supabase.storage.from('screenshot-proofs').upload(screenshotPath, fileBytes, { contentType: 'image/png' })
    , { maxRetries: 2, delayMs: 1000 });
    if (uploadErr) { uploadFailed = true; screenshotPath = null; }
  } catch (_) { uploadFailed = true; screenshotPath = null; }
  if (uploadFailed) showErrorToast('Screenshot upload failed — order saved without image.', 'warning');

  const { data, error } = await supabase
    .from('orders')
    .insert({
      user_id: user.id,
      email: user.email,
      package_name: pkgName,
      diamonds: pkgCoins,
      amount: Number(amount),
      currency,
      method,
      txn_id: txnId || null,
      sender_name: senderName,
      sender_number: senderNumber,
      screenshot_path: screenshotPath,
      status: 'pending',
      asset_type: 'gold',
      ocr_name: ocrName
    })
    .select()
    .single();

  if (error) {
    const { userMessage } = classifyError(error);
    showErrorToast('Gold order failed: ' + userMessage, 'error');
    throw error;
  }
  return { ok: true, order: data };
}