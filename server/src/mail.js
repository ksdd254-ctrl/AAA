const nodemailer = require('nodemailer');
const cfg = require('./config');

const transport = cfg.smtp ? nodemailer.createTransport(cfg.smtp) : null;

async function send(to, subject, html) {
  if (!transport) {
    console.log(`\n[mail -> ${to}] ${subject}\n${html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim()}\n`);
    return;
  }
  try { await transport.sendMail({ from: cfg.mailFrom, to, subject, html }); }
  catch (e) {
    // A mail failure must never take the server down; the caller still gets an error to report.
    console.error(`[mail] failed to send to ${to}: ${e.message}`);
    throw Object.assign(new Error('mail'), { mailFailed: true });
  }
}

const wrap = (body) => `<div style="font-family:Segoe UI,Tahoma,Arial;background:#0b0b14;color:#f1f0ff;padding:32px">
  <div style="max-width:520px;margin:auto;background:#151524;border-radius:16px;padding:28px;border:1px solid #26263c">
    <div style="font-size:22px;font-weight:700;color:#a78bfa;margin-bottom:16px">Jdo X Abu Qht</div>${body}</div></div>`;

module.exports = {
  code: (to, code) => send(to, `رمز التحقق ${code} · Verification code`, wrap(`
    <p>رمز التحقق حقك / Your verification code:</p>
    <div style="font-size:34px;letter-spacing:8px;font-weight:700;color:#22d3ee;margin:16px 0">${code}</div>
    <p style="color:#8e8cab">ينتهي خلال 10 دقائق · Expires in 10 minutes</p>`)),

  purchase: (to, planName, key, downloadUrl, liteUrl) => send(to, `مفتاحك ورابط التحميل · Your key and download`, wrap(`
    <p>شكراً لاشتراكك في باقة <b>${planName}</b>! · Thanks for buying <b>${planName}</b>!</p>
    <p>مفتاح الترخيص / License key:</p>
    <div style="font-family:Consolas,monospace;font-size:20px;background:#0b0b14;padding:14px;border-radius:10px;color:#22d3ee">${key}</div>
    <p style="margin-top:20px"><a href="${downloadUrl}" style="background:linear-gradient(90deg,#a78bfa,#22d3ee);color:#0b0b14;padding:12px 22px;border-radius:10px;text-decoration:none;font-weight:700">تحميل البرنامج · Download</a></p>
    ${liteUrl ? `<p><a href="${liteUrl}" style="color:#a78bfa">تحميل الويندوز المخفف · Download Lite Windows</a></p>` : ''}
    <p style="color:#8e8cab">سجّل دخول في البرنامج بإيميلك وكلمة المرور والمفتاح. المفتاح ينربط بجهاز واحد.<br>Sign in to the app with your email, password and key. The key binds to one PC.</p>`)),
};
