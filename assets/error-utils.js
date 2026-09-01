/**
 * VirtualHub Error Utilities
 * ──────────────────────────
 * Shared error handling for uploads, RPCs, and user-facing messages.
 * 
 * Usage:
 *   import { handleUploadError, handleRpcError, classifyError } from './error-utils.js';
 *   try { ... } catch (err) { handleUploadError(err); }
 */

// ── Error Classification ──────────────────────────────────────────

/**
 * Classifies a Supabase/storage error into a category + user message.
 * @param {Error|object} err - The error from Supabase client
 * @returns {{ category: string, userMessage: string, technicalMessage: string, retryable: boolean }}
 */
export function classifyError(err) {
  if (!err) {
    return { category: 'unknown', userMessage: 'An unexpected error occurred.', technicalMessage: 'null error', retryable: false };
  }

  const msg = (err.message || err.msg || '').toLowerCase();
  const status = err.status || err.statusCode || 0;
  const code = err.code || '';

  // ── Network errors ──
  if (msg.includes('failed to fetch') || msg.includes('networkerror') || msg.includes('network request failed') || msg.includes('econnrefused') || msg.includes('enotfound')) {
    return { category: 'network', userMessage: 'No internet connection. Please check your network and try again.', technicalMessage: err.message, retryable: true };
  }

  if (msg.includes('timeout') || msg.includes('timed out')) {
    return { category: 'network', userMessage: 'Request timed out. The server may be busy — please try again.', technicalMessage: err.message, retryable: true };
  }

  // ── Auth errors ──
  if (status === 401 || msg.includes('unauthorized') || msg.includes('invalid_token') || msg.includes('jwt expired') || msg.includes('session_not_found')) {
    return { category: 'auth', userMessage: 'Your session expired. Please log in again.', technicalMessage: err.message, retryable: false };
  }

  if (status === 403 || msg.includes('forbidden') || msg.includes('permission denied') || msg.includes('permission_denied')) {
    return { category: 'auth', userMessage: 'You don\'t have permission to do this.', technicalMessage: err.message, retryable: false };
  }

  // ── Storage / Upload errors ──
  if (msg.includes('file too large') || msg.includes('payload_too_large') || status === 413) {
    return { category: 'storage', userMessage: 'File is too large. Maximum size is 5MB.', technicalMessage: err.message, retryable: false };
  }

  if (msg.includes('invalid file type') || msg.includes('mime') || msg.includes('content-type')) {
    return { category: 'storage', userMessage: 'Invalid file type. Please upload a PNG, JPG, or WEBP image.', technicalMessage: err.message, retryable: false };
  }

  if (msg.includes('bucket') && (msg.includes('not found') || msg.includes('does not exist'))) {
    return { category: 'storage', userMessage: 'Upload service is not configured. Please contact support.', technicalMessage: err.message, retryable: false };
  }

  if (msg.includes('row level security') || msg.includes('rls') || msg.includes('policy') || status === 403) {
    return { category: 'storage', userMessage: 'Upload failed due to a permissions issue. Please try again or contact support.', technicalMessage: err.message, retryable: false };
  }

  if (msg.includes('upload') || code.includes('storage') || code.includes('upload')) {
    return { category: 'storage', userMessage: 'Screenshot upload failed. Please try again.', technicalMessage: err.message, retryable: true };
  }

  // ── RPC / Database errors ──
  if (msg.includes('insufficient_diamonds') || msg.includes('insufficient_gold') || msg.includes('insufficient_tickets')) {
    return { category: 'balance', userMessage: 'Not enough credits. Purchase a package to continue.', technicalMessage: err.message, retryable: false };
  }

  if (msg.includes('profile_missing')) {
    return { category: 'auth', userMessage: 'Account not found. Please sign up again.', technicalMessage: err.message, retryable: false };
  }

  if (msg.includes('unauthorized')) {
    return { category: 'auth', userMessage: 'Please log in to continue.', technicalMessage: err.message, retryable: false };
  }

  if (msg.includes('locked') || msg.includes('too many')) {
    return { category: 'rate_limit', userMessage: 'Too many failed attempts. Please wait a few minutes and try again.', technicalMessage: err.message, retryable: false };
  }

  if (msg.includes('invalid') && msg.includes('code')) {
    return { category: 'validation', userMessage: 'Invalid code. Please check and try again.', technicalMessage: err.message, retryable: false };
  }

  // ── Gemini / AI errors ──
  if (msg.includes('gemini') || msg.includes('generativelanguage') || msg.includes('ai') || msg.includes('generatecontent')) {
    return { category: 'ai', userMessage: 'AI analysis temporarily unavailable. Using backup predictions.', technicalMessage: err.message, retryable: true };
  }

  // ── HTTP status codes ──
  if (status >= 500) {
    return { category: 'server', userMessage: 'Server error. Please try again in a moment.', technicalMessage: err.message || `HTTP ${status}`, retryable: true };
  }

  if (status === 429) {
    return { category: 'rate_limit', userMessage: 'Too many requests. Please wait a moment and try again.', technicalMessage: err.message, retryable: true };
  }

  if (status === 404) {
    return { category: 'not_found', userMessage: 'The requested resource was not found.', technicalMessage: err.message, retryable: false };
  }

  // ── RPC-specific errors ──
  if (msg.includes('pgrst') || msg.includes('postgrest')) {
    return { category: 'server', userMessage: 'A server configuration error occurred. Please contact support.', technicalMessage: err.message, retryable: false };
  }

  // ── Fallback ──
  return { category: 'unknown', userMessage: 'Something went wrong. Please try again.', technicalMessage: err.message || String(err), retryable: false };
}

// ── User-Facing Error Display ─────────────────────────────────────

/**
 * Shows a user-friendly error toast/notification.
 * Falls back to console.error if toast system is unavailable.
 * @param {string} message - User-facing message
 * @param {'error'|'warning'|'info'} severity
 */
export function showErrorToast(message, severity = 'error') {
  // Try to use the VirtualHub toast system if available
  if (typeof window !== 'undefined' && window.__ve_toast) {
    window.__ve_toast('Error', message, severity);
    return;
  }

  // Try to use TanStack Query's toast or any global notification system
  if (typeof window !== 'undefined' && window.__showNotification) {
    window.__showNotification(message, severity);
    return;
  }

  // Fallback: create a temporary toast element
  if (typeof document !== 'undefined') {
    const container = document.getElementById('ve-toasts') || (() => {
      const c = document.createElement('div');
      c.id = 've-toasts';
      c.style.cssText = 'position:fixed;top:80px;right:16px;z-index:99999;display:flex;flex-direction:column;gap:8px;max-width:380px;pointer-events:none';
      document.body.appendChild(c);
      return c;
    })();

    const colour = { error: '#ef4444', warning: '#f59e0b', info: '#3b82f6' }[severity] || '#ef4444';
    const el = document.createElement('div');
    el.style.cssText = `background:#0d0d12;border:1px solid ${colour};border-left:4px solid ${colour};border-radius:14px;padding:14px 18px;color:#f1f1f1;font-size:13px;line-height:1.45;box-shadow:0 8px 32px rgba(239,68,68,.25);animation:veSlideIn .3s ease;opacity:1;transition:opacity .35s;pointer-events:auto`;
    el.innerHTML = `<div style="font-weight:800;color:${colour};margin-bottom:3px">${severity === 'error' ? '❌ Error' : severity === 'warning' ? '⚠️ Warning' : 'ℹ️ Info'}</div><div style="color:#9ca3af">${escapeHtml(message)}</div>`;
    container.appendChild(el);

    // Auto-dismiss after 6 seconds
    setTimeout(() => {
      el.style.opacity = '0';
      setTimeout(() => el.remove(), 350);
    }, 6000);
  }

  // Always log to console
  console.error(`[VirtualHub] ${severity}:`, message);
}

// ── Error Handler for Uploads ─────────────────────────────────────

/**
 * Handles upload errors with user-friendly messages and optional retry.
 * @param {Error|object} err - The error
 * @param {object} options - { context: string, retryFn: () => Promise, maxRetries: number }
 * @returns {{ handled: boolean, retried: boolean }}
 */
export async function handleUploadError(err, options = {}) {
  const { context = 'file upload', retryFn = null, maxRetries = 1 } = options;
  const { category, userMessage, retryable, technicalMessage } = classifyError(err);

  console.error(`[VirtualHub] Upload error (${context}):`, technicalMessage);

  // Attempt retry for retryable errors
  if (retryable && retryFn && maxRetries > 0) {
    showErrorToast(`${userMessage} Retrying...`, 'warning');
    try {
      await delay(1000);
      await retryFn();
      return { handled: true, retried: true };
    } catch (retryErr) {
      return handleUploadError(retryErr, { ...options, maxRetries: maxRetries - 1 });
    }
  }

  // Show user-facing error
  showErrorToast(userMessage);
  return { handled: true, retried: false };
}

// ── Error Handler for RPC Calls ───────────────────────────────────

/**
 * Handles RPC call errors with user-friendly messages and optional retry.
 * @param {Error|object} err - The error
 * @param {object} options - { context: string, retryFn: () => Promise, maxRetries: number, silent: boolean }
 * @returns {{ handled: boolean, retried: boolean, result: any }}
 */
export async function handleRpcError(err, options = {}) {
  const { context = 'RPC call', retryFn = null, maxRetries = 1, silent = false } = options;
  const { category, userMessage, retryable, technicalMessage } = classifyError(err);

  console.error(`[VirtualHub] RPC error (${context}):`, technicalMessage);

  // Attempt retry for retryable errors
  if (retryable && retryFn && maxRetries > 0) {
    if (!silent) showErrorToast(`${userMessage} Retrying...`, 'warning');
    try {
      await delay(1500);
      const result = await retryFn();
      return { handled: true, retried: true, result };
    } catch (retryErr) {
      return handleRpcError(retryErr, { ...options, maxRetries: maxRetries - 1 });
    }
  }

  // Show user-facing error (unless silent)
  if (!silent) showErrorToast(userMessage);
  return { handled: true, retried: false, result: null };
}

// ── Predictions Error Handler ─────────────────────────────────────

/**
 * Special handler for prediction errors - falls back to model predictions
 * if Gemini fails, and handles balance errors gracefully.
 */
export function handlePredictionError(err, { hasGeminiKey = false, fileBase64 = null } = {}) {
  const { category, userMessage, technicalMessage } = classifyError(err);

  // If Gemini failed and we have a screenshot, warn but continue with model
  if (category === 'ai' && fileBase64) {
    showErrorToast('AI screenshot analysis failed. Using backup prediction model.', 'warning');
    return { continueWithModel: true };
  }

  // If balance is insufficient, show purchase prompt
  if (category === 'balance') {
    showErrorToast(userMessage, 'warning');
    return { showPurchasePrompt: true };
  }

  // For network errors during prediction, suggest retry
  if (category === 'network') {
    showErrorToast('Connection lost during prediction. Please check your internet and try again.', 'error');
    return { showRetryButton: true };
  }

  // For server errors, show generic message
  showErrorToast(userMessage || 'Prediction failed. Please try again.', 'error');
  return { showRetryButton: true };
}

// ── Spin/Gold Error Handler ───────────────────────────────────────

/**
 * Special handler for spin/gold errors with balance-aware messages.
 */
export function handleSpinError(err) {
  const { category, userMessage } = classifyError(err);

  if (category === 'balance') {
    showErrorToast('Not enough gold coins. Purchase a gold package to continue.', 'warning');
    return { showPurchasePrompt: true };
  }

  showErrorToast(userMessage || 'Spin failed. Please try again.', 'error');
  return { showRetryButton: true };
}

// ── EFootball Error Handler ───────────────────────────────────────

/**
 * Special handler for eFootball booking code errors.
 */
export function handleEfootballError(err) {
  const { category, userMessage } = classifyError(err);

  if (category === 'balance') {
    showErrorToast('Not enough tickets. Contact support for tickets.', 'warning');
    return { showContactSupport: true };
  }

  showErrorToast(userMessage || 'Booking code request failed. Please try again.', 'error');
  return { showRetryButton: true };
}

// ── Helpers ───────────────────────────────────────────────────────

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

// ── Retry Wrapper ─────────────────────────────────────────────────

/**
 * Wraps an async function with retry logic.
 * @param {() => Promise} fn - The function to retry
 * @param {object} options - { maxRetries, delayMs, backoff }
 * @returns {Promise} The result of fn
 */
export async function withRetry(fn, options = {}) {
  const { maxRetries = 2, delayMs = 1000, backoff = 2 } = options;
  let lastError;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err;
      const { retryable } = classifyError(err);

      if (!retryable || attempt >= maxRetries) {
        throw err;
      }

      const waitTime = delayMs * Math.pow(backoff, attempt);
      console.warn(`[VirtualHub] Retry ${attempt + 1}/${maxRetries} after ${waitTime}ms:`, err.message);
      await delay(waitTime);
    }
  }

  throw lastError;
}
