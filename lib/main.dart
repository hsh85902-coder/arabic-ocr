import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const OcrApp());

const gold = Color(0xFFC7A451);
const ink = Color(0xFF171717);

class OcrApp extends StatelessWidget {
  const OcrApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'المستخرج الذكي OCR',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: gold, brightness: Brightness.light),
          scaffoldBackgroundColor: const Color(0xFFF7F6F2),
          fontFamily: 'sans-serif',
          appBarTheme: const AppBarTheme(backgroundColor: ink, foregroundColor: Colors.white),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          ),
        ),
        home: const HomePage(),
      );
}

class OcrPage {
  OcrPage({required this.number, required this.text, required this.source, this.confidence, this.previewPath});
  final int number;
  String text;
  final String source;
  final double? confidence;
  final String? previewPath;
  Map<String, dynamic> toJson() => {'page': number, 'text': text, 'source': source, 'confidence': confidence};
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _picker = ImagePicker();
  final _apiController = TextEditingController();
  final List<OcrPage> _pages = [];
  String _engine = 'hybrid';
  String _status = 'اختر صورة أو ملف PDF لبدء استخراج النصوص';
  bool _busy = false;
  String? _filename;
  int _selectedPage = 0;
  double _progress = 0;

  @override
  void dispose() {
    _apiController.dispose();
    super.dispose();
  }

  Future<Directory> _workDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final work = Directory(p.join(dir.path, 'ocr_work'));
    if (!await work.exists()) await work.create(recursive: true);
    return work;
  }

  Future<void> _camera() async {
    final x = await _picker.pickImage(source: ImageSource.camera, imageQuality: 100);
    if (x != null) await _processFile(File(x.path));
  }

  Future<void> _chooseFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'tif', 'tiff', 'bmp', 'webp'],
      withData: false,
    );
    if (result?.files.single.path != null) await _processFile(File(result!.files.single.path!));
  }

  Future<void> _processFile(File file) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _pages.clear();
      _filename = p.basename(file.path);
      _status = 'تهيئة المستند...';
    });
    try {
      final ext = p.extension(file.path).toLowerCase();
      if (ext == '.pdf') {
        await _processPdf(file);
      } else {
        await _processImage(file);
      }
      if (_pages.isEmpty) throw Exception('لم يتم العثور على صفحات قابلة للمعالجة.');
      setState(() => _status = 'اكتمل الاستخراج: ${_pages.length} صفحة');
    } catch (e) {
      setState(() => _status = 'تعذر إكمال الاستخراج: $e');
      _show('حدث خطأ أثناء المعالجة. تحقق من إعداد محرك OCR أو عنوان الخادم.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _processImage(File file) async {
    setState(() => _status = 'قراءة الصورة...');
    final page = await _recognize(file, 1);
    setState(() {
      _pages.add(page);
      _progress = 1;
    });
  }

  Future<void> _processPdf(File file) async {
    // Prefer server-side PDF processing in hybrid/cloud mode: it can extract
    // genuine embedded PDF text before falling back to page-level OCR.
    if (_engine != 'local' && _apiController.text.trim().isNotEmpty) {
      try {
        setState(() => _status = 'إرسال PDF إلى محرك المعالجة الهجين...');
        final base = _apiController.text.trim().replaceAll(RegExp(r'/$'), '');
        final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 5)));
        final form = FormData.fromMap({
          'file': await MultipartFile.fromFile(file.path, filename: p.basename(file.path)),
          'engine': 'hybrid',
        });
        final response = await dio.post('$base/api/extract', data: form);
        final data = response.data as Map<String, dynamic>;
        final pages = (data['pages'] as List).cast<Map<String, dynamic>>();
        setState(() {
          for (final item in pages) {
            _pages.add(OcrPage(
              number: (item['page'] as num).toInt(),
              text: (item['text'] ?? '').toString(),
              source: (item['source'] ?? 'معالجة PDF').toString(),
              confidence: (item['confidence'] as num?)?.toDouble(),
            ));
          }
          _progress = 1;
        });
        return;
      } catch (e) {
        if (_engine == 'cloud') rethrow;
        setState(() => _status = 'تعذرت المعالجة عبر الخادم؛ الانتقال إلى المعالجة المحلية...');
      }
    }
    final doc = await PdfDocument.openFile(file.path);
    try {
      final work = await _workDir();
      final count = doc.pagesCount;
      for (var i = 1; i <= count; i++) {
        if (!mounted) break;
        setState(() {
          _status = 'معالجة الصفحة $i من $count...';
          _progress = (i - 1) / count;
        });
        final page = await doc.getPage(i);
        final rendered = await page.render(
          width: (page.width * 2.5).clamp(1200, 2600).toDouble(),
          height: (page.height * 2.5).clamp(1600, 3600).toDouble(),
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        await page.close();
        if (rendered == null) continue;
        final imageFile = File(p.join(work.path, 'page_$i.png'));
        await imageFile.writeAsBytes(rendered.bytes, flush: true);
        final result = await _recognize(imageFile, i);
        setState(() {
          _pages.add(result);
          _progress = i / count;
          _selectedPage = _pages.length - 1;
        });
      }
    } finally {
      await doc.close();
    }
  }

  Future<OcrPage> _recognize(File image, int pageNumber) async {
    if (_engine == 'cloud') return _cloudRecognize(image, pageNumber);
    String? localText;
    Object? localError;
    try {
      localText = await FlutterTesseractOcr.extractText(
        image.path,
        language: 'ara+eng',
        args: {'psm': '3', 'preserve_interword_spaces': '1'},
      );
      if (_engine == 'local' || (localText.trim().length > 20 && !_looksPoor(localText))) {
        return OcrPage(number: pageNumber, text: localText.trim(), source: 'Tesseract محلي', previewPath: image.path);
      }
    } catch (e) {
      localError = e;
    }
    if (_engine == 'hybrid' && _apiController.text.trim().isNotEmpty) {
      try {
        final remote = await _cloudRecognize(image, pageNumber);
        if (remote.text.trim().length > (localText?.trim().length ?? 0) || localText == null || _looksPoor(localText)) {
          return remote;
        }
        return OcrPage(number: pageNumber, text: localText.trim(), source: 'Tesseract محلي (احتُفظ بالنتيجة)', previewPath: image.path);
      } catch (_) {
        if (localText != null && localText.trim().isNotEmpty) {
          return OcrPage(number: pageNumber, text: localText.trim(), source: 'Tesseract محلي (السحابة غير متاحة)', previewPath: image.path);
        }
        rethrow;
      }
    }
    if (localText != null && localText.trim().isNotEmpty) {
      return OcrPage(number: pageNumber, text: localText.trim(), source: 'Tesseract محلي', previewPath: image.path);
    }
    throw Exception(localError ?? 'محرك OCR المحلي غير جاهز.');
  }

  bool _looksPoor(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    if (compact.length < 35) return true;
    final arabic = RegExp(r'[\u0600-\u06FF]').allMatches(compact).length;
    return arabic / compact.length < 0.18;
  }

  Future<OcrPage> _cloudRecognize(File image, int pageNumber) async {
    final base = _apiController.text.trim().replaceAll(RegExp(r'/$'), '');
    if (base.isEmpty) throw Exception('أدخل عنوان خادم OCR أولاً.');
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 3)));
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(image.path, filename: p.basename(image.path)),
      'engine': 'hybrid',
    });
    final response = await dio.post('$base/api/extract', data: form);
    final data = response.data as Map<String, dynamic>;
    final pages = (data['pages'] as List).cast<Map<String, dynamic>>();
    final first = pages.first;
    return OcrPage(
      number: pageNumber,
      text: (first['text'] ?? '').toString(),
      source: (first['source'] ?? 'محرك سحابي').toString(),
      confidence: (first['confidence'] as num?)?.toDouble(),
      previewPath: image.path,
    );
  }

  Future<void> _exportText() async {
    if (_pages.isEmpty) return;
    final text = _pages.map((e) => 'ــــــــــ الصفحة ${e.number} ــــــــــ\n${e.text}').join('\n\n');
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'النص_المستخرج.txt'));
    await file.writeAsString(text, encoding: utf8, flush: true);
    await Share.shareXFiles([XFile(file.path)], text: 'النص المستخرج من ${_filename ?? 'المستند'}');
  }

  Future<void> _copyText() async {
    if (_pages.isEmpty) return;
    final text = _pages.map((e) => e.text).join('\n\n');
    await Share.share(text, subject: 'النص المستخرج');
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    final current = _pages.isEmpty ? null : _pages[_selectedPage.clamp(0, _pages.length - 1)];
    return Scaffold(
      appBar: AppBar(
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('المستخرج الذكي OCR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          Text('استخراج النصوص العربية من المستندات', style: TextStyle(fontSize: 10, color: gold)),
        ]),
        actions: [IconButton(onPressed: () => _settings(), icon: const Icon(Icons.settings_outlined))],
      ),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(22)),
            child: Column(children: [
              const Icon(Icons.document_scanner_outlined, size: 48, color: gold),
              const SizedBox(height: 8),
              const Text('حوّل مستنداتك إلى نص قابل للتحرير', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 5),
              const Text('PDF • JPG • PNG • TIFF', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(child: _actionButton(Icons.camera_alt_outlined, 'تصوير مستند', _camera)),
                const SizedBox(width: 10),
                Expanded(child: _actionButton(Icons.upload_file, 'اختيار ملف', _chooseFile)),
              ]),
            ]),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('إعدادات الاستخراج', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _engine,
                decoration: const InputDecoration(labelText: 'طريقة المعالجة'),
                items: const [
                  DropdownMenuItem(value: 'hybrid', child: Text('هجين: محلي + سحابي احتياطي')),
                  DropdownMenuItem(value: 'local', child: Text('محلي فقط - دون إنترنت')),
                  DropdownMenuItem(value: 'cloud', child: Text('سحابي عبر الخادم')),
                ],
                onChanged: _busy ? null : (v) => setState(() => _engine = v ?? 'hybrid'),
              ),
              if (_engine != 'local') ...[
                const SizedBox(height: 10),
                TextField(controller: _apiController, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'عنوان خادم OCR (اختياري)', hintText: 'https://your-server.example')),
              ],
            ])),
          ),
          const SizedBox(height: 12),
          if (_busy) LinearProgressIndicator(value: _progress == 0 ? null : _progress, color: gold, minHeight: 5),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              Icon(_busy ? Icons.hourglass_top : Icons.info_outline, color: gold),
              const SizedBox(width: 10),
              Expanded(child: Text(_status, style: const TextStyle(fontSize: 12))),
            ]),
          ),
          if (_pages.isNotEmpty) ...[
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('النص المستخرج', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
              Text('${_pages.length} صفحة', style: const TextStyle(color: Colors.black54, fontSize: 12)),
            ]),
            const SizedBox(height: 8),
            if (_pages.length > 1) SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _pages.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) => ChoiceChip(label: Text('صفحة ${i + 1}'), selected: _selectedPage == i, onSelected: (_) => setState(() => _selectedPage = i)),
              ),
            ),
            Card(elevation: 0, child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(current!.source, style: const TextStyle(color: Colors.black54, fontSize: 11))),
                if (current.confidence != null) Text('ثقة ${(current.confidence! * 100).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 11, color: Colors.green)),
              ]),
              const SizedBox(height: 8),
              TextFormField(
                key: ValueKey(current.number),
                initialValue: current.text,
                minLines: 12,
                maxLines: null,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
                decoration: const InputDecoration(hintText: 'سيظهر النص المستخرج هنا...', border: OutlineInputBorder()),
                onChanged: (v) => current.text = v,
              ),
            ]))),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: _copyText, icon: const Icon(Icons.copy), label: const Text('مشاركة النص'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.icon(onPressed: _exportText, icon: const Icon(Icons.save_alt), label: const Text('تصدير TXT'))),
            ]),
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('ملاحظة: تصدير Word/PDF وربط معاينة الكلمات بالصورة ضمن مرحلة التطوير التالية.', style: TextStyle(fontSize: 10, color: Colors.black54))),
          ],
        ]),
      ),
    );
  }

  Widget _actionButton(IconData icon, String label, VoidCallback action) => FilledButton.tonalIcon(
        onPressed: _busy ? null : action,
        icon: Icon(icon, color: gold),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF303030), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
      );

  void _settings() {
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 24), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: const [
        Text('إعدادات التطبيق', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        SizedBox(height: 12),
        Text('للتشغيل المحلي يجب إضافة ملف اللغة العربية ara.traineddata إلى assets/tessdata قبل البناء.'),
        SizedBox(height: 8),
        Text('يمكن ضبط عنوان خادم OCR من الشاشة الرئيسية لاستخدام المعالجة السحابية الاختيارية.'),
      ])),
    ));
  }
}
