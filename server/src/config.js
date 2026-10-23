require('dotenv').config();

const env = process.env;

module.exports = {
  port: Number(env.PORT || 8080),
  baseUrl: (env.BASE_URL || 'http://localhost:8080').replace(/\/$/, ''),
  dev: env.NODE_ENV !== 'production',

  ownerEmail: (env.OWNER_EMAIL || '').toLowerCase(),

  // Email: SMTP (e.g. a Gmail app password). With no SMTP the codes are printed to the console.
  // MAIL_CONSOLE=1 prints mail to the log instead of sending it (tests).
  smtp: env.MAIL_CONSOLE !== '1' && env.SMTP_HOST && env.SMTP_USER && env.SMTP_PASS ? {
    host: env.SMTP_HOST, port: Number(env.SMTP_PORT || 465), secure: env.SMTP_SECURE !== 'false',
    auth: { user: env.SMTP_USER, pass: env.SMTP_PASS },
  } : null,
  mailFrom: env.MAIL_FROM || 'Jdo X Abu Qht <no-reply@jdo-tweak.com>',

  // Payments. Apple Pay / Google Pay appear automatically in Stripe Checkout once the domain is verified in Stripe.
  stripeSecret: env.STRIPE_SECRET_KEY || '',
  stripeWebhookSecret: env.STRIPE_WEBHOOK_SECRET || '',

  // Bot protection: Cloudflare Turnstile (free). Without keys the check is skipped in dev only.
  turnstileSite: env.TURNSTILE_SITE_KEY || '',
  turnstileSecret: env.TURNSTILE_SECRET_KEY || '',

  // The installer users download after paying.
  downloadFile: env.DOWNLOAD_FILE || require('path').join(__dirname, '..', 'files', 'JdoTweak.exe'),
  liteWindowsUrl: env.LITE_WINDOWS_URL || '',

  plans: {
    basic:         { tier: 1, lite: false, price: 1000, ar: 'بيسك',              en: 'Basic' },
    elite:         { tier: 2, lite: false, price: 2500, ar: 'إيليت',             en: 'Elite' },
    ultimate:      { tier: 3, lite: false, price: 3500, ar: 'ألتميت',            en: 'Ultimate' },
  },
};
