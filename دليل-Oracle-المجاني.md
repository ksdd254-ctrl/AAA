# رفع Jdo X Abu Qht على Oracle Cloud المجاني (24 ساعة، بدون أي فلوس)

> البطاقة للتحقق بس. السيرفر المجاني (Always Free) ما ينخصم عليه شي، بشرط ما تسوي **Upgrade** للحساب.

## 1. التسجيل (5 دقايق)

1. **افتح التسجيل:** ادخل https://signup.cloud.oracle.com واضغط **Sign up**.
2. **اختر المنطقة:** في **Home Region** اختر **Saudi Arabia West (Jeddah)**. هذا الأقرب لكم، وما ينغيّر بعدين.
3. **أكمل الحساب:** اكتب معلوماتك، وأكّد الإيميل والجوال، وحط البطاقة للتحقق.

## 2. إنشاء السيرفر

1. **افتح صفحة الإنشاء:** من القائمة: **Compute ← Instances ← Create instance**.
2. **الاسم:** اكتب `jdo-server`.
3. **النظام:** في **Image and shape** اضغط **Edit**:
   - **Image:** اختر **Canonical Ubuntu 24.04**.
   - **Shape:**
     - اختر **Ampere (VM.Standard.A1.Flex)** وحط **1 OCPU و 6 GB**.
     - إذا قال لك ما فيه مكان (Out of capacity)، اختر **VM.Standard.E2.1.Micro**. يكفي برنامجنا.
     - تأكد إن جنبه مكتوب **Always Free-eligible**.
4. **الشبكة:** في **Networking** خلّ **Assign a public IPv4 address** مفعّل.
5. **مفتاح الدخول:** في **Add SSH keys** اختر **Paste public keys** والصق هذا السطر كامل:
   ```
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGR9owZXOmb0sEz3/wV4GTDtoG3Qy8KS7DH8+QrNp5ih jdo-server
   ```
6. **الإنشاء:** اضغط **Create** وانتظر لين يصير **Running**.

## 3. فتح منافذ الموقع

1. **افتح الشبكة:** في صفحة السيرفر اضغط على اسم الشبكة (**Virtual cloud network**).
2. **افتح القواعد:** اختر **Security Lists ← Default Security List ← Add Ingress Rules**.
3. **أضف القاعدة:**
   - **Source CIDR:** `0.0.0.0/0`
   - **IP Protocol:** TCP
   - **Destination Port Range:** `80,443`
4. **الحفظ:** اضغط **Add Ingress Rules**.

## 4. أرسل لي

**Public IP address** من صفحة السيرفر، مثلاً `158.101.20.30`.

وأنا أكمل الباقي:
- أرفع السيرفر (الحسابات، ملف البرنامج، الإعدادات).
- أشغّله 24 ساعة ومعه HTTPS.
- أبني البرنامج على العنوان الجديد، وأتأكد إن كل شي شغال.

**عنوان الموقع:** إذا ما عندك دومين، نستخدم عنوان مجاني مبني على الـ IP، مثل `158-101-20-30.sslip.io`. يشتغل مع HTTPS وما يحتاج تسجيل. إذا اشتريت دومين بعدين، نقدر ننقل عليه.
