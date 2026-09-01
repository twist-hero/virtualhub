import { C as supabase } from "./index-sG8SpmM9.js";
import { classifyError, showErrorToast, withRetry } from "./error-utils.js";

// GET: prediction-home
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
    .select('prediction_cost')
    .eq('id', 'global_config')
    .maybeSingle();

  const { data: predictions } = await supabase
    .from('predictions')
    .select('*')
    .eq('user_id', user.id)
    .order('created_at', { ascending: false });

  // Diamond packages — fetched from DB so admin edits persist.
  // Falls back to safe defaults if RPC not yet deployed.
  const { data: pkgData } = await supabase.rpc('get_packages').maybeSingle();
  let packages = pkgData?.diamonds;
  if (!Array.isArray(packages) || packages.length === 0) {
    packages = [
      { id: 'starter', name: 'Starter', diamonds: 2, ghs: 350, ngn: 35000, features: ['3 match predictions','Standard accuracy','Email support'], example: 'Man City vs Liverpool → Home Win 2-1 (82%)', popular: false, tone: 'emerald' },
      { id: 'pro',     name: 'Pro',     diamonds: 3, ghs: 500, ngn: 50000, features: ['10 match predictions','Gemini AI analysis','Priority processing','Score + goals tips'], example: 'Arsenal vs Chelsea → Home Win 3-1 (89%) + Over 2.5 goals', popular: true, tone: 'gold' },
      { id: 'elite',   name: 'Elite',   diamonds: 7, ghs: 850, ngn: 85000, features: ['Unlimited predictions','Gemini AI + screenshot OCR','Instant processing','Full analysis + notes','VIP support'], example: 'Real Madrid vs Barcelona → Draw 2-2 (94%) + BTTS Yes', popular: false, tone: 'ice' }
    ];
  }

  // User's diamond orders
  const { data: orders } = await supabase
    .from('orders')
    .select('*')
    .eq('user_id', user.id)
    .order('created_at', { ascending: false });

  return {
    diamonds: profile?.diamonds ?? 0,
    cost: settings?.prediction_cost ?? 50,
    packages,
    orders: orders || [],
    profile: {
      id: profile.id,
      fullName: profile.full_name,
      email: profile.email,
      phone: profile.phone,
      referralCode: profile.referral_code,
      status: profile.status,
      country: profile.country || null
    },
    predictions: predictions || []
  };
}
// Map short abbreviations to full team names (as seen in betting screenshots)
const ABBREV_MAP = {
  // CLUBS (priority — used in Champions League / domestic leagues)
  'ARS': 'Arsenal', 'CHE': 'Chelsea', 'LIV': 'Liverpool', 'MCI': 'Man City', 'MUN': 'Man United', 'TOT': 'Tottenham',
  'RMA': 'Real Madrid', 'RM': 'Real Madrid', 'BAR': 'Barcelona', 'FCB': 'Barcelona', 'ATM': 'Atletico Madrid',
  'BAY': 'Bayern Munich', 'BVB': 'Dortmund', 'PSG': 'PSG', 'JUV': 'Juventus', 'ACM': 'AC Milan', 'INT': 'Inter Milan',
  'NAP': 'Napoli', 'BEN': 'Benfica', 'SCP': 'Sporting CP', 'AJX': 'Ajax',
  'OL': 'Lyon', 'OLM': 'Marseille', 'MON': 'Monaco', 'LIL': 'Lille',
  'NEW': 'Newcastle', 'AVL': 'Aston Villa', 'WHU': 'West Ham', 'BHA': 'Brighton',
  'BRE': 'Brentford', 'FUL': 'Fulham', 'CRY': 'Crystal Palace', 'WOL': 'Wolves',
  'BUR': 'Burnley', 'SHU': 'Sheffield United', 'NFO': 'Nottingham Forest',
  'ROM': 'Roma', 'LAZ': 'Lazio', 'FIO': 'Fiorentina', 'ATA': 'Atalanta', 'TOR': 'Torino',
  'SEV': 'Sevilla', 'RBS': 'Real Sociedad', 'VIL': 'Villarreal', 'BET': 'Real Betis',
  'LEV': 'Bayer Leverkusen', 'SGE': 'Frankfurt', 'RBL': 'RB Leipzig',
  'POR': 'Porto', 'BSC': 'Hertha Berlin',
  // INTERNATIONALS (only used when context is international)
  'AUT': 'Austria', 'SUI': 'Switzerland', 'SCO': 'Scotland', 'IRE': 'Ireland',
  'GER': 'Germany', 'FRA2': 'France', 'ESP': 'Spain', 'ITA': 'Italy', 'ENG': 'England',
  'NED': 'Netherlands', 'BEL': 'Belgium', 'CRO': 'Croatia',
  'CZE': 'Czech Republic', 'POL': 'Poland', 'SWE': 'Sweden', 'NOR': 'Norway',
  'DEN': 'Denmark', 'WAL': 'Wales', 'UKR': 'Ukraine', 'SRB': 'Serbia'
};

function expandAbbrev(name) {
  if (!name) return name;
  const trimmed = name.trim();
  if (ABBREV_MAP[trimmed]) return ABBREV_MAP[trimmed];
  return trimmed;
}

// OCR: Extract team names from fixture screenshot using Gemini Vision (text extraction only)
async function callOCRScan(fileBase64, mime, geminiKey) {
  const geminiUrl = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent?key=${geminiKey}`;
  const prompt = `Look at this football fixture screenshot. Extract ALL fixture data visible: team abbreviations (like BEN, ARS, POR, INT, SCP, ATM, CHE, NAP, MCI, FCB, PSG, MUN), odds (1X2 format: home/draw/away), and league name if visible. Return a JSON array: [{"home":"BEN","away":"ARS","odds_home":2.91,"odds_draw":3.95,"odds_away":2.20,"league":"Champions"}] — include ALL matches visible in the image.`;

  const payload = {
    contents: [{ parts: [
      { text: prompt },
      { inlineData: { mimeType: mime || 'image/jpeg', data: fileBase64 } }
    ] }]
  };

  const response = await fetch(geminiUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });

  if (!response.ok) throw new Error('OCR scan failed');
  const resJson = await response.json();
  const rawText = resJson?.candidates?.[0]?.content?.parts?.[0]?.text?.trim() ?? '';
  const cleaned = rawText.replace(/```json/gi, '').replace(/```/g, '').trim();
  try {
    const fixtures = JSON.parse(cleaned);
    if (Array.isArray(fixtures) && fixtures.length > 0) return fixtures;
  } catch (_) {}
  return [];
}

// Generate predictions from extracted fixture text (local prediction engine)
function generatePredictions(fixtures) {
  const picks = ['1', 'X', '2'];
  const pickLabels = {'1': 'Home Win', 'X': 'Draw', '2': 'Away Win'};
  return fixtures.map(fix => {
    // Randomly pick Home, Draw, or Away
    const roll = picks[Math.floor(Math.random() * 3)];
    const pickLabel = pickLabels[roll];
    // Random confidence between 55-92%
    const confidence = Math.floor(Math.random() * 38) + 55;
    // Random correct score based on pick
    let correctScore;
    if (roll === '1') correctScore = `${Math.floor(Math.random()*3)+1}-${Math.floor(Math.random()*2)}`;
    else if (roll === 'X') correctScore = `${Math.floor(Math.random()*2)+1}-${Math.floor(Math.random()*2)+1}`;
    else correctScore = `${Math.floor(Math.random()*2)}-${Math.floor(Math.random()*3)+1}`;
    // Probabilities weighted toward the picked outcome
    let probHome = roll === '1' ? confidence : Math.floor(Math.random() * 25) + 15;
    let probAway = roll === '2' ? confidence : Math.floor(Math.random() * 20) + 10;
    let probDraw = Math.max(10, 100 - probHome - probAway);
    return {
      home: fix.home, away: fix.away,
      league: fix.league || '',
      probabilities: { home: probHome, draw: probDraw, away: probAway },
      odds: { home: fix.odds_home || null, draw: fix.odds_draw || null, away: fix.odds_away || null },
      pick: roll, pickLabel,
      confidence,
      drawChance: probDraw,
      correctScore,
      goals: probHome > 60 ? 'Over 2.5' : 'Under 2.5',
      note: `OCR: ${fix.home} vs ${fix.away}` + (fix.league ? ` (${fix.league})` : '')
    };
  });
}

// POST: get-prediction — now uses atomic server-side RPC
// The RPC handles: balance check, deduction, logging, and prediction insert in one transaction
export async function n(props) {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) { showErrorToast('Please log in to continue.', 'error'); throw new Error("Unauthorized"); }

  const { fileBase64, mime, fileName } = props?.data ?? {};
  let matches = [];
  let usedOCR = false;

  // Step 1: OCR scan — extract team names from screenshot
  try {
    const { data: keyData } = await supabase.rpc('get_gemini_key').maybeSingle();
    let geminiKey = keyData?.gemini_api_key || null;

    if (geminiKey && fileBase64) {
      const fixtures = await callOCRScan(fileBase64, mime || 'image/jpeg', geminiKey);
      if (Array.isArray(fixtures) && fixtures.length > 0) {
        // Keep abbreviations as-is (BEN, ARS, POR, etc.)
        // Randomly pick 2-3 games from all detected fixtures
        const shuffled = [...fixtures].sort(() => Math.random() - 0.5);
        const picked = shuffled.slice(0, Math.floor(Math.random() * 2) + 2); // 2 or 3 games
        matches = generatePredictions(picked);
        if (matches.length > 0) usedOCR = true;
      }
    }
  } catch (ocrErr) {
    console.warn('[VirtualHub] OCR scan failed:', ocrErr?.message);
    showErrorToast('OCR scan unavailable — using backup predictions.', 'warning');
  }

  // Fallback: if OCR didn't work, predict from top fixture matchups (abbreviations)
  if (!usedOCR) {
    const topFixtures = [
      {home: 'BEN', away: 'ARS', league: 'Champions', odds_home: 2.91, odds_draw: 3.95, odds_away: 2.20},
      {home: 'POR', away: 'INT', league: 'Champions', odds_home: 3.11, odds_draw: 4.07, odds_away: 2.07},
      {home: 'SCP', away: 'ATM', league: 'Champions', odds_home: 1.54, odds_draw: 5.25, odds_away: 4.72},
      {home: 'CHE', away: 'NAP', league: 'Champions', odds_home: 1.34, odds_draw: 5.79, odds_away: 7.55},
      {home: 'MCI', away: 'FCB', league: 'Champions', odds_home: 1.99, odds_draw: 4.36, odds_away: 3.15},
      {home: 'PSG', away: 'MUN', league: 'Champions', odds_home: 1.92, odds_draw: 5.02, odds_away: 3.02}
    ];
    // Pick 2-3 random games
    const shuffled = [...topFixtures].sort(() => Math.random() - 0.5);
    const picked = shuffled.slice(0, Math.floor(Math.random() * 2) + 2);
    matches = generatePredictions(picked);
  }

  // Fetch prediction cost from settings (admin-configurable)
  let cost = 50;
  try {
    const { data: costRow } = await supabase
      .from('settings')
      .select('prediction_cost')
      .eq('id', 'global_config')
      .maybeSingle();
    if (costRow?.prediction_cost) cost = costRow.prediction_cost;
  } catch (_) { /* use default */ }

  // Atomic server-side: deducts diamonds + logs transaction + inserts prediction in one tx
  const { data: rpcResult, error: rpcErr } = await supabase.rpc('submit_prediction', {
    p_user_id: user.id,
    p_result: { matches, source: usedOCR ? 'ocr' : 'model' },
    p_cost: cost,
    p_source: usedOCR ? 'ocr' : 'model'
  });

  if (rpcErr) {
    const { category, userMessage } = classifyError(rpcErr);
    if (category === 'balance') {
      showErrorToast('Not enough diamonds for a prediction. Purchase more to continue.', 'warning');
    } else if (category === 'network') {
      showErrorToast('Connection lost during prediction. Please try again.', 'error');
    } else {
      showErrorToast(`Prediction failed: ${userMessage}`, 'error');
    }
    throw rpcErr;
  }
  if (!rpcResult?.ok) {
    const reason = rpcResult?.reason || 'Unknown error';
    if (reason.includes('insufficient')) {
      showErrorToast('Not enough diamonds. Purchase a package to continue.', 'warning');
    } else {
      showErrorToast(`Prediction failed: ${reason}`, 'error');
    }
    return rpcResult;
  }

  return { ok: true, matches, source: usedOCR ? 'ocr' : 'model' };
}

// POST: history clear/delete function
export async function r(props) {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) { showErrorToast('Please log in to continue.', 'error'); throw new Error("Unauthorized"); }

  const id = props?.data?.id;

  if (id === 'all' || !id) {
    const { error } = await supabase
      .from('predictions')
      .delete()
      .eq('user_id', user.id);

    if (error) {
      const { userMessage } = classifyError(error);
      showErrorToast(`Could not clear history: ${userMessage}`);
      throw error;
    }
  } else {
    const { error } = await supabase
      .from('predictions')
      .delete()
      .eq('id', id)
      .eq('user_id', user.id);

    if (error) {
      const { userMessage } = classifyError(error);
      showErrorToast(`Could not delete prediction: ${userMessage}`);
      throw error;
    }
  }

  return { ok: true };
}

// POST: submit diamond order
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

export async function o(props) {
  const { packageId, packageName, diamonds, country, method, amount, currency, txnId, senderName, senderNumber, fileName, fileBase64 } = props?.data ?? {};
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) { showErrorToast('Please log in to continue.', 'error'); throw new Error("Unauthorized"); }

  // Upload screenshot
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
      package_name: packageName,
      diamonds: Number(diamonds),
      amount: Number(amount),
      currency,
      method,
      txn_id: txnId || null,
      sender_name: senderName,
      sender_number: senderNumber,
      screenshot_path: screenshotPath,
      status: 'pending',
      asset_type: 'diamond',
      ocr_name: ocrName
    })
    .select()
    .single();

  if (error) {
    const { userMessage } = classifyError(error);
    showErrorToast('Diamond order failed: ' + userMessage, 'error');
    throw error;
  }
  return { ok: true, order: data };
}
