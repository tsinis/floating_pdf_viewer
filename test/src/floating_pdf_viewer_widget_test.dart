import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:floating_pdf_viewer/floating_pdf_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdfx/pdfx.dart';
// ignore: implementation_imports, pdfx exports no other way to fake the platform.
import 'package:pdfx/src/renderer/interfaces/platform.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const _url = 'https://example.com/scan.pdf';
const _pdfBytes = [0x25, 0x50, 0x44, 0x46]; // "%PDF"

void main() {
  late Directory tempDir;
  late _FakePdfxPlatform pdfx;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('floating_pdf_viewer_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    pdfx = _FakePdfxPlatform();
    PdfxPlatform.instance = pdfx;
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  /// Lets the real file I/O of the cache finish, then builds the result.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      // Duration.zero also fires the zero-delay retry timer.
      await tester.pump(Duration.zero);
    }
  }

  Future<void> pumpViewer(WidgetTester tester, {int maxRetries = 1}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              FloatingPdfViewer(
                pdfUrl: _url,
                options: FloatingPdfViewerOptions(
                  maxRetries: maxRetries,
                  retryDelay: Duration.zero,
                ),
              ),
            ],
          ),
        ),
      );

  testWidgets('a document pdfx cannot open shows the error view instead of '
      'escaping as an unhandled error', (tester) async {
    await tester.runAsync(
      () => PdfCacheManager.savePdfToCache(_url, _pdfBytes),
    );
    pdfx.failuresLeft = 99;

    await pumpViewer(tester);
    await settleIo(tester);

    expect(find.text('Failed to load PDF'), findsOneWidget);
    expect(pdfx.openFileCalls, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cached file pdfx cannot open is removed from the cache', (
    tester,
  ) async {
    await tester.runAsync(
      () => PdfCacheManager.savePdfToCache(_url, _pdfBytes),
    );
    pdfx.failuresLeft = 99;

    await pumpViewer(tester, maxRetries: 0);
    await settleIo(tester);

    final isCached = await tester.runAsync(
      () => PdfCacheManager.isCached(_url),
    );
    expect(isCached, isFalse);
  });

  testWidgets('"Try Again" after a failed open shows the document', (
    tester,
  ) async {
    await tester.runAsync(
      () => PdfCacheManager.savePdfToCache(_url, _pdfBytes),
    );
    pdfx.failuresLeft = 1;

    await pumpViewer(tester, maxRetries: 0);
    await settleIo(tester);
    expect(find.text('Failed to load PDF'), findsOneWidget);

    // The failed file was dropped from the cache; put a good one back so the
    // reload does not need the network.
    await tester.runAsync(
      () => PdfCacheManager.savePdfToCache(_url, _pdfBytes),
    );
    await tester.tap(find.text('Try Again'));
    await settleIo(tester);

    expect(find.text('Failed to load PDF'), findsNothing);
    expect(find.byType(PdfViewPinch), findsOneWidget);
    expect(find.byKey(const Key('pdfx.root.success.doc-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

class _FakePdfxPlatform extends PdfxPlatform {
  int failuresLeft = 0;
  int openFileCalls = 0;

  @override
  Future<PdfDocument> openFile(String filePath, {String? password}) async {
    openFileCalls++;
    if (failuresLeft > 0) {
      failuresLeft--;
      throw Exception('RENDER_ERROR: Invalid PDF format');
    }
    return _FakeDocument();
  }

  @override
  Future<PdfDocument> openAsset(String name, {String? password}) =>
      throw UnimplementedError();

  @override
  Future<PdfDocument> openData(FutureOr<Uint8List> data, {String? password}) =>
      throw UnimplementedError();
}

class _FakeDocument extends PdfDocument {
  _FakeDocument() : super(sourceName: 'scan.pdf', id: 'doc-1', pagesCount: 1);

  @override
  Future<void> close() async => isClosed = true;

  @override
  Future<PdfPage> getPage(
    int pageNumber, {
    bool autoCloseAndroid = false,
  }) async => _FakePage(this, pageNumber);

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => id.hashCode;
}

class _FakePage extends PdfPage {
  _FakePage(PdfDocument document, int pageNumber)
    : super(
        document: document,
        id: 'page-$pageNumber',
        pageNumber: pageNumber,
        width: 595,
        height: 842,
        autoCloseAndroid: false,
      );

  @override
  Future<PdfPageImage?> render({
    required double width,
    required double height,
    PdfPageImageFormat format = PdfPageImageFormat.jpeg,
    String? backgroundColor,
    Rect? cropRect,
    int quality = 100,
    bool forPrint = false,
    bool removeTempFile = true,
  }) async => null;

  @override
  Future<PdfPageTexture> createTexture() async =>
      _FakeTexture(pageId: id, pageNumber: pageNumber);

  @override
  Future<void> close() async => isClosed = true;

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => Object.hash(id, pageNumber);
}

class _FakeTexture extends PdfPageTexture {
  _FakeTexture({required super.pageId, required super.pageNumber})
    : super(id: pageNumber);

  int? _textureWidth;
  int? _textureHeight;

  @override
  int? get textureWidth => _textureWidth;

  @override
  int? get textureHeight => _textureHeight;

  @override
  bool get hasUpdatedTexture => _textureWidth != null;

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> updateRect({
    required String documentId,
    int destinationX = 0,
    int destinationY = 0,
    int? width,
    int? height,
    int sourceX = 0,
    int sourceY = 0,
    int? textureWidth,
    int? textureHeight,
    double? fullWidth,
    double? fullHeight,
    String? backgroundColor,
    bool allowAntiAliasing = true,
  }) async {
    _textureWidth = textureWidth;
    _textureHeight = textureHeight;
    return true;
  }

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => Object.hash(id, pageNumber);
}
