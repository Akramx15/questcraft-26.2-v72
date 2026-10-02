# تثبيت QuestCraft 26.2 personal v72 على Quest 3

هذا دليل من البداية لمستخدم Windows لم يسبق له استعمال ADB. اقرأ الخطوة كاملة
قبل تنفيذ أوامرها، واترك نافذة PowerShell مفتوحة حتى تنتهي.

> [!WARNING]
> هذا **pre-release** وليس إصدار QuestCraft مستقرًا عامًا. يجب أن يتولى شخص
> بالغ إعداد حساب Meta وDeveloper Mode والموافقة على USB debugging. لا تحذف
> تطبيقًا أو instance باسم `26.2`، ولا تستخدم `adb uninstall`، لإصلاح مشكلة.

**English navigation:** See the short
[English quick summary](#english-quick-summary) at the end. The commands and
safety checks are the same.

## الخطة في دقيقة

سنفعل ستة أشياء فقط:

1. يفعّل شخص بالغ Developer Mode وUSB debugging.
2. نضع `adb.exe` وملف APK الرسمي في مجلد واحد على حاسوب Windows.
3. نوصل Quest 3 بكابل بيانات ونختار USB serial الصحيح.
4. نفحص SHA-256 قبل لمس النظارة.
5. نختار مسارًا واحدًا: **تثبيت جديد** أو **ترقية مع نسخة احتياطية**.
6. نتحقق من الإصدار ثم نشغّل Minecraft داخل VR.

## هوية الملف الصحيح

<!-- markdownlint-disable MD013 -->

| الحقل | القيمة المتوقعة |
| --- | --- |
| صفحة الإصدار الرسمية | [`v72-personal.13-perfbase-cd079c65`](https://github.com/Akramx15/questcraft-26.2-v72/releases/tag/v72-personal.13-perfbase-cd079c65) |
| اسم الملف | `QuestCraft-Vivecraft-26.2-personal.13-perfbase-cd079c65.apk` |
| الحجم | `128500669` bytes |
| SHA-256 | `6748C17071B90ED5DC236FBA84CA3BBC4DEAED54C802D0150CFA82B20EFA3680` |
| Android package | `com.qcxr.qcxr.dev262` |
| الاسم الظاهر في النظارة | `Vivecraft Stable` |
| `versionCode` | `72` |
| `versionName` | `6.0.1-26.2-vivecraft-personal.13` |
| Source commit used for APK | private development commit `cd079c65` (ليس ضمن التاريخ العام المضغوط) |
| Signer SHA-256 | `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A` |

<!-- markdownlint-enable MD013 -->

> [!IMPORTANT]
> لا يكفي تشابه الاسم. إذا اختلفت بصمة SHA-256 فلا تثبّت الملف.

## 1. قائمة التجهيز

ضع علامة ذهنية أمام كل عنصر قبل البدء:

- [ ] Meta Quest 3 مشحونة وبها مساحة حرة مناسبة.
- [ ] حاسوب Windows 10 أو 11 موثوق.
- [ ] كابل USB-C **ينقل البيانات**؛ بعض كابلات الشحن لا تنقل بيانات.
- [ ] تطبيق Meta Horizon على هاتف الشخص البالغ، والنظارة مقترنة به.
- [ ] حساب Meta Developer مؤهل ومتحقق؛ Meta تشترط أن يكون صاحب إعداد
  Developer Mode بعمر 18 سنة أو أكثر.
- [ ] اتصال إنترنت لأول تشغيل وتنزيل ملفات Minecraft الرسمية.
- [ ] نسخة قانونية من Minecraft: Java Edition.
- [ ] ملف APK الرسمي وAndroid SDK Platform-Tools من الروابط أدناه.

QGO ليس في القائمة لأنه **اختياري**، وغير مضمّن في APK، وغير مطلوب للتثبيت.
لا تشتره أو تثبّته من أجل اتباع هذا الدليل. يوجد قسم صغير لمن يملكه ومثبتًا
لديه أصلًا.

## 2. تجهيز Quest 3 — يقوم به شخص بالغ

اتبع صفحة Meta الرسمية:
**[Device Setup for Meta Quest](https://developers.meta.com/vr/documentation/native/android/mobile-device-setup/)**.
ملخصها الحالي:

1. انضم إلى developer team أو أنشئ واحدًا، وأكمل تحقق حساب Meta.
2. في تطبيق Meta Horizon على الهاتف: اضغط رمز النظارة، ثم النظارة المقترنة،
   ثم **Headset Settings → Developer Mode** وفعّله.
3. صِل النظارة بالحاسوب بكابل بيانات.
4. داخل النظارة افتح **Quick Controls → Settings → Developer** وفعّل
   **MTP Notification** إذا طلب دليل Meta ذلك.
5. عندما تظهر رسالة **Allow USB debugging?** داخل النظارة، وافق. اختر
   **Always allow from this computer** فقط إذا كان هذا حاسوبك الموثوق.
6. على Windows، نزّل وثبّت **Oculus ADB Drivers** من رابطها داخل صفحة Meta
   الرسمية نفسها.

رسالة السماح بالوصول إلى الملفات ليست بديلًا عن رسالة **USB debugging**.
إذا لم تظهر الرسالة الثانية، أبقِ النظارة مستيقظة، افصل الكابل وأعد توصيله.

## 3. تجهيز مجلد العمل على Windows

### 3.1 نزّل ADB من Google

1. افتح صفحة Google الرسمية:
   **[SDK Platform-Tools for Windows](https://developer.android.com/tools/releases/platform-tools)**.
2. اختر تنزيل Windows ووافق على شروط Google.
3. فك ضغط الملف. سيظهر مجلد اسمه عادةً `platform-tools`.
4. افتح المجلد وتأكد أن بداخله `adb.exe`.

لا تحتاج إلى Android Studio، ولا تحتاج إلى تعديل PATH لهذا الدليل.

### 3.2 نزّل APK الرسمي

1. افتح
   **[صفحة إصدار v72 الرسمية](https://github.com/Akramx15/questcraft-26.2-v72/releases/tag/v72-personal.13-perfbase-cd079c65)**.
2. من **Assets** نزّل هذا الملف بالضبط:
   `QuestCraft-Vivecraft-26.2-personal.13-perfbase-cd079c65.apk`.
3. انقل الملف إلى مجلد `platform-tools` بجانب `adb.exe`.

إذا لم تفتح صفحة الإصدار أو لم تجد الاسم نفسه، توقف. لا تستخدم مرآة أو ملفًا
مرسلًا في رسالة خاصة.

### 3.3 افتح PowerShell في المجلد الصحيح

افتح مجلد `platform-tools` في File Explorer، واضغط شريط العنوان، واكتب
`powershell` ثم Enter. نفّذ:

```powershell
.\adb.exe version
```

علامة النجاح: تظهر معلومات إصدار Android Debug Bridge. إذا ظهرت رسالة أن
`adb.exe` غير موجود، فأنت في المجلد الخطأ أو لم تفك الضغط بعد.

## 4. صِل النظارة واخترها بالاسم

اترك النظارة مستيقظة وموصولة بكابل USB، ثم نفّذ:

```powershell
.\adb.exe devices -l
```

سترى جدولًا. السطر الصحيح يجب أن ينتهي بالحالة `device`، مثل هذا المثال
الخيالي:

```text
List of devices attached
EXAMPLE_SERIAL    device product:... model:...
```

- إذا ظهر `unauthorized`: ضع النظارة ووافق على USB debugging، ثم أعد الأمر.
- إذا لم يظهر شيء: راجع Developer Mode والتعريف والكابل في شجرة الأخطاء.
- إذا ظهر أكثر من سطر: اختر سطر Quest المتصل بـUSB. اتصال Wi-Fi يشبه عادةً
  عنوانًا يحتوي على نقطتين (`:`) ورقم منفذ؛ لا تختَره لهذا الدليل.

انسخ القيمة الأولى من سطر USB فقط. ثم نفّذ الكتلة التالية بعد استبدال النص
`PASTE_USB_SERIAL_HERE` بالقيمة الحقيقية. لا تكتب المثال الوهمي أعلاه.

```powershell
$QuestSerial = "PASTE_USB_SERIAL_HERE"
$Apk = Join-Path $PWD "QuestCraft-Vivecraft-26.2-personal.13-perfbase-cd079c65.apk"

.\adb.exe -s $QuestSerial get-state
```

علامة النجاح هي كلمة:

```text
device
```

> [!TIP]
> أبقِ نافذة PowerShell هذه مفتوحة. إذا أغلقتها، أعد كتلة `$QuestSerial` و`$Apk`
> قبل متابعة أي أمر.

## 5. افحص APK قبل التثبيت

انسخ الكتلة كاملة:

```powershell
$ExpectedHash = "6748C17071B90ED5DC236FBA84CA3BBC4DEAED54C802D0150CFA82B20EFA3680"

if (-not (Test-Path -LiteralPath $Apk -PathType Leaf)) {
    throw "APK not found. Put the exact APK beside adb.exe and try again."
}

$ActualHash = (
    Get-FileHash -LiteralPath $Apk -Algorithm SHA256
).Hash.ToUpperInvariant()

$ActualHash

if ($ActualHash -ne $ExpectedHash) {
    throw "HASH MISMATCH. Do not install this APK."
}

"OK: SHA-256 matches the verified release."
```

علامة النجاح الأخيرة:

```text
OK: SHA-256 matches the verified release.
```

إذا ظهر `HASH MISMATCH`، لا تحاول إصلاح الملف ولا تثبّته. احذف **ملف APK
المنزّل فقط**، ثم نزّله مرة أخرى من صفحة الإصدار الرسمية وأعد الفحص.

## 6. اختر: ترقية أم تثبيت جديد؟

نفّذ هذا الفحص الآمن؛ لا يغير شيئًا:

```powershell
$InstalledPath = @(
    .\adb.exe -s $QuestSerial shell pm path com.qcxr.qcxr.dev262
) | Where-Object { $_ -like "package:*" }

$InstalledPath
```

- إذا ظهر سطر يبدأ بـ`package:`، فالحزمة موجودة: اذهب إلى
  **[7A. الترقية](#7a-ترقية-نسخة-dev262-موجودة)**.
- إذا لم يظهر أي سطر، فالحزمة غير موجودة: اذهب إلى
  **[7B. التثبيت الجديد](#7b-تثبيت-جديد-فقط-إذا-لم-تكن-dev262-موجودة)**.

وجود QuestCraft العام بالحزمة `com.qcxr.qcxr` لا يغيّر القرار؛ هذا البناء يستخدم
الحزمة المنفصلة `com.qcxr.qcxr.dev262`.

## 7A. ترقية نسخة dev262 موجودة

### 7A.1 خذ نسخة احتياطية أولًا

لا تتجاوز هذه الخطوة حتى لو كنت تتوقع أن `-r` سيحفظ البيانات. تثبيت التطبيقات
بـADB لا يعني أن Meta Cloud Backup سيحفظها لك تلقائيًا.

أغلق QuestCraft ثم انسخ ملفات المستخدم وAPK السابق إلى الحاسوب:

```powershell
$Package = "com.qcxr.qcxr.dev262"
$RemoteFiles = "/sdcard/Android/data/$Package/files"
$BackupDir = Join-Path $PWD (
    "QuestCraft-dev262-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
)
$FilesBackup = Join-Path $BackupDir "files"
$PreviousApk = Join-Path $BackupDir "previous-base.apk"

New-Item -ItemType Directory -Path $BackupDir | Out-Null

.\adb.exe -s $QuestSerial shell am force-stop $Package
if ($LASTEXITCODE -ne 0) {
    throw "Could not stop QuestCraft. Stop here."
}

.\adb.exe -s $QuestSerial pull $RemoteFiles $FilesBackup
if ($LASTEXITCODE -ne 0) {
    throw "File backup failed. Do not install yet."
}

$InstalledApkLine = @(
    .\adb.exe -s $QuestSerial shell pm path $Package
) | Where-Object { $_ -like "package:*" } | Select-Object -First 1

if (-not $InstalledApkLine) {
    throw "Could not find the installed APK. Do not install yet."
}

$InstalledApkPath = $InstalledApkLine.Trim() -replace '^package:', ''
.\adb.exe -s $QuestSerial pull $InstalledApkPath $PreviousApk
if ($LASTEXITCODE -ne 0) {
    throw "Previous APK backup failed. Do not install yet."
}

.\adb.exe -s $QuestSerial shell dumpsys package $Package |
    Out-File (Join-Path $BackupDir "package-before.txt") -Encoding utf8

Get-FileHash -LiteralPath $PreviousApk -Algorithm SHA256 |
    Out-File (Join-Path $BackupDir "previous-base.sha256.txt") -Encoding utf8

Get-Item -LiteralPath $BackupDir, $FilesBackup, $PreviousApk
```

افتح المجلد الذي يبدأ اسمه بـ`QuestCraft-dev262-backup-` وتأكد بنفسك من الآتي:

- ملف `previous-base.apk` موجود وحجمه ليس صفرًا.
- مجلد `files` ليس فارغًا.
- إذا كنت تستعمل instance `26.2`، فتأكد أن المسار
  `files\instances\26.2` موجود وأن العوالم المهمة بداخله.

إذا كنت تتوقع عوالم ولا تجدها في النسخة، **توقف ولا تثبّت** حتى تعرف مسارها.
نسخ ADB يحفظ المحتوى المتاح، لكنه ليس صورة كاملة لبيانات Android الخاصة ولا
يحفظ بالضرورة owner أو SELinux metadata.

### 7A.2 نفّذ الترقية

بعد فحص النسخة الاحتياطية:

```powershell
.\adb.exe -s $QuestSerial install -r $Apk
```

علامة النجاح:

```text
Success
```

الخيار `-r` يستبدل APK ويحافظ عادةً على بيانات الحزمة. لكنه **لا يقوم تلقائيًا
بمطابقة أو تحديث مجلد المودات الحي** داخل `26.2`. قد تبقى مودات قديمة أو معدلة
كما هي؛ لا تعتبر محتوى APK دليلًا على حالة ذلك المجلد، ولا تحذف instance لإجباره
على التغير.

إذا ظهر `INSTALL_FAILED_UPDATE_INCOMPATIBLE` أو خطأ توقيع، توقف وانتقل إلى
[شجرة الأخطاء](#10-شجرة-الأخطاء-السريعة). لا تستخدم uninstall كحل سريع.

## 7B. تثبيت جديد فقط إذا لم تكن dev262 موجودة

نفّذ:

```powershell
.\adb.exe -s $QuestSerial install $Apk
```

علامة النجاح:

```text
Success
```

إذا كان فحص الخطوة 6 قد وجد `com.qcxr.qcxr.dev262`، لا تستخدم هذا المسار ولا
تحذف النسخة الموجودة لتبدأ من جديد. ارجع إلى مسار الترقية والنسخة الاحتياطية.

## 8. أول تشغيل

1. تأكد من اتصال النظارة بالإنترنت ومن وجود مساحة حرة.
2. داخل النظارة افتح App Library ثم قسم **Unknown Sources** أو القسم الذي تعرض
   فيه نسخة نظامك التطبيقات المحمّلة جانبيًا.
3. افتح التطبيق الذي يحمل الاسم `Vivecraft Stable`.
4. أكمل تسجيل الدخول بحساب يملك Minecraft: Java Edition.
5. اختر instance `26.2` الذي يعرضه المشغّل. في الترقية، اختر النسخة الموجودة؛
   إذا لم يظهر `26.2`، فلا تنشئ بديلًا فوقه ولا تحذف شيئًا قبل فحص النسخة
   الاحتياطية.
6. اضغط **Play** واترك تنزيل وفحص assets والمكتبات يكتمل. لا تغلق التطبيق
   أثناء التنزيل.
7. علامة النجاح الفعلية هي ظهور قائمة Minecraft الرئيسية بصورة صحيحة داخل
   VR. بعد ذلك فقط افتح عالمًا تجريبيًا أو سيرفرًا.

### QGO اختياري لمن يملكه ومثبتًا لديه أصلًا

تجاوز هذا القسم تمامًا إذا لم تكن تستخدم Quest Games Optimizer. QGO تطبيق
خارجي، لا يأتي داخل APK، ولا يلزم لنجاح التثبيت.

إذا كان لديك QGO بالفعل وتريد baseline الذي استُخدم في القياس على جهاز
الاختبار، فملف `com.qcxr.qcxr.dev262` كان:

| الإعداد | baseline اختباري |
| --- | --- |
| CPU | `4` |
| GPU | `4` |
| Refresh rate | ثابت `72 Hz` |
| FFR | `4` |
| Resolution | `1680 × 1760` |
| Dynamic/adaptive refresh | Off |
| Forced SpaceWarp | Off |

شغّل `Vivecraft Stable` من **Apply/Launch** داخل QGO كي يطبق الملف. هذه قيم
جهاز اختبار وليست ضمان FPS، وليست إعدادات يشحنها APK. ابدأ Render Distance
عند `6` ولا تغيّر أكثر من عامل واحد أثناء المقارنة.

## 9. تحقق من نجاح التثبيت

### 9.1 تحقق من رقم الإصدار

```powershell
.\adb.exe -s $QuestSerial shell dumpsys package com.qcxr.qcxr.dev262 |
    Select-String "versionCode|versionName"
```

ابحث عن:

```text
versionCode=72
versionName=6.0.1-26.2-vivecraft-personal.13
```

قد يحتوي سطر `versionCode` على معلومات إضافية؛ المهم أن تكون قيمته `72`.

### 9.2 تحقق من APK المثبت نفسه

```powershell
$InstalledApkLine = @(
    .\adb.exe -s $QuestSerial shell pm path com.qcxr.qcxr.dev262
) | Where-Object { $_ -like "package:*" } | Select-Object -First 1

if (-not $InstalledApkLine) {
    throw "Installed package not found. Stop here."
}

$InstalledApkPath = $InstalledApkLine.Trim() -replace '^package:', ''
$VerifyApk = Join-Path $PWD "installed-v72-base.apk"

.\adb.exe -s $QuestSerial pull $InstalledApkPath $VerifyApk
if ($LASTEXITCODE -ne 0) {
    throw "Could not copy the installed APK for verification."
}

(Get-FileHash -LiteralPath $VerifyApk -Algorithm SHA256).Hash.ToUpperInvariant()
```

يجب أن تكون النتيجة:

```text
6748C17071B90ED5DC236FBA84CA3BBC4DEAED54C802D0150CFA82B20EFA3680
```

### 9.3 قائمة نجاح للمستخدم

- [ ] أمر التثبيت انتهى بكلمة `Success`.
- [ ] الحزمة تعرض `versionCode=72` و`versionName` الصحيح.
- [ ] بصمة APK المثبت تطابق البصمة المنشورة.
- [ ] في الترقية، instance `26.2` والعوالم ما زالت موجودة.
- [ ] تنزيل assets اكتمل دون خطأ integrity أو download.
- [ ] قائمة Minecraft الرئيسية ظهرت داخل VR بالعينين.
- [ ] إذا استعملت QGO، شغلت من **Apply/Launch** قبل تقييم الأداء.

نجاح البناء أو ظهور `Success` وحده لا يثبت اللعب. الوصول إلى القائمة داخل VR
هو فحص الجهاز الأول، ودخول عالم تجريبي هو فحص إضافي.

## 10. شجرة الأخطاء السريعة

ابدأ من الأعلى وتوقف عند أول إجابة «لا»:

1. **هل SHA-256 مطابق؟**
   - لا → لا تثبّت. أعد تنزيل APK الرسمي.
   - نعم → انتقل إلى السؤال 2.
2. **هل `adb devices -l` يعرض Quest بحالة `device`؟**
   - لا يظهر → تأكد من Developer Mode وOculus ADB Driver وكابل البيانات،
     جرّب منفذ USB آخر، ثم نفّذ الأوامر أدناه وأعد التوصيل.
   - يظهر `unauthorized` → وافق على USB debugging داخل النظارة.
   - يظهر `offline` → افصل الكابل، أعد تشغيل ADB، وأعد التوصيل.
   - نعم → انتقل إلى السؤال 3.
3. **هل اخترت USB serial الصحيح؟**
   - يوجد أكثر من جهاز → أعد تعيين `$QuestSerial` إلى السطر السلكي، ولا تخمّن.
   - جهاز واحد صحيح → انتقل إلى السؤال 4.
4. **هل أمر install انتهى بـ`Success`؟**
   - نعم → نفّذ تحقق الإصدار ثم جرّب أول تشغيل.
   - `INSTALL_FAILED_UPDATE_INCOMPATIBLE` → توقيع النسخة المثبتة مختلف. توقف؛
     لا تستخدم uninstall. احتفظ بالنسخة والبيانات واطلب بناءً بالتوقيع الصحيح.
   - `INSTALL_FAILED_VERSION_DOWNGRADE` → الملف أقدم من المثبت. لا تجبره إلا
     إذا كنت تنفذ قسم الرجوع المقصود وبـAPK محفوظ يحمل التوقيع نفسه.
   - خطأ مساحة → وفر مساحة دون حذف instance أو النسخة الاحتياطية، ثم أعد
     المحاولة.
5. **هل يفتح التطبيق لكن يظهر خطأ asset index؟**
   - نعم → نفّذ [حل asset index](#11-خطأ-asset-index-في-هذا-apk).
6. **هل يفتح لكن المودات ليست كما توقعت؟**
   - تذكر أن `adb install -r` لا يطابق مجلد المودات الحي. لا تحذف `26.2`؛
     افحص نسخة المجلد الاحتياطية وحالته الحالية كمسألة منفصلة.

لإعادة تشغيل ADB بأمان:

```powershell
.\adb.exe kill-server
.\adb.exe start-server
.\adb.exe devices -l
```

### أخطاء أخرى

- **`adb.exe` غير معروف:** افتح PowerShell من داخل `platform-tools` واستعمل
  `.\adb.exe` كما في الأوامر، لا `adb` وحدها.
- **`download failed`:** افحص Wi-Fi والتاريخ والوقت والمساحة، ثم أعد التشغيل.
  لا تحذف instance.
- **`AccessDeniedException`:** لا تستخدم `chmod 777` ولا تغيّر SELinux للمجلد
  كله. App UID يختلف بين التثبيتات. احتفظ بالنسخة، واستعد الملفات من داخل
  المشغّل أو أصلح مسارًا محددًا فقط بمساعدة خبير.
- **التطبيق غير ظاهر بعد `Success`:** ابحث عن `Vivecraft Stable` في Unknown
  Sources، ثم نفّذ تحقق الإصدار. لا تعِد التثبيت عشوائيًا إذا كان التحقق ناجحًا.

## 11. خطأ asset index في هذا APK

APK المنشور بُني من private development commit `cd079c65`. إصلاح self-heal
اللاحق موجود في **المصدر فقط** ضمن هذه اللقطة العامة، لكنه **ليس داخل APK**.

إذا ظهر النص:

```text
Minecraft asset index integrity check failed
```

لا تحذف instance `26.2`. أوقف التطبيق، وخذ نسخة من ملف index وحده، ثم أعد
تسميته على النظارة كي ينزّل المشغّل نسخة رسمية جديدة:

```powershell
$RemoteIndex = "/sdcard/Android/data/com.qcxr.qcxr.dev262/files/assets/indexes/32.json"
$IndexBackup = Join-Path $PWD "32.json.before-repair"

.\adb.exe -s $QuestSerial shell am force-stop com.qcxr.qcxr.dev262
.\adb.exe -s $QuestSerial pull $RemoteIndex $IndexBackup

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $IndexBackup)) {
    throw "Could not back up 32.json. Do not rename it."
}

.\adb.exe -s $QuestSerial shell mv $RemoteIndex "${RemoteIndex}.mismatched"

if ($LASTEXITCODE -ne 0) {
    throw "Could not rename the stale asset index. Stop here."
}
```

أعد تشغيل QuestCraft مع إنترنت ثابت. لا تنزّل `32.json` من موقع عشوائي. إذا
قال ADB إن الملف غير موجود، لا تحذف شيئًا؛ ارجع إلى فحص الشبكة والمساحة والوقت.

## 12. الرجوع إلى النسخة السابقة وعدم استخدام uninstall

الرجوع ممكن فقط إذا حفظت `previous-base.apk` وكان يحمل توقيعًا يقبله Android.
قبل الرجوع، كرر نسخة الخطوة 7A باسم زمني جديد حتى لا تستبدل نسخة ما قبل v72.

في الكتلة التالية، استبدل `PASTE_BACKUP_FOLDER_NAME_HERE` باسم مجلد النسخة
الحقيقي، مثل `QuestCraft-dev262-backup-20261002-153000`:

```powershell
$BackupDir = Join-Path $PWD "PASTE_BACKUP_FOLDER_NAME_HERE"
$PreviousApk = Join-Path $BackupDir "previous-base.apk"

if (-not (Test-Path -LiteralPath $PreviousApk -PathType Leaf)) {
    throw "Rollback APK was not found. Stop here."
}

.\adb.exe -s $QuestSerial shell am force-stop com.qcxr.qcxr.dev262
.\adb.exe -s $QuestSerial install -r -d $PreviousApk
```

- `-r` يطلب الحفاظ على البيانات.
- `-d` يسمح بمحاولة تثبيت إصدار أقدم.
- علامة النجاح هي `Success`، ثم أعد تحقق الإصدار وافتح عالمًا تجريبيًا.
- إذا رفض Android التوقيع أو downgrade، توقف. لا تستخدم uninstall لتجاوز
  الحماية.

`adb uninstall com.qcxr.qcxr.dev262` ليس أمر ترقية ولا رجوع؛ قد يزيل بيانات
الحزمة والعوالم والإعدادات وحالة تسجيل الدخول. لذلك لا يقدّم هذا الدليل خطوة
uninstall تلقائية. إذا قررت لاحقًا بدءًا نظيفًا عن قصد، افحص نسختين مستقلتين
أولًا وضع خطة استعادة صريحة.

لا تدفع مجلد `Android/data` كاملًا فوق التثبيت بلا فحص؛ قد تختلف الملكية
والصلاحيات بين التثبيتات. استعد من داخل المشغّل أو استعد ملفات محددة بعد التحقق
من App UID ونسخة احتياطية سليمة.

## 13. حدود هذا الإصدار

- إيصال الإصدار يثبت بناء APK وفحوصه الساكنة؛ لا يدّعي أنه ثُبّت في عملية
  البناء نفسها أو أن كل جهاز سيقبل التشغيل.
- إصلاح asset-index self-heal اللاحق مصدر فقط ضمن هذه اللقطة العامة، وليس في
  APK المبني من private development commit `cd079c65`.
- QGO وملفاته ليست داخل APK، واستعماله اختياري لمن يملكه مثبتًا أصلًا.
- Distant Horizons، وحزم المودات التجريبية، وتجهيز سيرفر، وحلول جهاز أو Hand
  Tracking خاصة ليست مميزات مشحونة في هذا APK.
- تحديث APK لا يساوي تحديث مجلد المودات الحي. احتفظ بنسخته وافحصه منفصلًا.
- لا يوجد ضمان FPS ثابت؛ العالم والسيرفر والحرارة وإعدادات النظام عوامل مستقلة.

## English quick summary

This is an Arabic-first Windows guide for the verified
`v72-personal.13-perfbase-cd079c65` pre-release.

1. An adult enables Meta Quest Developer Mode, installs the Oculus ADB driver,
   and approves USB debugging on a trusted PC.
2. Download Android Platform-Tools and the exact APK from the official release.
3. Verify SHA-256 equals
   `6748C17071B90ED5DC236FBA84CA3BBC4DEAED54C802D0150CFA82B20EFA3680`.
4. Use `adb devices -l`, copy the USB serial into `$QuestSerial`, and keep `-s
   $QuestSerial` in every device command.
5. If `com.qcxr.qcxr.dev262` is absent, use the fresh-install command. If it is
   present, make and inspect the backup first, then use `adb install -r`.
6. `-r` preserves package data but does not automatically reconcile the live
   mod folder. Never delete the `26.2` instance as an upgrade step.
7. Confirm `Success`, version code `72`, the installed APK hash, and the
   Minecraft main menu inside VR.
8. QGO is optional and external. Use it only if you already own and installed
   it. It is not required for installation.
9. Roll back only with the saved, same-signer `previous-base.apk` and `-r -d`.
   Never use uninstall as a shortcut around signer or downgrade errors.
