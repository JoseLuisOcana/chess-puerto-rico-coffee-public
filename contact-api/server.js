const express = require('express');
const cors = require('cors');
const nodemailer = require('nodemailer');
const { body, validationResult } = require('express-validator');

// BUTTON 259 (2026-11-26, owner; Codex review item 09): the public form endpoint is limited, and the service runs as its own
// unprivileged user (chess-contact), not root. Per visitor (X-Real-IP, which nginx sets from the connecting address): at most
// SENT_PER_IP messages sent and ATTEMPTS_PER_IP requests in 10 minutes; everyone together: at most SENT_PER_HOUR messages an hour (a fuse
// against mail floods). JSON only (the form sends JSON; other sites cannot post it from a plain HTML form), body at most 64 KB, field
// lengths below. Counters live in memory (a restart resets them; at most MAX_TRACKED visitors are tracked at once).
const LIMITS = { name: 100, email: 254, subject: 100, message: 5000 };
const WINDOW_MS = 10 * 60 * 1000, SENT_PER_IP = 3, ATTEMPTS_PER_IP = 30;
const HOUR_MS = 60 * 60 * 1000, SENT_PER_HOUR = 30, MAX_TRACKED = 10000;

const app = express();
app.disable('x-powered-by');
app.use(cors({ origin: 'https://chesspuertoricocoffee.com', credentials: true }));

// 2026-10-02: send through IONOS SMTP (587 + STARTTLS) instead of local sendmail. Direct
// delivery from this VPS failed SPF (~all) and carried no DKIM, so mail landed in junk.
// Credentials come from /etc/chess-contact.env (root-only), loaded by the systemd drop-in
// /etc/systemd/system/chess-contact.service.d/smtp.conf - never from this file.
const { SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS } = process.env;
if (!SMTP_HOST || !SMTP_USER || !SMTP_PASS) {
  console.error('SMTP_HOST/SMTP_USER/SMTP_PASS missing - is /etc/chess-contact.env loaded?');
  process.exit(1);
}
const transporter = nodemailer.createTransport({   // @TRANSPORT@ (the BUTTON 259 test build replaces this line only)
  host: SMTP_HOST,
  port: Number(SMTP_PORT) || 587,
  secure: false,
  requireTLS: true,
  auth: { user: SMTP_USER, pass: SMTP_PASS },
  connectionTimeout: 15000, greetingTimeout: 15000, socketTimeout: 30000   // an answer well inside nginx's 60 s
});
transporter.verify().then(() => console.log(`SMTP ready: ${SMTP_HOST}:${Number(SMTP_PORT) || 587} as ${SMTP_USER}`)).catch(err => console.error('SMTP verify failed:', err.message));   // @VERIFY@

const visitors = new Map();   // ip -> { attempts: [times], sent: [times] }
let sentAll = [];             // times of messages sent (or being sent) by everyone
const recent = (list, ms, now) => list.filter(t => now - t < ms);
setInterval(() => {           // forget old entries
  const now = Date.now();
  for (const [ip, v] of visitors) {
    v.attempts = recent(v.attempts, WINDOW_MS, now); v.sent = recent(v.sent, WINDOW_MS, now);
    if (!v.attempts.length && !v.sent.length) visitors.delete(ip);
  }
  sentAll = recent(sentAll, HOUR_MS, now);
}, 60 * 1000).unref();

const tooMany = (res, msg) => res.status(429).json({ success: false, error: msg });
function limitAttempts(req, res, next) {   // runs BEFORE the body is read
  const now = Date.now();
  const ip = String(req.get('X-Real-IP') || req.socket.remoteAddress || 'unknown').slice(0, 64);
  let v = visitors.get(ip);
  if (!v) {
    if (visitors.size >= MAX_TRACKED) {   // reclaim expired visitors first; refuse only when the table is really full
      for (const [k, x] of visitors) if (!recent(x.attempts, WINDOW_MS, now).length && !recent(x.sent, WINDOW_MS, now).length) visitors.delete(k);
    }
    if (visitors.size >= MAX_TRACKED) return tooMany(res, 'The contact form is busy right now. Please try again later.');
    v = { attempts: [], sent: [] }; visitors.set(ip, v);
  }
  v.attempts = recent(v.attempts, WINDOW_MS, now);
  if (v.attempts.length >= ATTEMPTS_PER_IP) return tooMany(res, 'Too many tries from you in a short time. Please try again in 10 minutes.');
  v.attempts.push(now); req.visitor = v;
  next();
}
const requireJson = (req, res, next) => req.is('application/json') ? next()
  : res.status(415).json({ success: false, error: 'Please use the form on the contact page.' });

app.post('/api/contact/send', limitAttempts, requireJson, express.json({ limit: '64kb' }), [
  body('name').isString().bail().trim().notEmpty().withMessage('Name is required')
    .isLength({ max: LIMITS.name }).withMessage(`Name: at most ${LIMITS.name} characters`),
  body('email').isString().bail().trim().isLength({ max: LIMITS.email }).withMessage(`Email: at most ${LIMITS.email} characters`)
    .bail().isEmail().withMessage('Valid email is required'),
  body('subject').isString().bail().trim().notEmpty().withMessage('Subject is required')
    .isLength({ max: LIMITS.subject }).withMessage(`Subject: at most ${LIMITS.subject} characters`),
  body('message').isString().bail().trim().notEmpty().withMessage('Message is required')
    .isLength({ max: LIMITS.message }).withMessage(`Message: at most ${LIMITS.message} characters`)
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({ success: false, error: errors.array()[0].msg });
  }
  const now = Date.now(), v = req.visitor;
  v.sent = recent(v.sent, WINDOW_MS, now);
  if (v.sent.length >= SENT_PER_IP) return tooMany(res, 'You have sent several messages in a short time. Please try again in 10 minutes.');
  sentAll = recent(sentAll, HOUR_MS, now);
  if (sentAll.length >= SENT_PER_HOUR) {
    console.warn(`rate limit: ${SENT_PER_HOUR} messages in the last hour from everyone - refused`);
    return tooMany(res, 'The contact form is busy right now. Please try again in an hour.');
  }
  sentAll.push(now); v.sent.push(now);   // the slot is reserved BEFORE sending; given back if the send fails
  const release = () => { let i = sentAll.indexOf(now); if (i >= 0) sentAll.splice(i, 1); i = v.sent.indexOf(now); if (i >= 0) v.sent.splice(i, 1); };
  const oneLine = s => s.replace(/[\u0000-\u001f\u007f]+/g, ' ');   // no control characters in the mail subject
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  const { name, email, subject, message } = req.body;
  try {
    const info = await transporter.sendMail({
      // IONOS only relays for the authenticated mailbox, so From must be SMTP_USER.
      from: `"Chess Puerto Rico Coffee" <${SMTP_USER}>`,
      replyTo: { name: oneLine(name), address: email },
      to: process.env.CONTACT_TO || 'contact-recipient@example.com', // sanitized for publication,
      subject: `[Chess PR Coffee] ${oneLine(subject)} — from ${oneLine(name)}`,
      text: `Name: ${name}\nEmail: ${email}\nSubject: ${subject}\n\n${message}`,
      html: `
        <div style="font-family:sans-serif;max-width:600px">
          <h2 style="color:#D4A76A;margin-bottom:4px">New Contact Message</h2>
          <p style="color:#888;font-size:13px;margin-top:0">from chesspuertoricocoffee.com</p>
          <table style="width:100%;border-collapse:collapse;margin:16px 0">
            <tr><td style="padding:8px;border-bottom:1px solid #eee;font-weight:bold;width:100px">Name</td><td style="padding:8px;border-bottom:1px solid #eee">${esc(name)}</td></tr>
            <tr><td style="padding:8px;border-bottom:1px solid #eee;font-weight:bold">Email</td><td style="padding:8px;border-bottom:1px solid #eee">${esc(email)}</td></tr>
            <tr><td style="padding:8px;border-bottom:1px solid #eee;font-weight:bold">Subject</td><td style="padding:8px;border-bottom:1px solid #eee">${esc(subject)}</td></tr>
          </table>
          <div style="padding:16px;background:#f5f5f5;border-radius:8px;white-space:pre-wrap">${esc(message)}</div>
          <p style="color:#999;font-size:12px;margin-top:16px">♞ Sent via Chess Puerto Rico Coffee contact form (reply to answer the sender)</p>
        </div>
      `
    });
    console.log(`sent: ${info.messageId} ${String(info.response || '').slice(0, 80)}`);
    res.json({ success: true });
  } catch (err) {
    release();
    console.error('Contact email error:', err.message);
    res.status(500).json({ success: false, error: 'Failed to send message. Please try again.' });
  }
});

// a too-large or malformed body: a short JSON answer, not an HTML error page
app.use((err, req, res, next) => {
  if (err && (err.type === 'entity.too.large' || err.status === 413)) return res.status(413).json({ success: false, error: 'Message too large.' });
  if (err && err.status === 400) return res.status(400).json({ success: false, error: 'Bad request.' });
  console.error('Contact API error:', err && err.message);
  return res.status(500).json({ success: false, error: 'Failed to send message. Please try again.' });
});

const PORT = 3001;   // @PORT@ (the BUTTON 259 test build replaces this line only)
app.listen(PORT, '127.0.0.1', () => {
  console.log(`♞ Chess Contact API running on port ${PORT}`);
});
