# بناء APK

## محلياً
- ثبّت Flutter stable وAndroid Studio/Android SDK.
- نفّذ من مجلد المشروع:

```bash
flutter create --platforms=android --org com.madani.ocr --project-name arabic_ocr .
mkdir -p assets/tessdata
curl -L https://github.com/tesseract-ocr/tessdata_best/raw/main/ara.traineddata -o assets/tessdata/ara.traineddata
curl -L https://github.com/tesseract-ocr/tessdata_best/raw/main/eng.traineddata -o assets/tessdata/eng.traineddata
flutter pub get
flutter analyze
flutter build apk --release
```

- ناتج APK: `build/app/outputs/flutter-apk/app-release.apk`.

## عبر GitHub Actions
ارفع المشروع إلى مستودع GitHub، ثم افتح Actions واختر **Build Android APK** ثم **Run workflow**. بعد اكتمال البناء نزّل artifact باسم `arabic-ocr-android-apk`.

ملف GitHub Actions موجود في `.github/workflows/android-apk.yml`. يحتاج مراجعة أول تشغيل على GitHub، خصوصاً إعدادات Gradle الخاصة بإصدار Flutter الذي سيستخدمه.
