import { C as supabase } from "./index-sG8SpmM9.js";
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

// Default ticket packages (fallback if DB returns nothing)
const DEFAULT_TICKET_PACKAGES = [
  { id: 'ticket-basic', name: 'Basic', coins: 3, ghs: 50, ngn: 5000, features: ['3 booking codes', 'Standard signals', 'Email support'], example: 'Man City vs Liverpool → Home Win 2-1', popular: false, tone: 'emerald' },
  { id: 'ticket-pro', name: 'Pro', coins: 10, ghs: 120, ngn: 12000, features: ['10 booking codes', 'AI-powered signals', 'Priority processing', 'Score predictions'], example: 'Arsenal vs Chelsea → Home Win 3-1 + Over 2.5', popular: true, tone: 'gold' },
  { id: 'ticket-elite', name: 'Elite', coins: 30, ghs: 250, ngn: 25000, features: ['30 booking codes', 'Full AI analysis', 'Instant processing', 'Detailed match notes', 'VIP support'], example: 'Liverpool vs Chelsea → Draw 2-2 + BTTS Yes', popular: false, tone: 'ice' }
];

// GET: efootball-home
export async function t() {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error("Unauthorized");

  const { data: profile } = await supabase
    .from('profiles')
    .select('tickets, status, country')
    .eq('id', user.id)
    .single();

  const { data: settings } = await supabase
    .from('settings')
    .select('efootball_cost, efootball_expiry')
    .eq('id', 'global_config')
    .maybeSingle();

  const { data: requests } = await supabase
    .from('booking_code_requests')
    .select('*')
    .eq('user_id', user.id)
    .order('created_at', { ascending: false });

  const { data: ledger } = await supabase
    .from('ticket_transactions')
    .select('*')
    .eq('user_id', user.id)
    .order('created_at', { ascending: false });

  // Ticket packages — fetched from DB so admin edits persist.
  const { data: pkgData } = await supabase.rpc('get_packages').maybeSingle();
  let packages = pkgData?.tickets;
  if (!Array.isArray(packages) || packages.length === 0) {
    packages = DEFAULT_TICKET_PACKAGES;
  }

  // User's ticket orders
  const { data: orders } = await supabase
    .from('orders')
    .select('*')
    .eq('user_id', user.id)
    .order('created_at', { ascending: false });

  return {
    tickets: profile?.tickets ?? 0,
    cost: settings?.efootball_cost ?? 1,
    expiresInMinutes: settings?.efootball_expiry ?? 10,
    profile: {
      status: profile?.status ?? 'pending',
      country: profile?.country || null
    },
    packages,
    orders: orders || [],
    requests: requests || [],
    ledger: ledger || []
  };
}

// POST: request booking code (via database RPC)
export async function n() {
  const { data, error } = await supabase.rpc('request_booking_code');
  if (error) {
    const { userMessage } = classifyError(error);
    showErrorToast('Booking code request failed: ' + userMessage, 'error');
    throw new Error(error.message);
  }
  return data;
}

// POST: submit ticket order
export async function r(props) {
  const { packageId, country, txnId, senderName, senderNumber, fileName, fileBase64 } = props?.data ?? {};
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) { showErrorToast('Please log in to continue.', 'error'); throw new Error('Unauthorized'); }

  // Find the package from DB or defaults
  const { data: pkgData } = await supabase.rpc('get_packages').maybeSingle();
  const allPkgs = pkgData?.tickets || DEFAULT_TICKET_PACKAGES;
  const pkg = allPkgs.find(p => p.id === packageId);
  if (!pkg) { showErrorToast('Package not found. Please try again.', 'error'); throw new Error('Invalid package'); }

  const currency = country === 'ghana' ? 'GHS' : 'NGN';
  const amount = country === 'ghana' ? pkg.ghs : pkg.ngn;
  const method = country === 'ghana' ? 'Mobile Money' : 'Bank Transfer';

  // Upload screenshot
  const fileBytes = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
  const screenshotPath = `${user.id}/${Date.now()}-${fileName}`;

  // OCR: scan screenshot for real sender name
  let ocrName = null;
  try { ocrName = await callPaymentOCR(fileBase64, 'image/png'); } catch (_) {}

  // Upload screenshot (non-blocking: order always saved)
  try {
    const { error: uploadErr } = await supabase.storage
      .from('screenshot-proofs')
      .upload(screenshotPath, fileBytes, { contentType: 'image/png' });
    if (uploadErr) screenshotPath = null;
  } catch (_) { screenshotPath = null; }

  // Insert order into orders table
  const { data, error } = await supabase
    .from('orders')
    .insert({
      user_id: user.id,
      email: user.email,
      package_name: pkg.name + ' Ticket',
      diamonds: pkg.coins,
      amount: Number(amount),
      currency,
      method,
      txn_id: txnId || null,
      sender_name: senderName,
      sender_number: senderNumber,
      screenshot_path: screenshotPath,
      status: 'pending',
      asset_type: 'ticket',
      ocr_name: ocrName
    })
    .select()
    .single();

  if (error) {
    const { userMessage } = classifyError(error);
    showErrorToast('Ticket order failed: ' + userMessage, 'error');
    throw error;
  }
  return { ok: true, receipt: data };
}