const express = require('express');
const cors = require('cors');
const nodemailer = require('nodemailer');
const { body, validationResult } = require('express-validator');

const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
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
const transporter = nodemailer.createTransport({
  host: SMTP_HOST,
  port: Number(SMTP_PORT) || 587,
  secure: false,
  requireTLS: true,
  auth: { user: SMTP_USER, pass: SMTP_PASS }
});
transporter.verify()
  .then(() => console.log(`SMTP ready: ${SMTP_HOST}:${Number(SMTP_PORT) || 587} as ${SMTP_USER}`))
  .catch(err => console.error('SMTP verify failed:', err.message));

app.post('/api/contact/send', [
  body('name').trim().notEmpty().withMessage('Name is required').escape(),
  body('email').isEmail().withMessage('Valid email is required').normalizeEmail(),
  body('subject').trim().notEmpty().withMessage('Subject is required').escape(),
  body('message').trim().notEmpty().withMessage('Message is required').escape()
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({ success: false, error: errors.array()[0].msg });
  }
  const { name, email, subject, message } = req.body;
  try {
    await transporter.sendMail({
      // IONOS only relays for the authenticated mailbox, so From must be SMTP_USER.
      from: `"Chess Puerto Rico Coffee" <${SMTP_USER}>`,
      replyTo: email,
      to: process.env.CONTACT_TO || 'contact-recipient@example.com', // sanitized for publication,
      subject: `[Chess PR Coffee] ${subject} — from ${name}`,
      text: `Name: ${name}\nEmail: ${email}\nSubject: ${subject}\n\n${message}`,
      html: `
        <div style="font-family:sans-serif;max-width:600px">
          <h2 style="color:#D4A76A;margin-bottom:4px">New Contact Message</h2>
          <p style="color:#888;font-size:13px;margin-top:0">from chesspuertoricocoffee.com</p>
          <table style="width:100%;border-collapse:collapse;margin:16px 0">
            <tr><td style="padding:8px;border-bottom:1px solid #eee;font-weight:bold;width:100px">Name</td><td style="padding:8px;border-bottom:1px solid #eee">${name}</td></tr>
            <tr><td style="padding:8px;border-bottom:1px solid #eee;font-weight:bold">Email</td><td style="padding:8px;border-bottom:1px solid #eee"><a href="mailto:${email}">${email}</a></td></tr>
            <tr><td style="padding:8px;border-bottom:1px solid #eee;font-weight:bold">Subject</td><td style="padding:8px;border-bottom:1px solid #eee">${subject}</td></tr>
          </table>
          <div style="padding:16px;background:#f5f5f5;border-radius:8px;white-space:pre-wrap">${message}</div>
          <p style="color:#999;font-size:12px;margin-top:16px">♞ Sent via Chess Puerto Rico Coffee contact form</p>
        </div>
      `
    });
    res.json({ success: true });
  } catch (err) {
    console.error('Contact email error:', err);
    res.status(500).json({ success: false, error: 'Failed to send message. Please try again.' });
  }
});

const PORT = 3001;
app.listen(PORT, '127.0.0.1', () => {
  console.log(`♞ Chess Contact API running on port ${PORT}`);
});
